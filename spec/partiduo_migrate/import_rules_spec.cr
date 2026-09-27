# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias B = PartiduoMigrate::SpecSupport::FecBuilder

# Deux ventes et leurs règlements ; le lettrage « A » est réutilisé pour
# chaque compte auxiliaire, comme le font la plupart des logiciels (Sage,
# EBP, Cegid) qui lettrent au niveau du compte de tiers.
private def reused_letters : Array(String)
  [
    B.row("VT", "1", "20240105", "411000", debit: "120,00", aux: "C1", letter: "A"),
    B.row("VT", "1", "20240105", "706000", credit: "100,00"),
    B.row("VT", "1", "20240105", "445710", credit: "20,00"),
    B.row("VT", "2", "20240106", "411000", debit: "240,00", aux: "C2", letter: "A"),
    B.row("VT", "2", "20240106", "706000", credit: "200,00"),
    B.row("VT", "2", "20240106", "445710", credit: "40,00"),
    B.row("BQ", "1", "20240120", "512000", debit: "120,00"),
    B.row("BQ", "1", "20240120", "411000", credit: "120,00", aux: "C1", letter: "A"),
    B.row("BQ", "2", "20240121", "512000", debit: "100,00"),
    B.row("BQ", "2", "20240121", "411000", credit: "100,00", aux: "C2", letter: "A"),
  ]
end

private def statement(code : String) : Partiduo::Api::Accounting::AccountStatementView
  Partiduo::Api::Accounting.account_statement(actor,
    Partiduo::Api::Accounting::StatementQuery.new(card: code, as_of: Time.utc(2024, 12, 31)))
end

