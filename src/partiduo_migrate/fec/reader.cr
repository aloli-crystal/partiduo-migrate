# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module Fec
    # Défaut d'un FEC : ligne du fichier (1 = en-tête), zone, message.
    record Problem, line : Int32, column : String, message : String do
      def to_s(io : IO) : Nil
        if column.empty?
          io << PartiduoMigrate.t("fec.problem", line: line, message: message)
        else
          io << PartiduoMigrate.t("fec.problem_column", line: line, column: column, message: message)
        end
      end
    end

    # Lecture d'un FEC en `Source::Dataset` : encodage et séparateur
    # reconnus, zones contrôlées ligne à ligne, lignes regroupées en
    # écritures par journal et numéro d'écriture. Les défauts sont réunis
    # dans `problems` ; un fichier qui en a n'est pas importé. Les montants
    # bruts de chaque ligne sont totalisés au fil de la lecture
    # (`Source::Control`) pour le contrôle de lecture du rapport.
    class Reader
      getter problems = [] of Problem
      # Avertissements qui n'empêchent pas la lecture (encodage douteux).
      getter warnings = [] of String
      getter encoding = ""
      getter separator = '\t'

      def initialize(@forced_encoding : String? = nil)
      end

      def read_file(path : String) : Source::Dataset
        read(File.read(path).to_slice, File.basename(path))
      end

      def read(bytes : Bytes, name : String = "FEC") : Source::Dataset
        dataset = Source::Dataset.new(PartiduoMigrate.t("source.fec_description", name: name))
        dataset.file_name = name
        control = Source::Control.new(sides: false)
        dataset.control = control
        text, @encoding = Encoding.decode(bytes, @forced_encoding)
        @warnings << PartiduoMigrate.t("fec.c1_characters", encoding: @encoding) if Encoding.c1?(text)
        lines = text.split(/\r\n|\n|\r/)
        while lines.last?.try(&.strip.empty?)
          lines.pop
        end
        header = lines.first?
        if header.nil? || header.strip.empty?
          @problems << Problem.new(1, "", PartiduoMigrate.t("fec.empty_file"))
          return dataset
        end
        @separator = detect_separator(header) || return dataset
        columns = header.split(@separator).map { |value| unquote(value) }
        # Séparateur terminal sur l'en-tête : toléré sur chaque ligne.
        trailing = columns.size > 1 && columns.last.empty?
        columns.pop if trailing
        index = column_index(columns) || return dataset

        read_lines(dataset, control, lines, columns.size, index, trailing)
        check_balance(dataset)
        dataset
      end

      private def read_lines(dataset : Source::Dataset, control : Source::Control, lines : Array(String), size : Int32,
                             index : Hash(String, Int32), trailing : Bool) : Nil
        by_key = {} of {String, String} => Source::Entry
        lines.each_with_index do |raw, position|
          next if position.zero? || raw.strip.empty?
          number = position + 1
          fields = raw.split(@separator).map { |value| unquote(value) }
          # Un séparateur terminal (annoncé par l'en-tête) donne une zone
          # finale vide, tolérée ; toute autre zone en trop décale les
          # suivantes (séparateur dans un libellé) : la ligne est refusée.
          fields.pop if trailing && fields.size == size + 1 && fields.last.empty?
          if fields.size != size
            @problems << Problem.new(number, "", PartiduoMigrate.t("fec.field_count", total: fields.size, expected: size))
            next
          end
          read_line(dataset, control, by_key, fields, index, number)
        end
      end

      private def check_balance(dataset : Source::Dataset) : Nil
        dataset.entries.each do |entry|
          next if entry.balanced?
          @problems << Problem.new(entry.lines.first?.try(&.row.to_i32) || 0, "EcritureNum",
            PartiduoMigrate.t("fec.unbalanced", entry: entry.reference, debit: Fec.format_amount(entry.total_debit),
              credit: Fec.format_amount(entry.total_credit)))
        end
      end

      private def detect_separator(header : String) : Char?
        return '\t' if header.includes?('\t')
        return '|' if header.includes?('|')
        @problems << Problem.new(1, "", PartiduoMigrate.t("fec.unknown_separator"))
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
          missing << PartiduoMigrate.t("fec.amount_columns")
        end
        missing.each { |name| @problems << Problem.new(1, name, PartiduoMigrate.t("fec.missing_column")) }
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

      private def read_line(dataset : Source::Dataset, control : Source::Control, by_key, values : Array(String),
                            index : Hash(String, Int32), number : Int32) : Nil
        fields = Fields.new(values, index, number, @problems)
        %w[JournalCode EcritureNum CompteNum EcritureDate].each do |name|
          @problems << Problem.new(number, name, PartiduoMigrate.t("fec.empty_field")) if fields[name].empty?
        end
        entry_date = fields.date("EcritureDate")
        fields.date("ValidDate")
        line, raw_debit, raw_credit = build_line(fields, number) || return
        return if entry_date.nil? || {"JournalCode", "EcritureNum", "CompteNum"}.any? { |name| fields[name].empty? }
        # Contrôle de lecture : montants bruts, avant le solde de la ligne ;
        # une ligne sans effet (débit = crédit) est ignorée des deux côtés.
        if raw_debit != raw_credit
          control.add(fields["CompteNum"], fields["JournalCode"], Source::Control.period_key(entry_date),
            Source::Tally.new.add(raw_debit, raw_credit))
        end
        if line.zero?
          dataset.zero_lines += 1
          return
        end
        store(dataset, by_key, fields, entry_date, line)
      end

      # Ligne du modèle, et montants bruts de la zone (débit, crédit).
      private def build_line(fields : Fields, number : Int32) : {Source::Line, BigDecimal, BigDecimal}?
        letter_date = fields.date("DateLet")
        raw_debit, raw_credit = amounts(fields, number) || return
        currency_amount = nil
        unless (text = fields["Montantdevise"]).empty?
          currency_amount = Fec.parse_amount(text)
          if currency_amount.nil?
            @problems << Problem.new(number, "Montantdevise", PartiduoMigrate.t("fec.unreadable_amount", value: text))
          end
        end
        # Débit et crédit sur la même ligne : leur solde (l'arrêté ne
        # l'interdit pas, certains logiciels le produisent).
        zero = BigDecimal.new(0)
        net = raw_debit - raw_credit
        debit, credit = net >= zero ? {net, zero} : {zero, -net}
        aux = fields["CompAuxNum"].presence
        line = Source::Line.new(
          account: fields["CompteNum"], account_label: fields["CompteLib"], aux: aux,
          aux_label: aux ? fields["CompAuxLib"] : nil, label: fields["EcritureLib"],
          debit: debit, credit: credit, letter: fields["EcritureLet"].presence, letter_date: letter_date,
          currency_amount: currency_amount, currency_code: fields["Idevise"].presence, row: number.to_i64,
        )
        {line, raw_debit, raw_credit}
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
            PartiduoMigrate.t("fec.date_mismatch", entry: entry.reference, date: Fec.format_date(entry_date),
              expected: Fec.format_date(entry.date)))
        end
        entry.due_date ||= due_date
        entry.lines << line
        dataset.journals[journal] ||= Source::Journal.new(journal, fields["JournalLib"])
        dataset.accounts[line.account] ||= Source::Account.new(line.account, line.account_label)
        line.aux.try { |code| dataset.parties[code] ||= fields["CompAuxLib"] }
      end

      # Débit et crédit bruts d'une ligne (zones `Debit` / `Credit`, ou
      # `Montant` et `Sens`), tels qu'écrits (négatifs compris) : le solde
      # de la ligne les remet chacun de son côté.
      private def amounts(fields : Fields, number : Int32) : {BigDecimal, BigDecimal}?
        value = ->(name : String) { fields[name] }
        zero = BigDecimal.new(0)
        if fields.has?("Debit")
          debit = Fec.parse_amount(value.call("Debit"))
          credit = Fec.parse_amount(value.call("Credit"))
          if debit.nil?
            @problems << Problem.new(number, "Debit", PartiduoMigrate.t("fec.unreadable_amount", value: value.call("Debit")))
          end
          if credit.nil?
            @problems << Problem.new(number, "Credit", PartiduoMigrate.t("fec.unreadable_amount", value: value.call("Credit")))
          end
          return if debit.nil? || credit.nil?
        else
          amount = Fec.parse_amount(value.call("Montant"))
          sens = value.call("Sens").strip.upcase
          if amount.nil?
            @problems << Problem.new(number, "Montant", PartiduoMigrate.t("fec.unreadable_amount", value: value.call("Montant")))
            return
          end
          case sens
          when "D", "+1", "1" then debit, credit = amount, zero
          when "C", "-1"      then debit, credit = zero, amount
          else
            @problems << Problem.new(number, "Sens", PartiduoMigrate.t("fec.unreadable_direction", value: sens))
            return
          end
        end
        {debit, credit}
      end
    end
  end
end
