# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Réconciliation par les éditions de l'instance (lot 3) : balance générale,
# balance âgée, journaux, FEC réexporté et relu, bilan et compte de
# résultat.

private alias Reconciliation = PartiduoMigrate::Reconciliation

describe "Réconciliation par les éditions" do
  it "rapproche la source des éditions et du FEC réexporté" do
    PartiduoMigrate::SpecSupport.provision!
    migration = PartiduoMigrate::Migration.new(demo_dataset)
    migration.run.should be_true
    comparison = migration.comparison.present!
    comparison.ok?.should be_true

    editions = comparison.section("editions").present!
    editions.rows.map(&.key).should eq(%w[trial_balance_delta result fec_entries])
    editions.rows.all?(&.ok?).should be_true
    comparison.after.fec_entries.should eq(133)
    comparison.after.trial_delta.should eq(0)
    comparison.after.result!.should eq(comparison.before.result!)

    fec = comparison.section("fec_accounts").present!
    fec.rows.size.should eq(comparison.before.accounts.size)
    fec.rows.all?(&.ok?).should be_true
    comparison.after.fec_accounts["510001"].should eq(comparison.before.accounts["510001"])

    keys = comparison.after.statements.map(&.[0])
    keys.should contain("fr.balance_sheet.total_assets")
    keys.should contain("fr.income_statement.net_result")
    net = comparison.after.statements.find! { |(key, _)| key == "fr.income_statement.net_result" }[1]
    difference = comparison.after.statements.find! { |(key, _)| key == "fr.income_statement.difference" }[1]
    (net + difference).should eq(comparison.after.result!)
  end

  it "arrête la balance âgée des deux côtés à la date de référence" do
    PartiduoMigrate::SpecSupport.provision!
    migration = PartiduoMigrate::Migration.new(demo_dataset, as_of: Time.utc(2024, 6, 30), dry_run: true)
    migration.run.should be_true
    comparison = migration.comparison.present!
    comparison.ok?.should be_true
    full = Reconciliation.source_ageing(demo_dataset, migration.mapping, Time.utc(2024, 12, 31))
    comparison.before.ageing.should_not eq(full)
    comparison.after.ageing.each do |code, ageing|
      comparison.before.ageing[code]?.should eq(ageing)
    end
  end

  it "signale en écart un FEC réexporté ou une balance qui ne tombent pas juste" do
    before = Reconciliation::Figures.new
    after = Reconciliation::Figures.new
    before.accounts["706"] = Reconciliation::Totals.new(BigDecimal.new(0), BigDecimal.new(100), 1)
    after.accounts["706"] = before.accounts["706"]
    after.fec_accounts["706"] = Reconciliation::Totals.new(BigDecimal.new(0), BigDecimal.new("99.99"), 1)
    after.trial_delta = BigDecimal.new("0.01")
    comparison = Reconciliation::Comparison.new(before, after, Time.utc(2024, 12, 31))
    comparison.ok?.should be_false
    failures = comparison.failures.map { |(section, row)| {section.key, row.key} }
    failures.should contain({"fec_accounts", "706"})
    failures.should contain({"editions", "trial_balance_delta"})
    failures.should_not contain({"accounts", "706"})
  end

  it "présente les éditions dans le rapport" do
    PartiduoMigrate::SpecSupport.provision!
    migration = PartiduoMigrate::Migration.new(demo_dataset)
    migration.run.should be_true
    dir = PartiduoMigrate::SpecSupport.report_dir
    PartiduoMigrate::Report.new(dir, migration).write
    report = File.read(File.join(dir, "rapport.adoc"))
    report.should contain("== Éditions de l'instance")
    report.should contain("== FEC réexporté par l'instance et relu")
    report.should contain("|Écritures du FEC réexporté |133,00 |133,00 |ok")
    report.should contain("=== Bilan et compte de résultat")
    rows = CSV.parse(File.read(File.join(dir, "editions.csv")))
    rows.size.should eq(4)
    rows.map(&.last).skip(1).uniq.should eq(["ok"])
    CSV.parse(File.read(File.join(dir, "fec-relu.csv"))).find! { |row| row[0] == "510001" }.last.should eq("ok")
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end
end
