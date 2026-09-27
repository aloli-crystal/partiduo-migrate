# SPDX-License-Identifier: AGPL-3.0-or-later

require "big"

module PartiduoMigrate
  # Fichier des écritures comptables (article A47 A-1 du livre des
  # procédures fiscales, arrêté du 29 juillet 2013) : un fichier texte à
  # plat, première ligne d'en-tête, champs séparés par une tabulation ou une
  # barre verticale, dates `AAAAMMJJ`, montants à virgule décimale.
  module Fec
    # Les dix-huit zones de l'article A47 A-1, dans l'ordre.
    COLUMNS = %w[
      JournalCode JournalLib EcritureNum EcritureDate CompteNum CompteLib
      CompAuxNum CompAuxLib PieceRef PieceDate EcritureLib Debit Credit
      EcritureLet DateLet ValidDate Montantdevise Idevise
    ]

    # Zones obligatoires, en plus des montants (`Debit` et `Credit`, ou
    # `Montant` et `Sens`). `Montantdevise` et `Idevise` sont tolérées
    # absentes (fichiers antérieurs à 2014).
    REQUIRED = %w[
      JournalCode JournalLib EcritureNum EcritureDate CompteNum CompteLib
      CompAuxNum CompAuxLib PieceRef PieceDate EcritureLib EcritureLet DateLet ValidDate
    ]

    # Zones facultatives reconnues au-delà des dix-huit : échéance (non
    # normalisée, produite par certains logiciels).
    DUE_DATE_COLUMNS = %w[DateEcheance EcheanceDate DateEch]

    # Séparateurs admis et leur nom (clé `migrate.fec.separators.<nom>`).
    SEPARATORS = {'\t' => "tab", '|' => "pipe"}

    def self.separator_name(separator : Char) : String
      SEPARATORS[separator]?.try { |name| PartiduoMigrate.t("fec.separators.#{name}") } || separator.to_s
    end

    class Error < Exception
    end

    # Montant d'une zone : virgule ou point décimal, blancs (y compris
    # insécables) et signe `+` admis ; vide = zéro. `nil` si illisible.
    def self.parse_amount(text : String) : BigDecimal?
      value = text.strip.gsub(/[\s  ]/, "")
      return BigDecimal.new(0) if value.empty?
      value = value.lchop('+')
      if value.includes?(',') && value.includes?('.')
        # 1.234,56 : le point est un séparateur de milliers.
        value = value.delete('.')
      end
      value = value.tr(",", ".")
      return unless value.matches?(/\A-?\d+(\.\d+)?\z|\A-?\.\d+\z/)
      BigDecimal.new(value)
    rescue InvalidBigDecimalException
      nil
    end

    # Montant écrit dans un FEC : virgule décimale, au moins deux décimales,
    # jamais d'exposant ni d'arrondi.
    def self.format_amount(value : BigDecimal) : String
      negative = value < 0
      text = value.abs.to_s
      integer, _, fraction = text.partition('.')
      fraction = fraction.rstrip('0')
      fraction = fraction.ljust(2, '0')
      "#{negative ? "-" : ""}#{integer},#{fraction}"
    end

    # Date `AAAAMMJJ` (tolère `AAAA-MM-JJ` et `JJ/MM/AAAA`) ; `nil` si vide,
    # `Error` si illisible.
    def self.parse_date(text : String) : Time?
      value = text.strip
      return if value.empty?
      year, month, day = case value
                         when /\A(\d{4})(\d{2})(\d{2})\z/, /\A(\d{4})-(\d{2})-(\d{2})\z/
                           {$1.to_i, $2.to_i, $3.to_i}
                         when /\A(\d{2})\/(\d{2})\/(\d{4})\z/
                           {$3.to_i, $2.to_i, $1.to_i}
                         else
                           raise Error.new(PartiduoMigrate.t("fec.unreadable_date", value: value))
                         end
      Time.utc(year, month, day)
    rescue ArgumentError
      raise Error.new(PartiduoMigrate.t("fec.unreadable_date", value: value))
    end

    def self.format_date(time : Time?) : String
      time.try(&.to_s("%Y%m%d")) || ""
    end
  end
end
