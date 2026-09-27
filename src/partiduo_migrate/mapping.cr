# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # Correspondances source → instance établies pendant la reprise : comptes,
  # journaux, fiches, lignes d'écritures. La réconciliation compare les
  # chiffres de la source *traduits* par ces correspondances à ceux relus
  # dans l'instance ; le rapport les publie.
  class Mapping
    getter accounts = {} of String => String
    getter journals = {} of String => String
    getter ledger_ids = {} of String => Int64
    getter cards = {} of String => String
    # Ligne source (`{écriture, rang}`) → identifiant de la ligne créée.
    getter lines = {} of {Int32, Int32} => Int64
    # Pièces renommées : `{journal, pièce source, pièce retenue}`.
    getter receipts = [] of {String, String, String}

    def account(number : String) : String
      accounts[number]? || number
    end

    def journal(code : String) : String
      journals[code]? || code
    end

    def card(code : String?) : String?
      code.try { |value| cards[value]? || value }
    end

    # Correspondances qui changent l'identifiant (pour le rapport).
    def renamed : Array({String, String, String})
      rows = [] of {String, String, String}
      accounts.each { |source, target| rows << {"compte", source, target} if source != target }
      journals.each { |source, target| rows << {"journal", source, target} if source != target }
      cards.each { |source, target| rows << {"fiche", source, target} if source != target }
      receipts.each { |(journal, source, target)| rows << {"pièce #{journal}", source, target} }
      rows
    end
  end
end
