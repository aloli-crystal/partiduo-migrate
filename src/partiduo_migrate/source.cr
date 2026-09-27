# SPDX-License-Identifier: AGPL-3.0-or-later

require "big"

module PartiduoMigrate
  # Modèle en mémoire d'un dossier à reprendre, commun aux deux sources
  # (FEC et base NOALYSS) : c'est lui que l'importateur écrit par le contrat
  # `Partiduo::Api` et dont la réconciliation calcule les chiffres « avant ».
  module Source
    ZERO = BigDecimal.new(0)

    # Ligne d'écriture telle que la source la décrit. `row` : numéro de ligne
    # du fichier (FEC) ou identifiant de la ligne (`jrnx.j_id`) ; `letter` :
    # code de lettrage, propre au compte.
    record Line,
      account : String,
      account_label : String,
      aux : String?,
      aux_label : String?,
      label : String,
      debit : BigDecimal,
      credit : BigDecimal,
      letter : String? = nil,
      letter_date : Time? = nil,
      currency_amount : BigDecimal? = nil,
      currency_code : String? = nil,
      row : Int64 = 0_i64 do
      # Montant signé débit − crédit.
      def signed : BigDecimal
        debit - credit
      end

      def zero? : Bool
        debit.zero? && credit.zero?
      end
    end

    # Pièce jointe d'une écriture (base NOALYSS : `jrn.jr_pj`).
    record Attachment, filename : String, content_type : String, content : Bytes

    # Écriture : lignes d'un même `EcritureNum` dans un même journal.
    # `origin` : identifiant dans la source (`jrn.jr_id` de NOALYSS).
    class Entry
      getter journal_code : String
      getter number : String
      getter date : Time
      getter receipt : String
      getter receipt_date : Time?
      getter label : String
      property due_date : Time?
      getter lines : Array(Line)
      property origin : Int64?
      property attachment : Attachment?

      def initialize(@journal_code, @number, @date, @receipt, @receipt_date, @label, @due_date = nil,
                     @lines = [] of Line, @origin = nil, @attachment = nil)
      end

      def total_debit : BigDecimal
        lines.sum(ZERO, &.debit)
      end

      def total_credit : BigDecimal
        lines.sum(ZERO, &.credit)
      end

      def balanced? : Bool
        total_debit == total_credit
      end

      def each_line(& : Line ->) : Nil
        @lines.each { |line| yield line }
      end

      # Référence lisible (`V01 n° 12`).
      def reference : String
        PartiduoMigrate.t("source.entry_reference", journal: journal_code, number: number)
      end
    end

    # Journal : code et libellé ; `kind` (`purchase`, `sale`, `financial`,
    # `misc`) et fiche Banque quand la source les connaît (NOALYSS).
    record Journal, code : String, label : String, kind : String? = nil, bank_card : String? = nil,
      receipt_prefix : String = ""

    # Compte du plan comptable : `kind` (`asset`, `liability`…) et
    # `direct_use` connus de la source NOALYSS seulement.
    record Account, number : String, label : String, parent : String? = nil, kind : String? = nil,
      direct_use : Bool = true

    # Fiche complète (base NOALYSS). `category` : identifiant de la catégorie
    # source (`fiche_def.fd_id`) ; `attributes` : valeurs par attribut
    # (`attr_def.ad_id`).
    record Card,
      code : String,
      name : String,
      category : Int64,
      account : String?,
      enabled : Bool,
      attributes : Hash(Int64, String)

    # Catégorie de fiches (base NOALYSS : `fiche_def`, modèle `frd_id`).
    record CardCategory, id : Int64, label : String, model : Int64, description : String

    # Taux de TVA (base NOALYSS : `tva_rate`) ; `rate` en pourcentage.
    record VatRate,
      code : String,
      label : String,
      rate : BigDecimal,
      comment : String,
      reverse_charge : Bool,
      sale_on_payment : Bool,
      purchase_on_payment : Bool,
      deductible_account : String?,
      collected_account : String?,
      id : Int64 = 0_i64

    # Période d'un exercice de la source (base NOALYSS : `parm_periode`).
    record Period, starts_on : Time, ends_on : Time, closed : Bool = false do
      def single_day? : Bool
        starts_on == ends_on
      end

      def overlaps?(first : Time, last : Time) : Bool
        starts_on <= last && ends_on >= first
      end
    end

    # Exercice de la source : premier jour, nombre de mois, libellé,
    # périodes (vide pour un exercice déduit des dates d'un FEC).
    record FiscalYear, label : String, starts_on : Time, months : Int32, periods : Array(Period) = [] of Period do
      def ends_on : Time
        starts_on.shift(months: months, days: -1)
      end

      # Période d'ouverture ou de clôture d'un jour (option « 13 périodes »
      # de NOALYSS) : reprise telle quelle par l'instance.
      def opening_period? : Bool
        periods.size > 1 && periods.first.single_day?
      end

      def closing_period? : Bool
        periods.size > 1 && periods.last.single_day?
      end
    end

    # Cumul d'une clé (compte, journal, mois) : lignes, débit, crédit.
    struct Tally
      getter count : Int32
      getter debit : BigDecimal
      getter credit : BigDecimal

      def initialize(@count = 0, @debit = ZERO, @credit = ZERO)
      end

      def add(debit : BigDecimal, credit : BigDecimal) : Tally
        Tally.new(@count + 1, @debit + debit, @credit + credit)
      end

      def add(other : Tally) : Tally
        Tally.new(@count + other.count, @debit + other.debit, @credit + other.credit)
      end

      def balance : BigDecimal
        debit - credit
      end
    end

    # Chiffres de la source relevés *indépendamment* du modèle, pour le
    # contrôle de lecture (ADR-001 D5) : FEC totalisé pendant la lecture sur
    # les montants bruts de chaque ligne, avant le calcul de son solde ; base
    # NOALYSS relue par des requêtes d'agrégat sur `jrnx` (modèle de
    # `acc_balance.class.php`). `sides` : débit et crédit comparables un à
    # un (base NOALYSS) ; sinon (FEC, dont une ligne peut porter débit et
    # crédit) seuls le nombre de lignes et le solde le sont.
    class Control
      getter accounts = Hash(String, Tally).new(Tally.new)
      getter journals = Hash(String, Tally).new(Tally.new)
      getter periods = Hash(String, Tally).new(Tally.new)
      getter? sides : Bool

      def initialize(@sides : Bool)
      end

      def self.period_key(date : Time) : String
        date.to_s("%Y-%m")
      end

      def add(account : String, journal : String, period : String, tally : Tally) : Nil
        accounts[account] = accounts[account].add(tally)
        journals[journal] = journals[journal].add(tally)
        periods[period] = periods[period].add(tally)
      end

      # Mêmes cumuls, calculés sur le modèle (`Dataset`), clés de la source.
      def self.of(dataset : Dataset, sides : Bool) : Control
        control = Control.new(sides)
        dataset.entries.each do |entry|
          period = period_key(entry.date)
          entry.each_line do |line|
            control.add(line.account, entry.journal_code, period, Tally.new.add(line.debit, line.credit))
          end
        end
        control
      end
    end

    # Donnée que la source porte mais que l'outil ne reprend pas (analytique
    # tant que le module n'a pas de contrat, pièces supplémentaires…),
    # consignée au rapport et en annexe CSV.
    record Unported, kind : String, reference : String, detail : String

    # Dossier complet.
    class Dataset
      getter description : String
      getter entries = [] of Entry
      getter journals = {} of String => Journal
      getter accounts = {} of String => Account
      getter parties = {} of String => String
      getter cards = [] of Card
      getter card_categories = [] of CardCategory
      getter attribute_labels = {} of Int64 => String
      getter vat_rates = [] of VatRate
      getter fiscal_years = [] of FiscalYear
      getter unported = [] of Unported
      # Nom du fichier FEC (date de clôture `…FECAAAAMMJJ`).
      property file_name : String? = nil
      # Toute la base NOALYSS (plan complet) plutôt que le seul FEC.
      property? full_chart = false
      # Zéros ignorés (lignes FEC à débit et crédit nuls).
      property zero_lines = 0
      # Chiffres relevés indépendamment du modèle (contrôle de lecture).
      property control : Control? = nil

      def initialize(@description : String)
      end

      def lines : Array(Line)
        entries.flat_map(&.lines)
      end

      def first_date : Time?
        entries.min_of?(&.date)
      end

      def last_date : Time?
        entries.max_of?(&.date)
      end

      # Données relues mais non reprises, en plus de `unported` : montants
      # en devise (une ligne par écriture et par devise autre que l'euro).
      def all_unported : Array(Unported)
        currencies = [] of Unported
        entries.each do |entry|
          amounts = Hash(String, BigDecimal).new(ZERO)
          entry.each_line do |line|
            code = line.currency_code.try(&.strip.upcase).presence || next
            next if code == "EUR"
            amounts[code] += line.currency_amount || ZERO
          end
          amounts.each do |code, amount|
            currencies << Unported.new("currency", entry.reference,
              PartiduoMigrate.t("source.currency_detail", amount: Fec.format_amount(amount), code: code))
          end
        end
        unported + currencies
      end

      # Dates de lettrage relues et non reprises (le lettrage de l'instance
      # porte sa propre date).
      def letter_dates : Int32
        lines.count(&.letter_date)
      end

      # Dates de pièce relues et non reprises (différentes de la date de
      # l'écriture).
      def receipt_dates : Int32
        entries.count { |entry| (day = entry.receipt_date) && day != entry.date }
      end

      # Date de clôture portée par le nom du fichier (`SIRENFECAAAAMMJJ`).
      def closing_date : Time?
        name = file_name || return
        match = name.match(/FEC(\d{4})(\d{2})(\d{2})/i) || return
        Time.utc(match[1].to_i, match[2].to_i, match[3].to_i)
      rescue ArgumentError
        nil
      end
    end
  end
end
