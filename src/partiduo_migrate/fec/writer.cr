# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module Fec
    # Écriture d'un FEC à partir d'un `Source::Dataset` : les dix-huit zones
    # de l'article A47 A-1, une ligne par ligne d'écriture, dans l'ordre des
    # écritures. Sert à produire le FEC de démonstration depuis une base
    # d'origine (`partiduo-migrate export-fec`). Comme l'export FEC de
    # l'application d'origine, `EcritureLib` porte le libellé de
    # l'opération ; à la différence de lui, le lettrage est écrit
    # (`EcritureLet`, `DateLet`).
    class Writer
      def initialize(@separator : Char = '\t', @encoding : String = "ISO-8859-15")
      end

      # Nom réglementaire : `<SIREN>FEC<AAAAMMJJ>.txt` (date de clôture).
      def self.file_name(siren : String, closing : Time) : String
        "#{siren.gsub(/\D/, "")}FEC#{closing.to_s("%Y%m%d")}.txt"
      end

      def write(dataset : Source::Dataset, io : IO) : Nil
        io.write(Encoding.encode(render(dataset), @encoding))
      end

      def render(dataset : Source::Dataset) : String
        String.build do |text|
          text << COLUMNS.join(@separator) << "\r\n"
          dataset.entries.each do |entry|
            entry.each_line do |line|
              values = [
                entry.journal_code,
                dataset.journals[entry.journal_code]?.try(&.label) || entry.journal_code,
                entry.number,
                Fec.format_date(entry.date),
                line.account,
                line.account_label,
                line.aux || "",
                line.aux_label || "",
                entry.receipt,
                Fec.format_date(entry.receipt_date || entry.date),
                entry.label.presence || line.label,
                Fec.format_amount(line.debit),
                Fec.format_amount(line.credit),
                line.letter || "",
                Fec.format_date(line.letter_date),
                Fec.format_date(entry.date),
                line.currency_amount.try { |amount| Fec.format_amount(amount) } || "",
                line.currency_code || "",
              ]
              text << values.map { |value| clean(value) }.join(@separator) << "\r\n"
            end
          end
        end
      end

      # Une zone ne contient ni le séparateur ni de fin de ligne.
      private def clean(value : String) : String
        value.gsub(/[\t\r\n|]/, " ").strip
      end
    end
  end
end
