# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # Correspondances source → instance établies pendant la reprise : comptes,
  # journaux, fiches, taux de TVA, lignes d'écritures. La réconciliation
  # compare les chiffres de la source *traduits* par ces correspondances à
  # ceux relus dans l'instance ; le rapport les publie.
  class Mapping
    getter accounts = {} of String => String
    getter journals = {} of String => String
    getter ledger_ids = {} of String => Int64
    getter cards = {} of String => String
    # Code l'application d'origine du taux (`tva_rate.tva_code`) → code du taux de l'instance.
    getter vat_rates = {} of String => String
    # Ligne source (`{écriture, rang}`) → identifiant de la ligne créée.
    getter lines = {} of {Int32, Int32} => Int64
    # Pièces renommées : `{journal, pièce source, pièce retenue}`.
    getter receipts = [] of {String, String, String}
    # Écriture source (rang) → identifiant de l'écriture créée.
    getter entry_ids = {} of Int32 => Int64
    # Poste analytique source `{plan, poste}` → `{plan, code}` de l'instance.
    getter analytic_posts = {} of {String, String} => {String, String}
    # Imputations analytiques écrites par la reprise (chiffres « avant »).
    getter analytic_rows = [] of Source::AnalyticRow

    def account(number : String) : String
      accounts[number]? || number
    end

    def journal(code : String) : String
      journals[code]? || code
    end

    def card(code : String?) : String?
      code.try { |value| cards[value]? || value }
    end

    # Correspondances qui changent l'identifiant (pour le rapport) : nature
    # (traduite), source, instance.
    def renamed : Array({String, String, String})
      rows = [] of {String, String, String}
      {"account" => accounts, "journal" => journals, "card" => cards, "vat_rate" => vat_rates}.each do |kind, pairs|
        label = PartiduoMigrate.t("mapping.#{kind}")
        pairs.each { |source, target| rows << {label, source, target} if source != target }
      end
      receipts.each do |(journal, source, target)|
        rows << {PartiduoMigrate.t("mapping.receipt", journal: journal), source, target}
      end
      rows
    end
  end
end
