# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoMigrate
  # Écrit un `Source::Dataset` dans une instance Partiduo neuve,
  # *exclusivement* par le contrat `Partiduo::Api` (ADR-001 D5, ADR-003 D6) :
  # aucune requête SQL sur les tables du cœur, les contrôles d'intégrité de
  # l'instance s'appliquent aux données reprises comme à la saisie.
  #
  # Ordre : comptes, taux de TVA, exercices, catégories et fiches, journaux,
  # pièces jointes et écritures, lettrages, périodes closes, fiches
  # désactivées. Chaque refus devient un `Problem` ; l'appelant
  # (`Migration`) décide d'annuler.
  class Importer
    alias Api = Partiduo::Api
    alias Accounting = Partiduo::Api::Accounting

    # Défaut rencontré. `blocking` : la reprise est incomplète (écriture,
    # lettrage, compte, journal, exercice) et ne peut pas réconcilier ;
    # sinon avertissement (détail de fiche, taux de TVA, pièce jointe).
    record Problem, step : String, reference : String, message : String, blocking : Bool = true

    getter dataset : Source::Dataset
    getter mapping = Mapping.new
    getter problems = [] of Problem
    getter notes = [] of String
    getter counts = Hash(String, Int32).new(0)

    def initialize(@dataset : Source::Dataset, @actor : Api::Actor = Api::Actor.system,
                   @fiscal_start_month : Int32? = nil)
    end

    # L'instance peut-elle recevoir la reprise ? Configuration société
    # présente, Comptabilité active, aucune écriture (instance neuve).
    def self.preconditions(actor : Api::Actor = Api::Actor.system) : Array(String)
      errors = [] of String
      unless Api::Core.provisioned?(actor)
        errors << "instance non provisionnée : créez-la d'abord avec bin/partiduo-provision"
        return errors
      end
      unless Api::Modules.get(actor, Accounting::MODULE_CODE).active
        errors << "module Comptabilité inactif sur l'instance (PARTIDUO_MODULES)"
        return errors
      end
      count = Accounting.count_entries(actor)
      errors << "l'instance compte déjà #{count} écriture(s) : la reprise se fait dans une instance neuve" if count > 0
      errors
    end

    def run : Nil
      import_accounts
      chart_before
      import_vat_rates
      import_fiscal_years
      import_cards
      import_parties
      import_journals
      import_entries
      import_matchings
      close_periods
      disable_cards
    end

    def blocking? : Bool
      problems.any?(&.blocking)
    end

    # --- Comptes ---------------------------------------------------------------

    private def import_accounts : Nil
      used = dataset.lines.map(&.account).to_set
      wanted = dataset.accounts.values
      wanted = wanted.select { |account| used.includes?(account.number) } unless dataset.full_chart?
      extra = dataset.vat_rates.flat_map { |rate| [rate.deductible_account, rate.collected_account] }.compact +
              dataset.cards.compact_map(&.account)
      extra.each do |number|
        next if dataset.accounts.has_key?(number) || wanted.any?(&.number.==(number))
        wanted << Source::Account.new(number, number)
      end
      wanted.sort_by! { |account| {account.number.size, account.number} }
      wanted.each { |account| import_account(account, used.includes?(account.number)) }
    end

    private def import_account(account : Source::Account, used : Bool) : Nil
      existing = find_account(account.number)
      if existing
        mapping.accounts[account.number] = existing.number
        if used && !existing.direct_use
          input = Accounting::AccountInput.new(number: existing.number, label: existing.label,
            parent: existing.parent_number, kind: existing.kind, direct_use: true)
          if check(Accounting.update_account(@actor, existing.id, input), "compte", existing.number)
            notes << "Compte #{existing.number} rendu utilisable en saisie (mouvementé dans la source)."
          end
        end
        return
      end
      label = account.label.strip.presence || account.number
      parent = account.parent.try { |number| find_account(mapping.account(number)).try(&.number) }
      input = Accounting::AccountInput.new(number: account.number, label: label[0, 255], parent: parent,
        kind: kind_of(account), direct_use: account.direct_use || used)
      result = Accounting.create_account(@actor, input)
      if view = check(result, "compte", account.number)
        mapping.accounts[account.number] = view.number
        counts["comptes créés"] += 1
      end
    end

    private def find_account(number : String) : Accounting::AccountView?
      Accounting.account(@actor, number)
    rescue Api::NotFound
      nil
    end

    # Type d'un compte créé : celui de la source (NOALYSS), sinon déduit de
    # la classe du plan comptable général (DECISIONS D-MIG-004).
    private def kind_of(account : Source::Account) : Accounting::AccountKind?
      if code = account.kind
        return Accounting::AccountKind.from_code(code)
      end
      number = account.number
      case number[0]?
      when '1'      then Accounting::AccountKind::Liability
      when '2', '3' then Accounting::AccountKind::Asset
      when '5'      then Accounting::AccountKind::Asset
      when '6'      then Accounting::AccountKind::Expense
      when '7'      then Accounting::AccountKind::Income
      when '4'
        number.starts_with?("41") || number.starts_with?("409") ? Accounting::AccountKind::Asset : Accounting::AccountKind::Liability
      end
    end

    # --- TVA -------------------------------------------------------------------

    private def import_vat_rates : Nil
      @vat_codes = {} of Int64 => String
      dataset.vat_rates.each do |rate|
        code = rate.code.upcase.gsub(/[^A-Z0-9]/, "")[0, 5]
        existing = Api::Vat.rate_by_code(@actor, code)
        result = if existing
                   input = existing.to_input.copy_with(rate: rate.rate, reverse_charge: rate.reverse_charge,
                     sale_on_payment: rate.sale_on_payment, purchase_on_payment: rate.purchase_on_payment)
                   Api::Vat.update_rate(@actor, existing.id, input)
                 else
                   label = (rate.comment.presence || rate.label).strip[0, 64]
                   if Api::Vat.rates(@actor, include_disabled: true).any?(&.label.==(label))
                     label = "#{label[0, 64 - code.size - 3]} (#{code})"
                   end
                   Api::Vat.create_rate(@actor, Api::Vat::RateInput.new(code: code, label: label, rate: rate.rate,
                     description: rate.label, reverse_charge: rate.reverse_charge,
                     sale_on_payment: rate.sale_on_payment, purchase_on_payment: rate.purchase_on_payment))
                 end
        view = check(result, "taux de TVA", rate.code, blocking: false) || next
        (@vat_codes ||= {} of Int64 => String)[rate.id] = view.code
        notes << "Taux de TVA #{rate.code} repris sous le code #{view.code}." if view.code != rate.code
        counts[existing ? "taux de TVA mis à jour" : "taux de TVA créés"] += 1
        next unless rate.deductible_account || rate.collected_account
        accounts = Accounting::VatRateAccountsInput.new(vat_rate_id: view.id,
          deductible_account: rate.deductible_account.try { |number| mapping.account(number) },
          collected_account: rate.collected_account.try { |number| mapping.account(number) })
        check(Accounting.set_vat_rate_accounts(@actor, accounts), "comptes du taux de TVA", rate.code, blocking: false)
      end
    end

    @vat_codes : Hash(Int64, String)? = nil

    # --- Exercices -------------------------------------------------------------

    private def import_fiscal_years : Nil
      if dataset.fiscal_years.empty?
        derived_fiscal_years.each { |year| create_fiscal_year(year) }
      else
        dataset.fiscal_years.each { |year| create_fiscal_year(year) }
        # Écritures hors des exercices de la source : exercices ajoutés.
        derived_fiscal_years.each { |year| create_fiscal_year(year) }
      end
    end

    # Exercices de douze mois couvrant les dates des écritures ; premier mois :
    # `--fiscal-start`, sinon le mois qui suit la date de clôture du nom du
    # FEC, sinon janvier.
    private def derived_fiscal_years : Array(Source::FiscalYear)
      first = dataset.first_date
      last = dataset.last_date
      return [] of Source::FiscalYear if first.nil? || last.nil?
      month = @fiscal_start_month || dataset.closing_date.try { |date| date.month % 12 + 1 } || 1
      start = Time.utc(first.year, month, 1)
      start = start.shift(years: -1) if start > first
      years = [] of Source::FiscalYear
      while start <= last
        years << Source::FiscalYear.new(label: "", starts_on: start, months: 12)
        start = start.shift(years: 1)
      end
      years
    end

    private def create_fiscal_year(year : Source::FiscalYear) : Nil
      last_day = year.starts_on.shift(months: year.months, days: -1)
      covered = [year.starts_on, last_day].all? { |day| Api::Core.period_for(@actor, day) }
      return if covered
      input = Api::Core::FiscalYearInput.new(year: last_day.year, start_year: year.starts_on.year,
        start_month: year.starts_on.month, months: year.months, label: year.label.presence)
      if check(Api::Core.create_fiscal_year(@actor, input), "exercice", year.label.presence || year.starts_on.to_s("%Y-%m"))
        counts["exercices créés"] += 1
      end
    end

    # --- Fiches (base NOALYSS) -------------------------------------------------

    # Modèle de catégorie NOALYSS (`fiche_def_ref.frd_id`) → catégorie
    # initiale de Partiduo et nature.
    FRD_CATEGORIES = {9_i64 => "CUSTOMER", 8_i64 => "SUPPLIER", 4_i64 => "BANK", 1_i64 => "SALE", 2_i64 => "PURCHASE",
                      3_i64 => "EXPENSE", 16_i64 => "CONTACT", 25_i64 => "EMPLOYEE", 10_i64 => "EMPLOYEE",
                      11_i64 => "EMPLOYEE", 12_i64 => "EMPLOYEE", 14_i64 => "TAX_AUTHORITY"}
    FRD_KINDS = {9_i64 => "customer", 8_i64 => "supplier", 4_i64 => "bank", 1_i64 => "item", 2_i64 => "item",
                 3_i64 => "item", 7_i64 => "item", 13_i64 => "item", 16_i64 => "contact", 25_i64 => "employee",
                 10_i64 => "employee", 11_i64 => "employee", 12_i64 => "employee"}

    # Attributs NOALYSS (`attr_def.ad_id`) repris dans une colonne typée ;
    # les autres vont dans les attributs propres (`noalyss_<ad_id>`).
    TYPED_ATTRIBUTES = {1_i64, 2_i64, 3_i64, 5_i64, 6_i64, 7_i64, 9_i64, 12_i64, 13_i64, 14_i64, 15_i64, 16_i64,
                        17_i64, 18_i64, 23_i64, 24_i64, 55_i64, 56_i64, 57_i64}
    COUNTRIES = {"FRANCE" => "FR", "BELGIQUE" => "BE", "BELGIË" => "BE", "BELGIUM" => "BE", "LUXEMBOURG" => "LU",
                 "ALLEMAGNE" => "DE", "ESPAGNE" => "ES", "ITALIE" => "IT", "PAYS-BAS" => "NL", "SUISSE" => "CH"}

    private def import_cards : Nil
      return if dataset.cards.empty?
      categories = map_categories
      dataset.cards.group_by(&.category).each do |source_category, cards|
        category = categories[source_category]? || next
        ids = cards.flat_map(&.attributes.select { |id, value| !value.empty? && !TYPED_ATTRIBUTES.includes?(id) }.keys)
        category = ensure_attributes(category, ids)
        cards.each { |card| category = import_card(card, category) }
      end
    end

    private def map_categories : Hash(Int64, Api::Cards::CategoryView)
      result = {} of Int64 => Api::Cards::CategoryView
      used = Set(String).new
      dataset.card_categories.each do |source|
        code = FRD_CATEGORIES[source.model]?
        category = code.try { |value| Api::Cards.category_by_code(@actor, value) } if code && !used.includes?(code)
        if category
          used << category.code
          result[source.id] = category
          next
        end
        code = "FD#{source.id}"
        category = Api::Cards.category_by_code(@actor, code)
        category ||= check(Api::Cards.create_category(@actor, Api::Cards::CategoryInput.new(
          code: code, name: source.label.strip.presence || code, kind: FRD_KINDS[source.model]? || "other",
          description: source.description)), "catégorie de fiches", source.label)
        next unless category
        counts["catégories de fiches créées"] += 1
        result[source.id] = category
      end
      result
    end

    # Ajoute à la catégorie les attributs NOALYSS `ids` qu'elle n'a pas
    # encore (texte, clé `noalyss_<ad_id>`).
    private def ensure_attributes(category : Api::Cards::CategoryView, ids : Array(Int64)) : Api::Cards::CategoryView
      input = category.to_input
      known = input.attributes.map(&.key).to_set
      added = ids.uniq.sort!.compact_map do |id|
        key = attribute_key(category, id)
        next if known.includes?(key)
        known << key
        Api::Cards::AttributeInput.new(key: key, label: (dataset.attribute_labels[id]?.presence || key)[0, 100])
      end
      return category if added.empty?
      updated = input.copy_with(attributes: input.attributes + added)
      check(Api::Cards.update_category(@actor, category.id, updated), "catégorie de fiches", category.code,
        blocking: false) || category
    end

    # Prénom (`ad_id` 32) : attribut `first_name` des catégories qui l'ont.
    private def attribute_key(category : Api::Cards::CategoryView, id : Int64) : String
      return "first_name" if id == 32 && category.attributes.any?(&.key.==("first_name"))
      "noalyss_#{id}"
    end

    ADDRESS_ATTRIBUTES = {14_i64, 15_i64, 24_i64, 16_i64}

    # Fiche en préparation : colonnes typées (champ → attribut NOALYSS et
    # valeur), attributs propres, adresse. Une valeur refusée par le socle
    # passe en attribut propre (`degrade`).
    private class CardDraft
      getter typed = {} of String => {Int64, String?}
      getter extra = {} of Int64 => String
      getter address : Api::Cards::AddressInput?
      getter notes = [] of String

      TYPED = {"contact_name" => 12_i64, "vat_number" => 13_i64, "phone" => 17_i64, "email" => 18_i64,
               "siren" => 55_i64, "siret" => 56_i64, "iban" => 3_i64, "description" => 9_i64,
               "sale_price" => 6_i64, "purchase_price" => 7_i64, "vat_rate_id" => 2_i64}
      PARTY_ONLY = %w[contact_name vat_number siren siret iban]
      ITEM_ONLY  = %w[sale_price purchase_price vat_rate_id]

      def initialize(@card : Source::Card, item : Bool)
        TYPED.each { |field, id| @typed[field] = {id, text(id)} }
        @card.attributes.each do |id, value|
          @extra[id] = value unless value.empty? || TYPED_ATTRIBUTES.includes?(id)
        end
        # Colonnes réservées aux articles, ou aux tiers : en attribut propre.
        (item ? PARTY_ONLY : ITEM_ONLY).each { |field| move(field) }
        if item
          drop_address
        else
          country = text(57_i64).try(&.upcase).try { |value| value.size == 2 ? value : nil } ||
                    text(16_i64).try { |value| COUNTRIES[value.upcase]? }
          @address = Api::Cards::AddressInput.new(line1: text(14_i64), postcode: text(15_i64), city: text(24_i64),
            country_code: country)
        end
      end

      def text(id : Int64) : String?
        @card.attributes[id]?.try(&.strip).presence
      end

      def value(field : String) : String?
        typed[field][1]
      end

      def move(field : String) : Nil
        id, value = typed[field]
        typed[field] = {id, nil}
        value.try { |text| extra[id] = text }
      end

      def drop_address : Nil
        @address = nil
        ADDRESS_ATTRIBUTES.each { |id| text(id).try { |value| extra[id] = value } }
      end

      # Passe en attribut propre les valeurs refusées ; faux si aucune ne
      # peut l'être (refus d'une autre nature).
      def degrade(errors : Array(Api::FieldError)) : Bool
        moved = false
        errors.each do |error|
          field = error.field.split('.').first
          if field == "address" && @address
            drop_address
            notes << "Fiche #{@card.code} : adresse refusée (#{error.message}), conservée en attribut."
            moved = true
          elsif typed.has_key?(field) && (current = value(field))
            notes << "Fiche #{@card.code} : #{field} « #{current} » refusé (#{error.message}), conservé en attribut."
            move(field)
            moved = true
          end
        end
        moved
      end
    end

    # Reprend une fiche ; renvoie la catégorie, complétée des attributs
    # ajoutés en chemin.
    private def import_card(card : Source::Card, category : Api::Cards::CategoryView) : Api::Cards::CategoryView
      code = Api::Cards.format_code(card.code)
      if existing = Api::Cards.card_by_code(@actor, code)
        mapping.cards[card.code] = existing.code
        notes << "Fiche #{existing.code} déjà présente dans l'instance : conservée telle quelle."
        assign_account(existing.id, existing.code, card.account)
        return category
      end
      draft = CardDraft.new(card, category.item?)
      errors = [] of Api::FieldError
      3.times do
        category = ensure_attributes(category, draft.extra.keys)
        result = Api::Cards.create_card(@actor, card_input(card, category, code, draft))
        if view = result.value?
          notes.concat(draft.notes)
          mapping.cards[card.code] = view.code
          counts["fiches créées"] += 1
          assign_account(view.id, view.code, card.account, created: true)
          return category
        end
        errors = result.errors
        break unless draft.degrade(errors)
      end
      problem("fiche", card.code, errors)
      category
    end

    private def card_input(card : Source::Card, category : Api::Cards::CategoryView, code : String,
                           draft : CardDraft) : Api::Cards::CardInput
      price = ->(field : String) { draft.value(field).try { |value| Fec.parse_amount(value) } }
      vat_rate_id = draft.value("vat_rate_id").try(&.to_i64?).try do |id|
        @vat_codes.try(&.[id]?).try { |rate_code| Api::Vat.rate_by_code(@actor, rate_code).try(&.id) }
      end
      known = category.attributes.map(&.key).to_set
      attributes = {} of String => JSON::Any
      draft.extra.each do |id, value|
        key = attribute_key(category, id)
        attributes[key] = JSON::Any.new(value) if known.includes?(key)
      end
      Api::Cards::CardInput.new(
        category_id: category.id, name: card.name[0, 255], code: code,
        description: draft.value("description"), vat_number: draft.value("vat_number"), siren: draft.value("siren"),
        siret: draft.value("siret"), iban: draft.value("iban"), email: draft.value("email"),
        phone: draft.value("phone"), contact_name: draft.value("contact_name"), address: draft.address,
        sale_price: price.call("sale_price"), purchase_price: price.call("purchase_price"), vat_rate_id: vat_rate_id,
        extra: attributes,
      )
    end

    # Rattache une fiche au compte de la source. Une fiche *créée par la
    # reprise* a pu recevoir de l'abonné `card.saved` de la Comptabilité un
    # compte calculé (`account_compute`) : il est remplacé par celui de la
    # source, puis effacé s'il vient d'être créé (DECISIONS D-MIG-006).
    private def assign_account(card_id : Int64, code : String, account : String?, created : Bool = false) : Nil
      return if account.nil?
      target = mapping.account(account)
      current = Accounting.card_account(@actor, card_id).try(&.account)
      return if current && (!created || current.number == target)
      input = Accounting::AssignCardAccountInput.new(card_id: card_id, account: target)
      check(Accounting.assign_card_account(@actor, input), "compte de fiche", code) || return
      return if current.nil? || chart_before.includes?(current.number)
      check(Accounting.delete_account(@actor, current.id), "compte calculé", current.number, blocking: false)
    end

    @chart_before : Set(String)? = nil

    # Comptes de l'instance avant la création des fiches.
    private def chart_before : Set(String)
      @chart_before ||= Accounting.chart(@actor).map(&.account.number).to_set
    end

    # --- Tiers du FEC ----------------------------------------------------------

    # Comptes auxiliaires sans fiche NOALYSS : fiche minimale (nom, code),
    # catégorie déduite du compte, rattachée au compte le plus mouvementé.
    private def import_parties : Nil
      lines_by_aux = Hash(String, Array(Source::Line)).new { |hash, key| hash[key] = [] of Source::Line }
      dataset.entries.each { |entry| entry.each_line { |line| line.aux.try { |aux| lines_by_aux[aux] << line } } }
      dataset.parties.each do |aux, label|
        next if mapping.cards.has_key?(aux)
        accounts = (lines_by_aux[aux]? || [] of Source::Line).map(&.account).tally
        account = accounts.max_by?(&.[1]).try(&.[0])
        code = Api::Cards.format_code(aux)
        if code.empty? || code.size > 64
          code = ""
        elsif existing = Api::Cards.card_by_code(@actor, code)
          mapping.cards[aux] = existing.code
          assign_account(existing.id, existing.code, account)
          next
        end
        category = Api::Cards.category_by_code(@actor, party_category(account)) ||
                   Api::Cards.category_by_code(@actor, "CONTACT")
        next problem("tiers", aux, [Api::FieldError.base("cards.errors.card.category_id.not_found")]) if category.nil?
        input = Api::Cards::CardInput.new(category_id: category.id, name: (label.strip.presence || aux)[0, 255],
          code: code.presence)
        view = check(Api::Cards.create_card(@actor, input), "tiers", aux) || next
        mapping.cards[aux] = view.code
        counts["fiches créées"] += 1
        assign_account(view.id, view.code, account, created: true)
      end
    end

    private def party_category(account : String?) : String
      number = account || ""
      case number
      when .starts_with?("40")                      then "SUPPLIER"
      when .starts_with?("41")                      then "CUSTOMER"
      when .starts_with?("42")                      then "EMPLOYEE"
      when .starts_with?("43"), .starts_with?("44") then "TAX_AUTHORITY"
      when .starts_with?("51"), .starts_with?("53") then "BANK"
      when .starts_with?("6")                       then "EXPENSE"
      when .starts_with?("7")                       then "SALE"
      else                                               "CONTACT"
      end
    end

    # --- Journaux --------------------------------------------------------------

    private def import_journals : Nil
      entries = dataset.entries.group_by(&.journal_code)
      codes = dataset.full_chart? ? dataset.journals.keys : entries.keys
      codes.each do |code|
        journal = dataset.journals[code]? || Source::Journal.new(code, code)
        import_journal(journal, entries[code]? || [] of Source::Entry)
      end
    end

    private def import_journal(journal : Source::Journal, entries : Array(Source::Entry)) : Nil
      code = journal.code.upcase.gsub(/[^A-Z0-9]/, "")[0, 10]
      if !code.empty? && (existing = find_ledger(code))
        map_journal(journal.code, existing)
        if (kind = journal.kind) && kind != existing.kind.code
          notes << "Journal #{existing.code} de l'instance (#{existing.kind.code}) repris pour le journal source " \
                   "#{journal.code} (#{kind})."
        end
        return
      end
      kind = journal.kind.try { |value| Accounting::LedgerKind.from_code(value) } || guess_kind(entries)
      bank_card = kind.financial? ? bank_card_for(journal, entries) : nil
      if kind.financial? && bank_card.nil?
        notes << "Journal #{journal.code} : aucune fiche Banque déterminée, créé en opérations diverses."
        kind = Accounting::LedgerKind::Misc
      end
      input = Accounting::LedgerInput.new(name: (journal.label.strip.presence || journal.code)[0, 100], kind: kind,
        code: code.presence, receipt_prefix: journal.receipt_prefix, bank_card: bank_card)
      view = check(Accounting.create_ledger(@actor, input), "journal", journal.code) || return
      counts["journaux créés"] += 1
      map_journal(journal.code, view)
    end

    private def map_journal(code : String, view : Accounting::LedgerView) : Nil
      mapping.journals[code] = view.code
      mapping.ledger_ids[code] = view.id
    end

    private def find_ledger(code : String) : Accounting::LedgerView?
      Accounting.ledger_by_code(@actor, code)
    rescue Api::NotFound
      nil
    end

    # Nature d'un journal que la source ne donne pas (FEC) : financier si
    # chaque écriture touche un compte de trésorerie (51, 53), achats ou
    # ventes selon les comptes de tiers et de charges ou de produits, sinon
    # opérations diverses (DECISIONS D-MIG-005).
    private def guess_kind(entries : Array(Source::Entry)) : Accounting::LedgerKind
      return Accounting::LedgerKind::Misc if entries.empty?
      has = ->(entry : Source::Entry, prefixes : Array(String)) do
        entry.lines.any? { |line| prefixes.any? { |prefix| line.account.starts_with?(prefix) } }
      end
      if entries.all? { |entry| has.call(entry, %w[51 53]) }
        Accounting::LedgerKind::Financial
      elsif entries.all? { |entry| has.call(entry, %w[40]) && has.call(entry, %w[6 2]) }
        Accounting::LedgerKind::Purchase
      elsif entries.all? { |entry| has.call(entry, %w[41]) && has.call(entry, %w[7]) }
        Accounting::LedgerKind::Sale
      else
        Accounting::LedgerKind::Misc
      end
    end

    # Fiche Banque d'un journal financier : celle de la source (NOALYSS),
    # sinon celle du compte de trésorerie le plus mouvementé, créée au
    # besoin.
    private def bank_card_for(journal : Source::Journal, entries : Array(Source::Entry)) : String?
      if code = journal.bank_card
        return mapping.card(code)
      end
      account = entries.flat_map(&.lines).map(&.account).select(&.starts_with?("5")).tally
        .max_by?(&.[1]).try(&.[0]) || return
      target = mapping.account(account)
      Accounting.card_ids_for_account(@actor, target).each do |id|
        card = Api::Cards.card(@actor, id)
        return card.code if card.kind == "bank"
      end
      category = Api::Cards.category_by_code(@actor, "BANK") || return
      input = Api::Cards::CardInput.new(category_id: category.id, name: "#{journal.label.presence || journal.code} (#{target})"[0, 255])
      card = check(Api::Cards.create_card(@actor, input), "fiche Banque", journal.code) || return
      counts["fiches créées"] += 1
      assign_account(card.id, card.code, account, created: true)
      card.code
    end

    # --- Écritures -------------------------------------------------------------

    private def import_entries : Nil
      taken = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
      dataset.entries.each_with_index do |entry, index|
        ledger_id = mapping.ledger_ids[entry.journal_code]? || next problem("écriture", entry.reference,
          [Api::FieldError.new("ledger_id", "accounting.errors.entry.ledger.not_found")])
        receipt = receipt_for(entry, taken[entry.journal_code])
        attachment_id = store_attachment(entry)
        lines = entry.lines.map do |line|
          debit = line.debit > 0
          Accounting::EntryLineInput.new(
            account: mapping.account(line.account), side: debit ? Accounting::Side::Debit : Accounting::Side::Credit,
            amount: debit ? line.debit : line.credit, card: line.aux.try { |aux| mapping.cards[aux]? },
            label: line.label == entry.label ? "" : line.label[0, 255],
          )
        end
        source = (entry.origin ? "noalyss:#{entry.origin}" : "fec:#{entry.journal_code}:#{entry.number}")[0, 100]
        input = Accounting::EntryInput.new(ledger_id: ledger_id, date: entry.date, lines: lines,
          label: entry.label[0, 255], receipt: receipt, due_date: entry.due_date, attachment_id: attachment_id,
          source: source)
        view = check(Accounting.post_entry(@actor, input), "écriture", entry.reference) || next
        counts["écritures créées"] += 1
        view.lines.sort_by!(&.position).each_with_index do |line, position|
          mapping.lines[{index, position}] = line.id
        end
      end
    end

    # Pièce de l'écriture : celle de la source, rendue unique dans le journal
    # (`-2`, `-3`…) et limitée à 40 caractères ; vide = numérotation du
    # journal.
    private def receipt_for(entry : Source::Entry, taken : Set(String)) : String?
      source = entry.receipt.strip
      return if source.empty?
      receipt = source[0, 40]
      counter = 1
      while taken.includes?(receipt)
        counter += 1
        suffix = "-#{counter}"
        receipt = source[0, 40 - suffix.size] + suffix
      end
      taken << receipt
      mapping.receipts << {entry.journal_code, source, receipt} if receipt != source
      receipt
    end

    private def store_attachment(entry : Source::Entry) : Int64?
      attachment = entry.attachment || return
      input = Api::Core::AttachmentInput.new(filename: attachment.filename, content_type: attachment.content_type,
        content: IO::Memory.new(attachment.content))
      view = check(Api::Core.store_attachment(@actor, input), "pièce jointe", "#{entry.reference} #{attachment.filename}",
        blocking: false) || return
      counts["pièces jointes"] += 1
      view.id
    end

    # --- Lettrage --------------------------------------------------------------

    # Lignes d'un même compte et d'un même code de lettrage : un lettrage
    # (partiel si débit ≠ crédit).
    private def import_matchings : Nil
      groups = Hash({String, String}, Array(Int64)).new { |hash, key| hash[key] = [] of Int64 }
      dataset.entries.each_with_index do |entry, index|
        entry.lines.each_with_index do |line, position|
          letter = line.letter || next
          id = mapping.lines[{index, position}]? || next
          groups[{mapping.account(line.account), letter}] << id
        end
      end
      groups.each do |(account, letter), ids|
        if check(Accounting.match_lines(@actor, ids), "lettrage", "#{account} #{letter}")
          counts["lettrages"] += 1
        end
      end
    end

    # --- Fin de reprise --------------------------------------------------------

    # Périodes closes dans la source (NOALYSS), fermées après les écritures.
    private def close_periods : Nil
      dataset.fiscal_years.each do |year|
        year.closed_periods.each do |day|
          period = Api::Core.period_for(@actor, day) || next
          next if period.closed?
          counts["périodes closes"] += 1 if check(Api::Core.close_period(@actor, period.id), "période",
                                              day.to_s("%Y-%m"), blocking: false)
        end
      end
    end

    # Fiches désactivées dans la source : désactivées après les écritures
    # (une fiche inactive refuse la saisie).
    private def disable_cards : Nil
      dataset.cards.reject(&.enabled).each do |card|
        code = mapping.cards[card.code]? || next
        view = Api::Cards.card_by_code(@actor, code) || next
        check(Api::Cards.set_card_enabled(@actor, view.id, false), "fiche", card.code, blocking: false)
      end
    end

    # --- Outils ----------------------------------------------------------------

    private def check(result : Api::Result(T), step : String, reference : String, blocking : Bool = true) : T? forall T
      return result.value! if result.success?
      problem(step, reference, result.errors, blocking)
      nil
    end

    private def problem(step : String, reference : String, errors : Array(Api::FieldError), blocking : Bool = true) : Nil
      message = errors.map { |error| "#{error.field} : #{error.message}" }.join(" ; ")
      problems << Problem.new(step, reference, message, blocking)
    end
  end
end
