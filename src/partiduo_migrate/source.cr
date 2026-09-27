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
        "#{journal_code} n° #{number}"
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

    # Exercice de la source : premier jour, nombre de mois, libellé ;
    # `closed_periods` : premiers jours des périodes closes.
    record FiscalYear, label : String, starts_on : Time, months : Int32, closed_periods : Array(Time) = [] of Time

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
