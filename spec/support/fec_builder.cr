# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module SpecSupport
    # FEC minimal construit en mémoire pour les specs de règles : une ligne
    # par appel de `row`, zones de l'article A47 A-1 dans l'ordre.
    module FecBuilder
      HEADER = PartiduoMigrate::Fec::COLUMNS.join('\t')

      def self.row(journal : String, number : String, date : String, account : String, debit : String = "0,00",
                   credit : String = "0,00", aux : String = "", label : String = "Écriture", receipt : String = "",
                   letter : String = "", journal_label : String? = nil) : String
        [journal, journal_label || "Journal #{journal}", number, date, account, "Compte #{account}", aux,
         aux.empty? ? "" : "Tiers #{aux}", receipt.empty? ? "#{journal}-#{number}" : receipt, date, label, debit,
         credit, letter, letter.empty? ? "" : date, date, "", ""].join('\t')
      end

      def self.bytes(rows : Array(String)) : Bytes
        ([HEADER] + rows).join("\r\n").to_slice
      end

      # Jeu de données lu par le lecteur de FEC ; la spec échoue s'il relève
      # un défaut.
      def self.dataset(rows : Array(String), name : String = "123456789FEC20241231.txt") : Source::Dataset
        reader = PartiduoMigrate::Fec::Reader.new
        dataset = reader.read(bytes(rows), name)
        reader.problems.map(&.to_s).should be_empty
        dataset
      end
    end
  end
end