describe "Règles de reprise d'un FEC" do
  it "lettre séparément un même code de lettrage porté par deux comptes auxiliaires" do
    PartiduoMigrate::SpecSupport.provision!
    migration = PartiduoMigrate::Migration.new(B.dataset(reused_letters))
    migration.run.should be_true
    migration.problems.should be_empty
    migration.counts["matchings"].should eq(2)
    # C1 soldé, C2 : reliquat de 140 du règlement partiel.
    statement("C1").remaining.should eq(BigDecimal.new(0))
    statement("C2").remaining.should eq(BigDecimal.new(140))
    comparison = migration.comparison.present!
    comparison.before.ageing["C1"].remaining.should eq(BigDecimal.new(0))
    comparison.before.ageing["C2"].over_60.should eq(BigDecimal.new(140))
  end

  it "déduit la nature des journaux et crée la fiche Banque du journal financier" do
    PartiduoMigrate::SpecSupport.provision!
    rows = reused_letters + [
      B.row("HA", "1", "20240110", "401000", credit: "60,00", aux: "F1"),
      B.row("HA", "1", "20240110", "606400", debit: "50,00"),
      B.row("HA", "1", "20240110", "445660", debit: "10,00"),
      B.row("OD", "1", "20240131", "641000", debit: "80,00"),
      B.row("OD", "1", "20240131", "421000", credit: "80,00"),
    ]
    PartiduoMigrate::Migration.new(B.dataset(rows)).run.should be_true
    kind = ->(code : String) { Partiduo::Api::Accounting.ledger_by_code(actor, code).kind.code }
    kind.call("VT").should eq("sale")
    kind.call("HA").should eq("purchase")
    kind.call("BQ").should eq("financial")
    kind.call("OD").should eq("misc")
    Partiduo::Api::Cards.card_by_code(actor, "F1").present!.kind.should eq("supplier")
    Partiduo::Api::Cards.card_by_code(actor, "C1").present!.kind.should eq("customer")
    # Type des comptes créés, d'après la classe du plan comptable général.
    Partiduo::Api::Accounting.account(actor, "411000").kind.code.should eq("asset")
    Partiduo::Api::Accounting.account(actor, "401000").kind.code.should eq("liability")
    Partiduo::Api::Accounting.account(actor, "706000").kind.code.should eq("income")
    Partiduo::Api::Accounting.account(actor, "606400").kind.code.should eq("expense")
  end

  it "crée l'exercice d'après la date de clôture du nom du FEC" do
    PartiduoMigrate::SpecSupport.provision!
    rows = [
      B.row("OD", "1", "20230915", "512000", debit: "10,00"),
      B.row("OD", "1", "20230915", "580000", credit: "10,00"),
      B.row("OD", "2", "20240315", "512000", debit: "5,00"),
      B.row("OD", "2", "20240315", "580000", credit: "5,00"),
    ]
    migration = PartiduoMigrate::Migration.new(B.dataset(rows, "123456789FEC20240630.txt"))
    migration.as_of.should eq(Time.utc(2024, 6, 30))
    migration.run.should be_true
    migration.counts["fiscal_years_created"].should eq(1)
    period = Partiduo::Api::Core.period_for(actor, Time.utc(2023, 7, 1)).present!
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 6, 30)).present!.fiscal_year_id.should eq(period.fiscal_year_id)
    Partiduo::Api::Core.period_for(actor, Time.utc(2023, 6, 30)).should be_nil
  end

  it "suit --fiscal-start plutôt que le nom du fichier" do
    PartiduoMigrate::SpecSupport.provision!
    rows = [
      B.row("OD", "1", "20240415", "512000", debit: "10,00"),
      B.row("OD", "1", "20240415", "580000", credit: "10,00"),
    ]
    PartiduoMigrate::Migration.new(B.dataset(rows), fiscal_start_month: 4).run.should be_true
    period = Partiduo::Api::Core.period_for(actor, Time.utc(2024, 4, 1)).present!
    Partiduo::Api::Core.period_for(actor, Time.utc(2025, 3, 31)).present!.fiscal_year_id.should eq(period.fiscal_year_id)
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 3, 31)).try(&.fiscal_year_id).should_not eq(period.fiscal_year_id)
  end

  it "tronque une pièce trop longue à 40 caractères et la rend unique dans le journal" do
    PartiduoMigrate::SpecSupport.provision!
    long = "P" * 45
    rows = [
      B.row("OD", "1", "20240105", "512000", debit: "10,00", receipt: long),
      B.row("OD", "1", "20240105", "580000", credit: "10,00", receipt: long),
      B.row("OD", "2", "20240106", "512000", debit: "20,00", receipt: long),
      B.row("OD", "2", "20240106", "580000", credit: "20,00", receipt: long),
    ]
    migration = PartiduoMigrate::Migration.new(B.dataset(rows))
    migration.run.should be_true
    receipts = Partiduo::Api::Accounting.entries(actor).compact_map(&.receipt).sort!
    receipts.should eq(["P" * 38 + "-2", "P" * 40])
    migration.mapping.receipts.should eq([{"OD", long, "P" * 40}, {"OD", long, "P" * 38 + "-2"}])
  end

  it "ignore les lignes à zéro sans fausser la réconciliation" do
    PartiduoMigrate::SpecSupport.provision!
    rows = [
      B.row("OD", "1", "20240105", "512000", debit: "10,00"),
      B.row("OD", "1", "20240105", "471000"),
      B.row("OD", "1", "20240105", "580000", credit: "10,00"),
    ]
    dataset = B.dataset(rows)
    dataset.zero_lines.should eq(1)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    Partiduo::Api::Accounting.entries(actor).first.lines.size.should eq(2)
  end

  it "annule tout quand le socle refuse une écriture (déséquilibrée)" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = B.dataset([
      B.row("OD", "1", "20240105", "512000", debit: "10,00"),
      B.row("OD", "1", "20240105", "580000", credit: "10,00"),
      B.row("OD", "2", "20240106", "512000", debit: "5,00"),
      B.row("OD", "2", "20240106", "580000", credit: "5,00"),
    ])
    # Montant altéré après lecture : le lecteur l'aurait signalé, le socle
    # doit le refuser à son tour.
    entry = dataset.entries.last
    entry.lines[0] = entry.lines[0].copy_with(debit: BigDecimal.new("5.01"))
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_false
    migration.committed?.should be_false
    migration.problems.find! { |problem| problem.step == "entry" }.blocking.should be_true
    Partiduo::Api::Accounting.count_entries(actor).should eq(0)
    Partiduo::Api::Cards.card_by_code(actor, "C1").should be_nil
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 1, 5)).should be_nil
  end

  it "en mode strict, fait échouer une reprise qui n'a qu'un avertissement" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = B.dataset([
      B.row("OD", "1", "20240105", "512000", debit: "10,00"),
      B.row("OD", "1", "20240105", "580000", credit: "10,00"),
    ])
    dataset.entries.first.attachment = PartiduoMigrate::Source::Attachment.new("vide.pdf", "application/pdf", Bytes.empty)
    lenient = PartiduoMigrate::Migration.new(dataset, dry_run: true)
    lenient.run.should be_true
    warnings = lenient.problems.reject(&.blocking)
    warnings.map(&.step).should eq(["attachment"])

    strict = PartiduoMigrate::Migration.new(dataset, strict: true)
    strict.run.should be_false
    strict.failure_reason.should contain("1 anomalie(s) de reprise")
    Partiduo::Api::Accounting.count_entries(actor).should eq(0)
  end

  it "refuse une instance dont la Comptabilité est inactive" do
    PartiduoMigrate::SpecSupport.provision!
    modules = Partiduo::Api::Modules
    # Les pièces qui dépendent de la Comptabilité d'abord.
    5.times do
      modules.list(actor).select(&.active).each { |view| modules.deactivate(actor, view.code) }
    end
    modules.get(actor, "ACCOUNTING").active.should be_false
    expect_raises(Partiduo::Api::ModuleDisabled) { Partiduo::Api::Accounting.count_entries(actor) }
    migration = PartiduoMigrate::Migration.new(B.dataset(reused_letters))
    migration.run.should be_false
    migration.problems.first.message.should contain("Comptabilité inactif")
    migration.comparison.should be_nil
  end

  it "ne peut être menée par un utilisateur sans droits sur la Comptabilité" do
    PartiduoMigrate::SpecSupport.provision!
    reader = Partiduo::Api::Actor.user(1_i64, Set{"accounting.entry.read"})
    migration = PartiduoMigrate::Migration.new(B.dataset(reused_letters), actor: reader)
    # Le refus d'accès ne sort pas de la commande : anomalie « interne »
    # bloquante, transaction annulée, rapport écrit.
    migration.run.should be_false
    migration.committed?.should be_false
    problem = migration.problems.find! { |candidate| candidate.step == "internal" }
    problem.blocking.should be_true
    problem.reference.should start_with("Partiduo::Api::")
    dir = PartiduoMigrate::SpecSupport.report_dir
    PartiduoMigrate::Report.new(dir, migration).write
    File.read(File.join(dir, "anomalies.csv")).should contain("interne")
    Partiduo::Api::Accounting.count_entries(actor).should eq(0)
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end
end

