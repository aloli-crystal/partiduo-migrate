# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # Rapport de réconciliation (ADR-001 D5) : balance générale, balance âgée
  # des tiers, totaux par journal et par période, calculés *avant* depuis
  # la source (traduite par les correspondances de la reprise) et *après*
  # en relisant l'instance par le contrat `Partiduo::Api`. Tout écart, même
  # d'un centime, est un échec.
  module Reconciliation
    ZERO = BigDecimal.new(0)

    # Totaux d'une clé : débit, crédit, nombre (lignes pour un compte,
    # écritures pour un journal ou une période).
    struct Totals
      getter debit : BigDecimal
      getter credit : BigDecimal
      getter count : Int32

      def initialize(@debit = ZERO, @credit = ZERO, @count = 0)
      end

      def add(debit : BigDecimal, credit : BigDecimal, count : Int32 = 1) : Totals
        Totals.new(@debit + debit, @credit + credit, @count + count)
      end

      def balance : BigDecimal
        debit - credit
      end

      def ==(other : Totals) : Bool
        debit == other.debit && credit == other.credit && count == other.count
      end
    end

    # Balance âgée d'un tiers : reste dû et ses tranches (montants signés
    # débit − crédit, règles de `Partiduo::Api::Accounting.account_statement`).
    struct Ageing
      getter not_due : BigDecimal
      getter days_1_30 : BigDecimal
      getter days_31_60 : BigDecimal
      getter over_60 : BigDecimal

      def initialize(@not_due = ZERO, @days_1_30 = ZERO, @days_31_60 = ZERO, @over_60 = ZERO)
      end

      def add(amount : BigDecimal, days : Int64) : Ageing
        if days <= 0
          Ageing.new(@not_due + amount, @days_1_30, @days_31_60, @over_60)
        elsif days <= 30
          Ageing.new(@not_due, @days_1_30 + amount, @days_31_60, @over_60)
        elsif days <= 60
          Ageing.new(@not_due, @days_1_30, @days_31_60 + amount, @over_60)
        else
          Ageing.new(@not_due, @days_1_30, @days_31_60, @over_60 + amount)
        end
      end

      def remaining : BigDecimal
        not_due + days_1_30 + days_31_60 + over_60
      end

      def values : Array(BigDecimal)
        [not_due, days_1_30, days_31_60, over_60, remaining]
      end

      def ==(other : Ageing) : Bool
        values == other.values
      end
    end

    # Chiffres d'un côté (avant ou après).
    class Figures
      getter accounts = Hash(String, Totals).new(Totals.new)
      getter journals = Hash(String, Totals).new(Totals.new)
      getter periods = Hash(String, Totals).new(Totals.new)
      getter ageing = {} of String => Ageing
      getter labels = {} of String => String
      property entries = 0
      property total = Totals.new
    end

    def self.period_key(date : Time) : String
      date.to_s("%Y-%m")
    end

    # Chiffres de la source, traduits par `mapping` (comptes, journaux,
    # fiches) pour être comparables à ceux de l'instance.
    def self.before(dataset : Source::Dataset, mapping : Mapping, as_of : Time) : Figures
      figures = Figures.new
      dataset.entries.each do |entry|
        journal = mapping.journal(entry.journal_code)
        figures.entries += 1
        figures.journals[journal] = figures.journals[journal].add(entry.total_debit, entry.total_credit)
        period = period_key(entry.date)
        figures.periods[period] = figures.periods[period].add(entry.total_debit, entry.total_credit)
        figures.total = figures.total.add(entry.total_debit, entry.total_credit)
        entry.each_line do |line|
          account = mapping.account(line.account)
          figures.accounts[account] = figures.accounts[account].add(line.debit, line.credit)
          figures.labels[account] ||= line.account_label
        end
      end
      source_ageing(dataset, mapping, as_of).each { |code, ageing| figures.ageing[code] = ageing }
      figures
    end

    # Tiers suivis en balance âgée : fiches citées sur un compte de tiers
    # (classe 4).
    def self.party?(account : String) : Bool
      account.starts_with?('4')
    end

    # Balance âgée de la source, avec les règles du relevé de l'instance :
    # éléments ouverts = lignes non lettrées, et reliquat de chaque lettrage
    # partiel (écart de toutes ses lignes) daté de la plus ancienne
    # référence (échéance, sinon date) des lignes du tiers dans ce lettrage.
    def self.source_ageing(dataset : Source::Dataset, mapping : Mapping, as_of : Time) : Hash(String, Ageing)
      differences = Hash({String, String}, BigDecimal).new(ZERO)
      dataset.entries.each do |entry|
        entry.each_line do |line|
          letter = line.letter || next
          key = {mapping.account(line.account), letter}
          differences[key] += line.signed
        end
      end
      parties = Set(String).new
      rows = Hash(String, Array({Source::Entry, Source::Line})).new { |hash, key| hash[key] = [] of {Source::Entry, Source::Line} }
      dataset.entries.each do |entry|
        entry.each_line do |line|
          code = mapping.card(line.aux) || next
          rows[code] << {entry, line}
          parties << code if party?(mapping.account(line.account))
        end
      end
      result = {} of String => Ageing
      parties.each do |code|
        ageing = Ageing.new
        partials = {} of {String, String} => Time
        rows[code].each do |(entry, line)|
          reference = entry.due_date || entry.date
          if letter = line.letter
            key = {mapping.account(line.account), letter}
            next if differences[key].zero?
            partials[key] = [partials[key]? || reference, reference].min
          else
            ageing = ageing.add(line.signed, (as_of - reference).days)
          end
        end
        partials.each { |key, reference| ageing = ageing.add(differences[key], (as_of - reference).days) }
        result[code] = ageing
      end
      result
    end

    PAGE = 500

    # Chiffres relus dans l'instance par le contrat.
    def self.after(as_of : Time, actor : Partiduo::Api::Actor = Partiduo::Api::Actor.system) : Figures
      figures = Figures.new
      parties = Set(String).new
      offset = 0
      loop do
        query = Partiduo::Api::Accounting::EntryQuery.new(limit: PAGE, offset: offset)
        page = Partiduo::Api::Accounting.entries(actor, query)
        page.each do |entry|
          debit = entry.total_debit
          credit = entry.total_credit
          figures.entries += 1
          figures.journals[entry.ledger_code] = figures.journals[entry.ledger_code].add(debit, credit)
          period = period_key(entry.date)
          figures.periods[period] = figures.periods[period].add(debit, credit)
          figures.total = figures.total.add(debit, credit)
          entry_lines = entry.lines
          entry_lines.each do |line|
            figures.accounts[line.account_number] = figures.accounts[line.account_number].add(line.debit, line.credit)
            figures.labels[line.account_number] ||= line.account_label
            code = line.card_code
            parties << code if code && party?(line.account_number)
          end
        end
        break if page.size < PAGE
        offset += PAGE
      end
      parties.each do |code|
        statement = Partiduo::Api::Accounting.account_statement(actor,
          Partiduo::Api::Accounting::StatementQuery.new(card: code, as_of: as_of))
        ageing = statement.ageing
        figures.ageing[code] = Ageing.new(ageing.not_due, ageing.days_1_30, ageing.days_31_60, ageing.over_60)
      end
      figures
    end

    # Ligne de comparaison : clé, libellé, valeurs avant et après.
    record Row, key : String, label : String, before : Array(BigDecimal), after : Array(BigDecimal) do
      def differences : Array(BigDecimal)
        before.zip(after).map { |(left, right)| right - left }
      end

      def ok? : Bool
        differences.all?(&.zero?)
      end
    end

    # Comparaison complète.
    class Comparison
      getter before : Figures
      getter after : Figures
      getter as_of : Time

      def initialize(@before : Figures, @after : Figures, @as_of : Time)
      end

      def accounts : Array(Row)
        rows(before.accounts, after.accounts, true)
      end

      def journals : Array(Row)
        rows(before.journals, after.journals, false)
      end

      def periods : Array(Row)
        rows(before.periods, after.periods, false)
      end

      def ageing : Array(Row)
        keys = (before.ageing.keys + after.ageing.keys).uniq.sort!
        empty = Ageing.new
        keys.map do |key|
          Row.new(key, "", (before.ageing[key]? || empty).values, (after.ageing[key]? || empty).values)
        end
      end

      def totals : Row
        Row.new("total", "", totals_of(before), totals_of(after))
      end

      def sections : Array({String, Array(Row)})
        [{"balance générale", accounts}, {"balance âgée", ageing}, {"journaux", journals}, {"périodes", periods},
         {"total", [totals]}]
      end

      def failures : Array({String, Row})
        sections.flat_map { |(name, rows)| rows.reject(&.ok?).map { |row| {name, row} } }
      end

      def ok? : Bool
        failures.empty?
      end

      private def totals_of(figures : Figures) : Array(BigDecimal)
        [BigDecimal.new(figures.entries), figures.total.debit, figures.total.credit]
      end

      private def rows(left : Hash(String, Totals), right : Hash(String, Totals), with_label : Bool) : Array(Row)
        (left.keys + right.keys).uniq.sort!.map do |key|
          a = left[key]? || Totals.new
          b = right[key]? || Totals.new
          label = with_label ? (after.labels[key]? || before.labels[key]? || "") : ""
          Row.new(key, label, values(a, with_label), values(b, with_label))
        end
      end

      private def values(totals : Totals, balance : Bool) : Array(BigDecimal)
        list = [BigDecimal.new(totals.count), totals.debit, totals.credit]
        list << totals.balance if balance
        list
      end
    end
  end
end
