# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module Fec
    # Défaut d'un FEC : ligne du fichier (1 = en-tête), zone, message.
    record Problem, line : Int32, column : String, message : String do
      def to_s(io : IO) : Nil
        io << "ligne " << line
        io << ", " << column unless column.empty?
        io << " : " << message
      end
    end

    # Lecture d'un FEC en `Source::Dataset` : encodage et séparateur
    # reconnus, zones contrôlées ligne à ligne, lignes regroupées en
    # écritures par journal et numéro d'écriture. Les défauts sont réunis
    # dans `problems` ; un fichier qui en a n'est pas importé.
    class Reader
      getter problems = [] of Problem
      getter encoding = ""
      getter separator = '\t'

      def initialize(@forced_encoding : String? = nil)
      end

      def read_file(path : String) : Source::Dataset
        read(File.read(path).to_slice, File.basename(path))
      end

      def read(bytes : Bytes, name : String = "FEC") : Source::Dataset
        dataset = Source::Dataset.new("FEC #{name}")
        dataset.file_name = name
        text, @encoding = Encoding.decode(bytes, @forced_encoding)
        lines = text.split(/\r\n|\n|\r/)
        while lines.last?.try(&.strip.empty?)
          lines.pop
        end
        header = lines.first?
        if header.nil? || header.strip.empty?
          @problems << Problem.new(1, "", "fichier vide")
          return dataset
        end
        @separator = detect_separator(header) || return dataset
        columns = header.split(@separator).map { |value| unquote(value) }
        index = column_index(columns) || return dataset

        by_key = {} of {String, String} => Source::Entry
        lines.each_with_index do |raw, position|
          next if position.zero? || raw.strip.empty?
          number = position + 1
          fields = raw.split(@separator).map { |value| unquote(value) }
          if fields.size < columns.size
            @problems << Problem.new(number, "", "#{fields.size} zones au lieu de #{columns.size}")
            next
          end
          read_line(dataset, by_key, fields, index, number)
        end
        dataset.entries.each do |entry|
          next if entry.balanced?
          @problems << Problem.new(entry.lines.first?.try(&.row.to_i32) || 0, "EcritureNum",
            "écriture #{entry.reference} déséquilibrée (débit #{Fec.format_amount(entry.total_debit)}, " \
            "crédit #{Fec.format_amount(entry.total_credit)})")
        end
        dataset
      end

      private def detect_separator(header : String) : Char?
        return '\t' if header.includes?('\t')
        return '|' if header.includes?('|')
        @problems << Problem.new(1, "", "séparateur non reconnu : tabulation ou barre verticale attendue")
        nil
      end

      private def unquote(value : String) : String
        value = value.strip
        value.size >= 2 && value.starts_with?('"') && value.ends_with?('"') ? value[1..-2].gsub("\"\"", "\"") : value
      end

      # Position de chaque zone, sans égard à la casse ; `nil` (et un défaut
      # par zone) s'il en manque.
      private def column_index(columns : Array(String)) : Hash(String, Int32)?
        index = {} of String => Int32
        columns.each_with_index { |name, position| index[name.downcase] = position }
        missing = REQUIRED.reject { |name| index.has_key?(name.downcase) }
        unless (index.has_key?("debit") && index.has_key?("credit")) || (index.has_key?("montant") && index.has_key?("sens"))
          missing << "Debit/Credit (ou Montant/Sens)"
        end
        missing.each { |name| @problems << Problem.new(1, name, "zone obligatoire absente") }
        missing.empty? ? index : nil
      end

      # Zones d'une ligne du fichier, lues par nom ; une date illisible est
      # consignée comme défaut.
      private struct Fields
        getter number : Int32

        def initialize(@fields : Array(String), @index : Hash(String, Int32), @number : Int32,
                       @problems : Array(Problem))
        end

        def [](name : String) : String
          @index[name.downcase]?.try { |position| @fields[position]? } || ""
        end

        def has?(name : String) : Bool
          @index.has_key?(name.downcase)
        end

        def date(name : String) : Time?
          Fec.parse_date(self[name])
        rescue ex : Error
          @problems << Problem.new(@number, name, ex.message.to_s)
          nil
        end

        # Échéance d'une zone facultative reconnue (`DUE_DATE_COLUMNS`).
        def due_date : Time?
          DUE_DATE_COLUMNS.each do |name|
            next unless has?(name)
            found = date(name)
            return found if found
          end
          nil
        end
      end

      private def read_line(dataset : Source::Dataset, by_key, values : Array(String), index : Hash(String, Int32),
                            number : Int32) : Nil
        fields = Fields.new(values, index, number, @problems)
        %w[JournalCode EcritureNum CompteNum EcritureDate].each do |name|
          @problems << Problem.new(number, name, "zone vide") if fields[name].empty?
        end
        entry_date = fields.date("EcritureDate")
        fields.date("ValidDate")
        line = build_line(fields, number) || return
        return if entry_date.nil? || {"JournalCode", "EcritureNum", "CompteNum"}.any? { |name| fields[name].empty? }
        if line.zero?
          dataset.zero_lines += 1
          return
        end
        store(dataset, by_key, fields, entry_date, line)
      end

      private def build_line(fields : Fields, number : Int32) : Source::Line?
        letter_date = fields.date("DateLet")
        debit, credit = amounts(fields, number) || return
        currency_amount = nil
        unless (text = fields["Montantdevise"]).empty?
          currency_amount = Fec.parse_amount(text)
          @problems << Problem.new(number, "Montantdevise", "montant illisible : #{text}") if currency_amount.nil?
        end
        aux = fields["CompAuxNum"].presence
        Source::Line.new(
          account: fields["CompteNum"], account_label: fields["CompteLib"], aux: aux,
          aux_label: aux ? fields["CompAuxLib"] : nil, label: fields["EcritureLib"],
          debit: debit, credit: credit, letter: fields["EcritureLet"].presence, letter_date: letter_date,
          currency_amount: currency_amount, currency_code: fields["Idevise"].presence, row: number.to_i64,
        )
      end

      private def store(dataset : Source::Dataset, by_key, fields : Fields, entry_date : Time, line : Source::Line) : Nil
        journal = fields["JournalCode"]
        key = {journal, fields["EcritureNum"]}
        due_date = fields.due_date
        entry = by_key[key]? || begin
          created = Source::Entry.new(journal, key[1], entry_date, fields["PieceRef"], fields.date("PieceDate"),
            fields["EcritureLib"], due_date)
          by_key[key] = created
          dataset.entries << created
          created
        end
        if entry.date != entry_date
          @problems << Problem.new(fields.number, "EcritureDate",
            "écriture #{entry.reference} : date #{Fec.format_date(entry_date)} différente de #{Fec.format_date(entry.date)}")
        end
        entry.due_date ||= due_date
        entry.lines << line
        dataset.journals[journal] ||= Source::Journal.new(journal, fields["JournalLib"])
        dataset.accounts[line.account] ||= Source::Account.new(line.account, line.account_label)
        line.aux.try { |code| dataset.parties[code] ||= fields["CompAuxLib"] }
      end

      # Débit et crédit d'une ligne (zones `Debit` / `Credit`, ou `Montant`
      # et `Sens`) ; un montant négatif passe de l'autre côté.
      private def amounts(fields : Fields, number : Int32) : {BigDecimal, BigDecimal}?
        value = ->(name : String) { fields[name] }
        zero = BigDecimal.new(0)
        if fields.has?("Debit")
          debit = Fec.parse_amount(value.call("Debit"))
          credit = Fec.parse_amount(value.call("Credit"))
          @problems << Problem.new(number, "Debit", "montant illisible : #{value.call("Debit")}") if debit.nil?
          @problems << Problem.new(number, "Credit", "montant illisible : #{value.call("Credit")}") if credit.nil?
          return if debit.nil? || credit.nil?
        else
          amount = Fec.parse_amount(value.call("Montant"))
          sens = value.call("Sens").strip.upcase
          if amount.nil?
            @problems << Problem.new(number, "Montant", "montant illisible : #{value.call("Montant")}")
            return
          end
          case sens
          when "D", "+1", "1" then debit, credit = amount, zero
          when "C", "-1"      then debit, credit = zero, amount
          else
            @problems << Problem.new(number, "Sens", "sens illisible : #{sens}")
            return
          end
        end
        # Débit et crédit sur la même ligne : leur solde (l'arrêté ne
        # l'interdit pas, certains logiciels le produisent).
        net = debit - credit
        net >= zero ? {net, zero} : {zero, -net}
      end
    end
  end
end
