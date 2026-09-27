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

    # Défaut rencontré. `step` : étape (clé `migrate.steps.<step>`) ;
    # `blocking` : la reprise est incomplète (écriture, lettrage, compte,
    # journal, exercice) et ne peut pas réconcilier ; sinon avertissement
    # (détail de fiche, taux de TVA, pièce jointe).
    record Problem, step : String, reference : String, message : String, blocking : Bool = true do
      def step_label : String
        PartiduoMigrate.t("steps.#{step}")
      end
    end

    getter dataset : Source::Dataset
    getter mapping = Mapping.new
    getter problems = [] of Problem
    getter notes = [] of String
    # Compteurs de la reprise (clé `migrate.counts.<clé>`).
    getter counts = Hash(String, Int32).new(0)

    def initialize(@dataset : Source::Dataset, @actor : Api::Actor = Api::Actor.system,
                   @fiscal_start_month : Int32? = nil)
    end

    # L'instance peut-elle recevoir la reprise ? Configuration société
    # présente, Comptabilité active, aucune écriture (instance neuve).
    def self.preconditions(actor : Api::Actor = Api::Actor.system) : Array(String)
      errors = [] of String
      unless Api::Core.provisioned?(actor)
        errors << PartiduoMigrate.t("preconditions.not_provisioned")
        return errors
      end
      unless Api::Modules.get(actor, Accounting::MODULE_CODE).active
        errors << PartiduoMigrate.t("preconditions.accounting_inactive")
        return errors
      end
      count = Accounting.count_entries(actor)
      errors << PartiduoMigrate.t("preconditions.not_empty", total: count) if count > 0
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
          if check(Accounting.update_account(@actor, existing.id, input), "account", existing.number)
            notes << PartiduoMigrate.t("notes.account_enabled", account: existing.number)
          end
        end
        return
      end
      label = account.label.strip.presence || account.number
      parent = account.parent.try { |number| find_account(mapping.account(number)).try(&.number) }
      input = Accounting::AccountInput.new(number: account.number, label: label[0, 255], parent: parent,
        kind: kind_of(account), direct_use: account.direct_use || used)
      result = Accounting.create_account(@actor, input)
      if view = check(result, "account", account.number)
        mapping.accounts[account.number] = view.number
        counts["accounts_created"] += 1
      end
    end

    private def find_account(number : String) : Accounting::AccountView?
      Accounting.account(@actor, number)
    rescue Api::NotFound
      nil
    end

    # Type d'un compte créé : celui de la source (NOALYSS), sinon le plus
    # précis de deux : type du compte parent dans le plan de l'instance
    # (plus long préfixe existant, hors racine de contexte) et table des
    # préfixes du plan comptable général (`PCG_KINDS`) ; à précision égale,
    # la table (DECISIONS D-MIG-004, amendée).
    private def kind_of(account : Source::Account) : Accounting::AccountKind?
      if code = account.kind
        return Accounting::AccountKind.from_code(code)
      end
      number = account.number
      table = PCG_KINDS.select { |(prefix, _)| number.starts_with?(prefix) }.max_by?(&.[0].size)
      (number.size - 1).downto(1) do |size|
        parent = find_account(number[0, size]) || next
        break if parent.kind.context?
        return parent.kind if table.nil? || size > table[0].size
        break
      end
      table.try(&.[1])
    end

    alias Kind = Accounting::AccountKind

    # Préfixes du plan comptable général (règlement ANC 2014-03) → type du
    # compte ; le plus long préfixe l'emporte. Classe 4 : passif par défaut,
    # actif pour les créances (clients, fournisseurs débiteurs, avances au
    # personnel, TVA déductible et crédits de TVA, charges constatées
    # d'avance, écarts de conversion actif…) ; comptes de dépréciation et
    # d'amortissement en actif soustractif ; concours bancaires (519) au
    # passif.
    PCG_KINDS = [
      {"1", Kind::Liability}, {"109", Kind::Asset}, {"119", Kind::LiabilityContra}, {"129", Kind::LiabilityContra},
      {"2", Kind::Asset}, {"28", Kind::AssetContra}, {"29", Kind::AssetContra},
      {"3", Kind::Asset}, {"39", Kind::AssetContra},
      {"4", Kind::Liability}, {"409", Kind::Asset}, {"41", Kind::Asset}, {"419", Kind::Liability},
      {"425", Kind::Asset}, {"4287", Kind::Asset}, {"4387", Kind::Asset}, {"441", Kind::Asset},
      {"4456", Kind::Asset}, {"44581", Kind::Asset}, {"44582", Kind::Asset}, {"44583", Kind::Asset},
      {"44586", Kind::Asset}, {"4487", Kind::Asset}, {"462", Kind::Asset}, {"465", Kind::Asset},
      {"4687", Kind::Asset}, {"476", Kind::Asset}, {"481", Kind::Asset}, {"486", Kind::Asset}, {"49", Kind::AssetContra},
      {"5", Kind::Asset}, {"519", Kind::Liability}, {"59", Kind::AssetContra},
      {"6", Kind::Expense}, {"7", Kind::Income},
    ]

    # --- TVA -------------------------------------------------------------------

    # Taux de TVA : code nettoyé et tronqué à 5 caractères. Un taux du jeu
    # initial de même code et de même taux est mis à jour (autoliquidation,
    # exigibilité) ; sinon le taux est créé, sous un code suffixé (`FRIN2`)
    # si le code est pris — par un taux initial d'un autre taux, ou par un
    # taux déjà repris (deux codes NOALYSS qui donnent le même code). Les
    # codes changés vont dans les correspondances (DECISIONS D-MIG-008).
    private def import_vat_rates : Nil
      @vat_codes = {} of Int64 => String
      assigned = Set(String).new
      dataset.vat_rates.each do |rate|
        base = rate.code.upcase.gsub(/[^A-Z0-9]/, "")[0, 5].presence || "TVA"
        existing = assigned.includes?(base) ? nil : Api::Vat.rate_by_code(@actor, base)
        updated = !existing.nil? && existing.rate == rate.rate
        view = check(save_vat_rate(rate, base, updated ? existing : nil, !existing.nil?, assigned), "vat_rate",
          rate.code, blocking: false) || next
        assigned << view.code
        (@vat_codes ||= {} of Int64 => String)[rate.id] = view.code
        mapping.vat_rates[rate.code] = view.code
        if view.code == base && base != rate.code
          notes << PartiduoMigrate.t("notes.vat_code_cleaned", source: rate.code, code: view.code)
        elsif view.code != base
          notes << PartiduoMigrate.t("notes.vat_code_taken", source: rate.code, code: view.code, taken: base)
        end
        counts[updated ? "vat_rates_updated" : "vat_rates_created"] += 1
        next unless rate.deductible_account || rate.collected_account
        accounts = Accounting::VatRateAccountsInput.new(vat_rate_id: view.id,
          deductible_account: rate.deductible_account.try { |number| mapping.account(number) },
          collected_account: rate.collected_account.try { |number| mapping.account(number) })
        check(Accounting.set_vat_rate_accounts(@actor, accounts), "vat_rate_accounts", rate.code, blocking: false)
      end
    end

    # Taux initial de même taux (`same`) : autoliquidation et exigibilité
    # reprises ; sinon taux créé sous `base`, ou sous un code libre si
    # `base` est pris.
    private def save_vat_rate(rate : Source::VatRate, base : String, same : Api::Vat::RateView?, taken : Bool,
                              assigned : Set(String)) : Api::Result(Api::Vat::RateView)
      if same
        input = same.to_input.copy_with(reverse_charge: rate.reverse_charge,
          sale_on_payment: rate.sale_on_payment, purchase_on_payment: rate.purchase_on_payment)
        return Api::Vat.update_rate(@actor, same.id, input)
      end
      code = taken || assigned.includes?(base) ? free_vat_code(base, assigned) : base
      label = (rate.comment.presence || rate.label).strip[0, 64]
      if Api::Vat.rates(@actor, include_disabled: true).any?(&.label.==(label))
        label = "#{label[0, 64 - code.size - 3]} (#{code})"
      end
      Api::Vat.create_rate(@actor, Api::Vat::RateInput.new(code: code, label: label, rate: rate.rate,
        description: rate.label, reverse_charge: rate.reverse_charge,
        sale_on_payment: rate.sale_on_payment, purchase_on_payment: rate.purchase_on_payment))
    end

    # Premier code libre `<base><n>` (5 caractères au plus) : ni taux de
    # l'instance, ni code déjà attribué par la reprise.
    private def free_vat_code(base : String, assigned : Set(String)) : String
      (2..).each do |counter|
        suffix = counter.to_s
        candidate = base[0, 5 - suffix.size] + suffix
        return candidate unless assigned.includes?(candidate) || Api::Vat.rate_by_code(@actor, candidate)
      end
      raise "unreachable"
    end

    @vat_codes : Hash(Int64, String)? = nil

    # --- Exercices -------------------------------------------------------------

    # Exercices de la source (base NOALYSS), puis, pour les dates
    # d'écritures qu'aucune période ne couvre, exercices de douze mois
    # alignés sur les exercices voisins de la source. Sans exercices dans la
    # source (FEC), exercices de douze mois déduits des dates.
    private def import_fiscal_years : Nil
      if dataset.fiscal_years.empty?
        derived_fiscal_years.each { |year| create_fiscal_year(year) }
        return
      end
      years = dataset.fiscal_years.sort_by(&.starts_on)
      years.each { |year| create_fiscal_year(year) }
      dataset.entries.map(&.date).uniq!.sort!.each do |day|
        next if Api::Core.period_for(@actor, day)
        create_fiscal_year(aligned_fiscal_year(years, day))
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

    # Exercice qui couvre `day`, hors des exercices de la source `years`
    # (triés) : après le dernier, douze mois à partir du lendemain de sa fin
    # (par pas de douze mois) ; avant le premier, douze mois finissant la
    # veille de son début ; entre deux exercices, au plus douze mois à partir
    # du lendemain du précédent, arrêtés à la veille du suivant.
    private def aligned_fiscal_year(years : Array(Source::FiscalYear), day : Time) : Source::FiscalYear
      first = years.first
      if day < first.starts_on
        start = first.starts_on.shift(years: -1)
        while start > day
          start = start.shift(years: -1)
        end
        return Source::FiscalYear.new(label: "", starts_on: start, months: 12)
      end
      previous = years.reverse.find! { |year| year.ends_on < day }
      following = years.find { |year| year.starts_on > day }
      start = previous.ends_on.shift(days: 1)
      loop do
        ends = start.shift(months: 12, days: -1)
        ends = following.starts_on.shift(days: -1) if following && ends >= following.starts_on
        if day <= ends
          months = (ends.year - start.year) * 12 + ends.month - start.month + 1
          return Source::FiscalYear.new(label: "", starts_on: start, months: months)
        end
        start = ends.shift(days: 1)
      end
    end

    private def create_fiscal_year(year : Source::FiscalYear) : Nil
      last_day = year.ends_on
      covered = [year.starts_on, last_day].all? { |day| Api::Core.period_for(@actor, day) }
      return if covered
      input = Api::Core::FiscalYearInput.new(year: last_day.year, start_year: year.starts_on.year,
        start_month: year.starts_on.month, months: year.months, label: year.label.presence,
        opening_period: year.opening_period?, closing_period: year.closing_period?)
      if check(Api::Core.create_fiscal_year(@actor, input), "fiscal_year", year.label.presence || year.starts_on.to_s("%Y-%m"))
        counts["fiscal_years_created"] += 1
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
          description: source.description)), "card_category", source.label)
        next unless category
        counts["card_categories_created"] += 1
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
      check(Api::Cards.update_category(@actor, category.id, updated), "card_category", category.code,
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
            notes << PartiduoMigrate.t("notes.card_address_refused", card: @card.code, message: error.message)
            moved = true
          elsif typed.has_key?(field) && (current = value(field))
            notes << PartiduoMigrate.t("notes.card_value_refused", card: @card.code, field: field, value: current,
              message: error.message)
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
        notes << PartiduoMigrate.t("notes.card_kept", card: existing.code)
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
          counts["cards_created"] += 1
          assign_account(view.id, view.code, card.account, created: true)
          return category
        end
        errors = result.errors
        break unless draft.degrade(errors)
      end
      problem("card", card.code, errors)
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
      check(Accounting.assign_card_account(@actor, input), "card_account", code) || return
      return if current.nil? || chart_before.includes?(current.number)
      check(Accounting.delete_account(@actor, current.id), "computed_account", current.number, blocking: false)
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
        next problem("party", aux, [Api::FieldError.base("cards.errors.card.category_id.not_found")]) if category.nil?
        input = Api::Cards::CardInput.new(category_id: category.id, name: (label.strip.presence || aux)[0, 255],
          code: code.presence)
        view = check(Api::Cards.create_card(@actor, input), "party", aux) || next
        mapping.cards[aux] = view.code
        counts["cards_created"] += 1
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

    # Journal cible → journal source qui l'a reçu pendant la reprise.
    @ledger_owners = {} of String => String

    # Code nettoyé et tronqué à 10 caractères. Journal de l'instance de même
    # code (jeu initial) : réutilisé. Code déjà attribué par la reprise à un
    # autre journal source (`BQ-1` et `BQ1`) : journal distinct sous un code
    # suffixé, consigné — jamais de fusion silencieuse (DECISIONS D-MIG-005).
    private def import_journal(journal : Source::Journal, entries : Array(Source::Entry)) : Nil
      code = journal.code.upcase.gsub(/[^A-Z0-9]/, "")[0, 10]
      if owner = @ledger_owners[code]?
        free = free_ledger_code(code)
        notes << PartiduoMigrate.t("notes.ledger_code_taken", source: journal.code, other: owner, code: code,
          target: free)
        code = free
      elsif !code.empty? && (existing = find_ledger(code))
        map_journal(journal.code, existing)
        if (kind = journal.kind) && kind != existing.kind.code
          notes << PartiduoMigrate.t("notes.ledger_kind_differs", ledger: existing.code, kind: existing.kind.code,
            source: journal.code, source_kind: kind)
        end
        return
      end
      kind = journal.kind.try { |value| Accounting::LedgerKind.from_code(value) } || guess_kind(entries)
      bank_card = kind.financial? ? bank_card_for(journal, entries) : nil
      if kind.financial? && bank_card.nil?
        notes << PartiduoMigrate.t("notes.ledger_without_bank", ledger: journal.code)
        kind = Accounting::LedgerKind::Misc
      end
      input = Accounting::LedgerInput.new(name: (journal.label.strip.presence || journal.code)[0, 100], kind: kind,
        code: code.presence, receipt_prefix: journal.receipt_prefix, bank_card: bank_card)
      view = check(Accounting.create_ledger(@actor, input), "ledger", journal.code) || return
      counts["ledgers_created"] += 1
      map_journal(journal.code, view)
    end

    # Premier code libre `<code><n>` (10 caractères au plus).
    private def free_ledger_code(code : String) : String
      (2..).each do |counter|
        suffix = counter.to_s
        candidate = code[0, 10 - suffix.size] + suffix
        return candidate unless @ledger_owners.has_key?(candidate) || find_ledger(candidate)
      end
      raise "unreachable"
    end

    private def map_journal(code : String, view : Accounting::LedgerView) : Nil
      mapping.journals[code] = view.code
      mapping.ledger_ids[code] = view.id
      @ledger_owners[view.code] = code
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
    # besoin. Une fiche citée par le compte mais introuvable est ignorée.
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
      rescue Api::NotFound
        next
      end
      category = Api::Cards.category_by_code(@actor, "BANK") || return
      input = Api::Cards::CardInput.new(category_id: category.id, name: "#{journal.label.presence || journal.code} (#{target})"[0, 255])
      card = check(Api::Cards.create_card(@actor, input), "bank_card", journal.code) || return
      counts["cards_created"] += 1
      assign_account(card.id, card.code, account, created: true)
      card.code
    end

    # --- Écritures -------------------------------------------------------------

    private def import_entries : Nil
      # Pièces prises, par journal *cible* : deux journaux source réunis dans
      # un même journal de l'instance partagent la même numérotation.
      taken = Hash(Int64, Set(String)).new { |hash, key| hash[key] = Set(String).new }
      dataset.entries.each_with_index do |entry, index|
        ledger_id = mapping.ledger_ids[entry.journal_code]? || next problem("entry", entry.reference,
          [Api::FieldError.new("ledger_id", "accounting.errors.entry.ledger.not_found")])
        receipt = receipt_for(entry, taken[ledger_id])
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
        view = check(Accounting.post_entry(@actor, input), "entry", entry.reference) || next
        counts["entries_created"] += 1
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
      view = check(Api::Core.store_attachment(@actor, input), "attachment", "#{entry.reference} #{attachment.filename}",
        blocking: false) || return
      counts["attachments"] += 1
      view.id
    end

    # --- Lettrage --------------------------------------------------------------

    # Lettrages de la source (`Reconciliation.matching_groups`) ; partiel
    # si débit ≠ crédit.
    private def import_matchings : Nil
      Reconciliation.matching_groups(dataset, mapping).each do |group|
        ids = group.refs.compact_map { |ref| mapping.lines[ref]? }
        if check(Accounting.match_lines(@actor, ids), "matching", group.reference)
          counts["matchings"] += 1
        end
      end
    end

    # --- Fin de reprise --------------------------------------------------------

    # Périodes closes dans la source (NOALYSS), fermées après les écritures.
    # Une période de l'instance n'est fermée que si toutes les périodes de
    # la source qu'elle recouvre sont closes : la période de clôture d'un
    # jour (31/12, option « 13 périodes »), close seule, ne ferme pas
    # décembre (consigné).
    private def close_periods : Nil
      source = dataset.fiscal_years.flat_map(&.periods)
      return if source.none?(&.closed)
      Api::Core.periods(@actor).each do |period|
        next if period.closed?
        inside = source.select(&.overlaps?(period.starts_on, period.ends_on))
        next if inside.none?(&.closed)
        if inside.all?(&.closed)
          counts["periods_closed"] += 1 if check(Api::Core.close_period(@actor, period.id), "period",
                                             period_reference(period), blocking: false)
        else
          notes << PartiduoMigrate.t("notes.period_left_open", period: period_reference(period))
        end
      end
    end

    private def period_reference(period : Api::Core::PeriodView) : String
      "#{period.starts_on.to_s("%Y-%m-%d")} – #{period.ends_on.to_s("%Y-%m-%d")}"
    end

    # Fiches désactivées dans la source : désactivées après les écritures
    # (une fiche inactive refuse la saisie).
    private def disable_cards : Nil
      dataset.cards.reject(&.enabled).each do |card|
        code = mapping.cards[card.code]? || next
        view = Api::Cards.card_by_code(@actor, code) || next
        check(Api::Cards.set_card_enabled(@actor, view.id, false), "card", card.code, blocking: false)
      end
    end

    # --- Outils ----------------------------------------------------------------

    private def check(result : Api::Result(T), step : String, reference : String, blocking : Bool = true) : T? forall T
      return result.value! if result.success?
      problem(step, reference, result.errors, blocking)
      nil
    end

    private def problem(step : String, reference : String, errors : Array(Api::FieldError), blocking : Bool = true) : Nil
      message = errors.map { |error| PartiduoMigrate.t("error", field: error.field, message: error.message) }.join(" ; ")
      problems << Problem.new(step, reference, message, blocking)
    end
  end
end
