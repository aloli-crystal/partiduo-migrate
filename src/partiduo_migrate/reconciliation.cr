# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # Rapport de réconciliation (ADR-001 D5) : balance générale, balance âgée
  # des tiers, totaux par journal et par période, calculés *avant* depuis
  # la source (traduite par les correspondances de la reprise) et *après*
  # par les éditions de l'instance (lot 3, contrat `Partiduo::Api`) :
  # balance générale (`trial_balance`), balance âgée (`aged_balance`),
  # journaux (`journals`), FEC réexporté puis relu (`fec`), bilan et compte
  # de résultat (`financial_statement`, à titre d'information). Tout écart,
  # même d'un centime, est un échec.
  module Reconciliation
    ZERO = BigDecimal.new(0)

    alias Acc = Partiduo::Api::Accounting

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

    # Chiffres d'un côté (avant ou après). Après : `fec_accounts` et
    # `fec_entries` viennent du FEC réexporté par l'instance et relu par
    # `Fec::Reader` ; `trial_delta` (débit − crédit de la balance) et
    # `result` (produits − charges) de la balance générale ; `statements`
    # (rubrique → montant) et `unmapped` (comptes qu'aucune rubrique ne
    # reprend) du bilan et du compte de résultat, pour information.
    class Figures
      getter accounts = Hash(String, Totals).new(Totals.new)
      getter journals = Hash(String, Totals).new(Totals.new)
      getter periods = Hash(String, Totals).new(Totals.new)
      getter ageing = {} of String => Ageing
      getter labels = {} of String => String
      getter fec_accounts = Hash(String, Totals).new(Totals.new)
      # Analytique : débit et crédit par poste (`plan/poste`), imputations
      # reprises (avant) face aux balances analytiques de l'instance (après).
      getter analytic = Hash(String, Totals).new(Totals.new)
      getter statements = [] of {String, BigDecimal}
      getter unmapped = [] of String
      property entries = 0
      property total = Totals.new
      property fec_entries = 0
      property trial_delta = ZERO
      property result : BigDecimal? = nil

      # Résultat (produits − charges) : donné par la balance de l'instance,
      # sinon calculé sur les comptes des classes 6 et 7.
      def result! : BigDecimal
        result || accounts.select { |number, _| number.starts_with?('6') || number.starts_with?('7') }
          .sum(ZERO) { |_, totals| totals.credit - totals.debit }
      end
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
      mapping.analytic_rows.each do |row|
        plan, code = mapping.analytic_posts[{row.plan, row.post}]? || {row.plan, row.post}
        key = "#{plan}/#{code}"
        figures.analytic[key] = figures.analytic[key].add(row.debit ? row.amount : ZERO, row.debit ? ZERO : row.amount, 0)
      end
      figures
    end

    # Tiers suivis en balance âgée : fiches citées sur un compte de tiers
    # (classe 4).
    def self.party?(account : String) : Bool
      account.starts_with?('4')
    end

    # Lettrage de la source : compte (traduit), code, compte auxiliaire
    # quand le code est propre à chaque tiers, lignes `{écriture, rang}`.
    record MatchingGroup, account : String, letter : String, aux : String?, refs : Array({Int32, Int32}) do
      def reference : String
        aux.try { |code| "#{account} #{code} #{letter}" } || "#{account} #{letter}"
      end
    end

    # Lettrages de la source : lignes d'un même compte et d'un même code de
    # lettrage. Beaucoup de logiciels (Sage, EBP, Cegid…) lettrent au niveau
    # du compte auxiliaire et réutilisent les mêmes codes d'un tiers à
    # l'autre : un code porté par plusieurs comptes auxiliaires, dont chacun
    # a des lignes au débit et au crédit, forme un lettrage par tiers
    # (DECISIONS D-MIG-013). Sinon (base d'origine, lettrage d'un compte général),
    # le code forme un seul lettrage.
    def self.matching_groups(dataset : Source::Dataset, mapping : Mapping) : Array(MatchingGroup)
      groups = Hash({String, String}, Array({Int32, Int32})).new { |hash, key| hash[key] = [] of {Int32, Int32} }
      dataset.entries.each_with_index do |entry, index|
        entry.lines.each_with_index do |line, position|
          letter = line.letter || next
          groups[{mapping.account(line.account), letter}] << {index, position}
        end
      end
      line_at = ->(ref : {Int32, Int32}) { dataset.entries[ref[0]].lines[ref[1]] }
      two_sided = ->(refs : Array({Int32, Int32})) do
        sides = refs.map { |ref| line_at.call(ref).debit > 0 }.uniq!
        sides.size == 2
      end
      result = [] of MatchingGroup
      groups.each do |(account, letter), refs|
        by_aux = refs.group_by { |ref| line_at.call(ref).aux }
        if by_aux.size > 1 && by_aux.values.all? { |list| two_sided.call(list) }
          by_aux.each { |aux, list| result << MatchingGroup.new(account, letter, aux, list) }
        else
          result << MatchingGroup.new(account, letter, nil, refs)
        end
      end
      result
    end

    # Balance âgée de la source au jour `as_of`, avec les règles de la
    # balance âgée de l'instance (`aged_balance`) : seules comptent les
    # écritures datées au plus tard `as_of` ; éléments ouverts = lignes non
    # lettrées, et reliquat de chaque lettrage partiel (écart de ses lignes
    # arrêtées à `as_of`) daté de la plus ancienne référence (échéance,
    # sinon date) des lignes du tiers dans ce lettrage.
    def self.source_ageing(dataset : Source::Dataset, mapping : Mapping, as_of : Time) : Hash(String, Ageing)
      group_of = {} of {Int32, Int32} => Int32
      differences = [] of BigDecimal
      matching_groups(dataset, mapping).each_with_index do |group, number|
        differences << group.refs.sum(ZERO) do |(index, position)|
          entry = dataset.entries[index]
          entry.date <= as_of ? entry.lines[position].signed : ZERO
        end
        group.refs.each { |ref| group_of[ref] = number }
      end
      parties = Set(String).new
      rows = Hash(String, Array({Source::Entry, Source::Line, {Int32, Int32}})).new do |hash, key|
        hash[key] = [] of {Source::Entry, Source::Line, {Int32, Int32}}
      end
      dataset.entries.each_with_index do |entry, index|
        entry.lines.each_with_index do |line, position|
          code = mapping.card(line.aux) || next
          parties << code if party?(mapping.account(line.account))
          rows[code] << {entry, line, {index, position}} if entry.date <= as_of
        end
      end
      result = {} of String => Ageing
      parties.each do |code|
        ageing = Ageing.new
        partials = {} of Int32 => Time
        rows[code].each do |(entry, line, ref)|
          reference = entry.due_date || entry.date
          if number = group_of[ref]?
            next if differences[number].zero?
            partials[number] = [partials[number]? || reference, reference].min
          else
            ageing = ageing.add(line.signed, (as_of - reference).days)
          end
        end
        partials.each { |number, reference| ageing = ageing.add(differences[number], (as_of - reference).days) }
        result[code] = ageing
      end
      result
    end

    # Natures de fiches parcourues pour la balance âgée : toutes sauf les
    # articles (un tiers de la source peut être repris en salarié, en
    # banque ou en « autre »).
    PARTY_KINDS = Partiduo::Api::Cards::KINDS - %w[item]

    # Chiffres relus dans l'instance par ses éditions (lot 3), de
    # `date_from` à `date_to` (les dates extrêmes de la source).
    def self.after(as_of : Time, actor : Partiduo::Api::Actor = Partiduo::Api::Actor.system,
                   date_from : Time? = nil, date_to : Time? = nil) : Figures
      figures = Figures.new
      from = date_from || as_of
      to = date_to || as_of

      balance = Acc.trial_balance(actor, Acc::TrialBalanceQuery.new(date_from: from, date_to: to))
      balance.rows.each do |row|
        figures.accounts[row.number] = Totals.new(row.debit, row.credit, row.lines)
        figures.labels[row.number] = row.label
      end
      figures.trial_delta = balance.delta
      figures.result = balance.summary.result

      journals = Acc.journals(actor, Acc::JournalQuery.new(date_from: from, date_to: to))
      journals.ledgers.each do |ledger|
        next if ledger.entries.empty?
        figures.journals[ledger.ledger_code] = Totals.new(ledger.total_debit, ledger.total_credit, ledger.entries.size)
        ledger.months.each do |month|
          figures.periods[month.key] = figures.periods[month.key].add(month.debit, month.credit, month.entries)
        end
      end
      figures.entries = journals.entries
      figures.total = Totals.new(journals.total_debit, journals.total_credit, journals.entries)

      PARTY_KINDS.each do |kind|
        parties = Acc.auxiliary_balance(actor, Acc::AuxiliaryBalanceQuery.new(date_from: from, date_to: to, kind: kind,
          account: "4")).rows.map(&.card_code).to_set
        next if parties.empty?
        aged = Acc.aged_balance(actor, Acc::AgedBalanceQuery.new(as_of: as_of, kind: kind))
        aged.rows.each do |row|
          next unless parties.includes?(row.card_code)
          ageing = row.ageing
          figures.ageing[row.card_code] = Ageing.new(ageing.not_due, ageing.days_1_30, ageing.days_31_60, ageing.over_60)
        end
      end

      reexport(figures, actor, from, to)
      statements(figures, actor, from, to)
      analytic(figures, actor, from, to)
      figures
    end

    # Balances analytiques de l'instance, plan par plan (module actif).
    private def self.analytic(figures : Figures, actor : Partiduo::Api::Actor, from : Time, to : Time) : Nil
      return unless Partiduo::Api::Modules.get(actor, "ANALYTIC").active
      Partiduo::Api::Analytic.plans(actor).each do |plan|
        balance = Partiduo::Api::Analytic.balance(actor, Partiduo::Api::Analytic::ReportQuery.new(plan_id: plan.id,
          date_from: from, date_to: to))
        balance.rows.each do |row|
          next if row.amounts.debit.zero? && row.amounts.credit.zero?
          figures.analytic["#{plan.name}/#{row.post.code}"] = Totals.new(row.amounts.debit, row.amounts.credit, 0)
        end
      end
    rescue Partiduo::Api::NotFound
      nil
    end

    # FEC de chaque exercice de l'instance qui recouvre la période, relu par
    # le lecteur de la reprise : lignes, débit et crédit par compte.
    private def self.reexport(figures : Figures, actor : Partiduo::Api::Actor, from : Time, to : Time) : Nil
      Partiduo::Api::Core.fiscal_years(actor).reverse_each do |year|
        starts = year.starts_on || next
        ends = year.ends_on || next
        next if ends < from || starts > to
        result = Acc.fec(actor, Acc::FecQuery.new(fiscal_year_id: year.id, encoding: Acc::FecEncoding::Utf8))
        file = result.value? || next
        dataset = Fec::Reader.new("UTF-8").read(file.content, file.filename)
        figures.fec_entries += dataset.entries.size
        dataset.entries.each do |entry|
          entry.each_line do |line|
            figures.fec_accounts[line.account] = figures.fec_accounts[line.account].add(line.debit, line.credit)
          end
        end
      end
    end

    # Bilan et compte de résultat du régime de l'instance, pour information.
    private def self.statements(figures : Figures, actor : Partiduo::Api::Actor, from : Time, to : Time) : Nil
      unmapped = Set(String).new
      {Acc::StatementKind::BalanceSheet    => %w[total_assets total_liabilities],
       Acc::StatementKind::IncomeStatement => %w[net_result]}.each do |kind, codes|
        view = Acc.financial_statement(actor, Acc::FinancialStatementQuery.new(kind: kind, date_from: from, date_to: to,
          compare: false))
        codes.each { |code| figures.statements << {"#{view.regime}.#{kind.code}.#{code}", view.line(code).try(&.net) || ZERO} }
        figures.statements << {"#{view.regime}.#{kind.code}.difference", view.difference}
        view.unmapped.each { |account| unmapped << account.number }
      rescue Partiduo::Api::NotFound
        next
      end
      figures.unmapped.concat(unmapped.to_a.sort!)
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

    # Tableau de la comparaison : clé (`migrate.sections.<key>`), colonnes
    # (`migrate.columns.<colonne>`, la première est un nombre), libellé par
    # ligne ou non, lignes.
    record Section, key : String, columns : Array(String), rows : Array(Row), labelled : Bool = false

    # Contrôle de lecture de la source : chiffres relevés indépendamment du
    # modèle (`Source::Control`) comparés à ceux du modèle, clés de la
    # source. Vide si la source n'a pas de contrôle.
    def self.reading(dataset : Source::Dataset) : Array(Section)
      control = dataset.control || return [] of Section
      model = Source::Control.of(dataset, control.sides?)
      columns = control.sides? ? %w[lines debit credit balance] : %w[lines balance]
      values = ->(tally : Source::Tally) do
        list = [BigDecimal.new(tally.count)]
        list.concat([tally.debit, tally.credit]) if control.sides?
        list << tally.balance
        list
      end
      pairs = {"reading_accounts" => {control.accounts, model.accounts},
               "reading_journals" => {control.journals, model.journals},
               "reading_periods"  => {control.periods, model.periods}}
      pairs.map do |key, (left, right)|
        rows = (left.keys + right.keys).uniq.sort!.map do |code|
          Row.new(code, "", values.call(left[code]? || Source::Tally.new), values.call(right[code]? || Source::Tally.new))
        end
        Section.new(key, columns, rows)
      end
    end

    # Comparaison complète : contrôle de lecture de la source (`reading`),
    # puis source traduite (avant) et instance (après).
    class Comparison
      getter before : Figures
      getter after : Figures
      getter as_of : Time
      getter reading : Array(Section)

      AGEING_COLUMNS = %w[not_due days_1_30 days_31_60 over_60 remaining]

      def initialize(@before : Figures, @after : Figures, @as_of : Time, @reading = [] of Section)
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

      # FEC réexporté par l'instance et relu, face à la balance de la source.
      def fec_accounts : Array(Row)
        rows(before.accounts, after.fec_accounts, true)
      end

      # Contrôles des éditions : balance équilibrée, résultat de la balance,
      # nombre d'écritures du FEC réexporté.
      def editions : Array(Row)
        [Row.new("trial_balance_delta", "", [ZERO], [after.trial_delta]),
         Row.new("result", "", [before.result!], [after.result!]),
         Row.new("fec_entries", "", [BigDecimal.new(before.entries)], [BigDecimal.new(after.fec_entries)])]
      end

      def sections : Array(Section)
        [Section.new("accounts", %w[lines debit credit balance], accounts, labelled: true),
         Section.new("ageing", AGEING_COLUMNS, ageing),
         Section.new("journals", %w[entries debit credit], journals),
         Section.new("periods", %w[entries debit credit], periods),
         Section.new("total", %w[entries debit credit], [totals]),
         Section.new("fec_accounts", %w[lines debit credit balance], fec_accounts, labelled: true),
         Section.new("editions", %w[value], editions),
         Section.new("analytic", %w[debit credit balance], analytic)] + reading
      end

      # Analytique par poste : débit, crédit, solde.
      def analytic : Array(Row)
        (before.analytic.keys + after.analytic.keys).uniq.sort!.map do |key|
          a = before.analytic[key]? || Totals.new
          b = after.analytic[key]? || Totals.new
          Row.new(key, "", [a.debit, a.credit, a.balance], [b.debit, b.credit, b.balance])
        end
      end

      def section(key : String) : Section?
        sections.find(&.key.==(key))
      end

      def failures : Array({Section, Row})
        sections.flat_map { |section| section.rows.reject(&.ok?).map { |row| {section, row} } }
      end

      def reading_ok? : Bool
        reading.all? { |section| section.rows.all?(&.ok?) }
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