describe PartiduoMigrate::Reconciliation do
  it "range la balance âgée par tranches aux bornes 0, 30 et 60 jours" do
    ageing = PartiduoMigrate::Reconciliation::Ageing.new
    one = BigDecimal.new(1)
    {-5_i64, 0_i64, 1_i64, 30_i64, 31_i64, 60_i64, 61_i64}.each { |days| ageing = ageing.add(one, days) }
    ageing.values.should eq([2, 2, 2, 1, 7].map { |value| BigDecimal.new(value) })
  end

  it "voit un écart d'un centime comme un échec" do
    left = PartiduoMigrate::Reconciliation::Figures.new
    right = PartiduoMigrate::Reconciliation::Figures.new
    left.accounts["512000"] = PartiduoMigrate::Reconciliation::Totals.new.add(BigDecimal.new("10.00"), BigDecimal.new(0))
    right.accounts["512000"] = PartiduoMigrate::Reconciliation::Totals.new.add(BigDecimal.new("10.01"), BigDecimal.new(0))
    comparison = PartiduoMigrate::Reconciliation::Comparison.new(left, right, Time.utc(2024, 12, 31))
    comparison.ok?.should be_false
    section, row = comparison.failures.first
    section.key.should eq("accounts")
    row.differences.should eq([0, "0.01", 0, "0.01"].map { |value| BigDecimal.new(value) })
  end

  it "voit un compte présent d'un seul côté comme un écart" do
    left = PartiduoMigrate::Reconciliation::Figures.new
    right = PartiduoMigrate::Reconciliation::Figures.new
    right.journals["OD"] = PartiduoMigrate::Reconciliation::Totals.new.add(BigDecimal.new(0), BigDecimal.new(0))
    comparison = PartiduoMigrate::Reconciliation::Comparison.new(left, right, Time.utc(2024, 12, 31))
    comparison.failures.map(&.[0].key).should eq(["journals"])
  end

  it "date le reliquat d'un lettrage partiel de sa plus ancienne échéance" do
    dataset = B.dataset([
      B.row("VT", "1", "20241001", "411000", debit: "300,00", aux: "C1", letter: "B"),
      B.row("VT", "1", "20241001", "706000", credit: "300,00"),
      B.row("BQ", "1", "20241220", "512000", debit: "100,00"),
      B.row("BQ", "1", "20241220", "411000", credit: "100,00", aux: "C1", letter: "B"),
      B.row("VT", "2", "20241215", "411000", debit: "50,00", aux: "C1"),
      B.row("VT", "2", "20241215", "706000", credit: "50,00"),
    ])
    dataset.entries.first.due_date = Time.utc(2024, 11, 15)
    ageing = PartiduoMigrate::Reconciliation.source_ageing(dataset, PartiduoMigrate::Mapping.new, Time.utc(2024, 12, 31))
    ageing["C1"].days_31_60.should eq(BigDecimal.new(200))
    ageing["C1"].days_1_30.should eq(BigDecimal.new(50))
    ageing["C1"].remaining.should eq(BigDecimal.new(250))
  end
end
