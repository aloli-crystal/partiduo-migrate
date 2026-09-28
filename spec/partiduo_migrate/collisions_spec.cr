# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias B = PartiduoMigrate::SpecSupport::FecBuilder

private def legacy_dataset : PartiduoMigrate::Source::Dataset
  PartiduoMigrate::Legacy::Database.new(PartiduoMigrate::SpecSupport.legacy_url).read(with_attachments: false)
end

private def vat_rate(code : String, rate : String, id : Int64) : PartiduoMigrate::Source::VatRate
  PartiduoMigrate::Source::VatRate.new(code: code, label: code, rate: BigDecimal.new(rate), comment: "Taux #{code}",
    reverse_charge: false, sale_on_payment: false, purchase_on_payment: false, deductible_account: nil,
    collected_account: nil, id: id)
end

describe "Codes en collision pendant la reprise" do
  it "crée deux taux distincts pour deux codes de la base d'origine qui donnent le même code" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    dataset.vat_rates << vat_rate("FRINTRA_ACH", "20", 901_i64)
    dataset.vat_rates << vat_rate("FRINTRA_VEN", "5.5", 902_i64)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    vat = Partiduo::Api::Vat
    vat.rate_by_code(actor, "FRINT").present!.rate.should eq(BigDecimal.new(20))
    vat.rate_by_code(actor, "FRIN2").present!.rate.should eq(BigDecimal.new("5.5"))
    migration.mapping.vat_rates["FRINTRA_ACH"].should eq("FRINT")
    migration.mapping.vat_rates["FRINTRA_VEN"].should eq("FRIN2")
    migration.mapping.renamed.should contain({"taux de TVA", "FRINTRA_VEN", "FRIN2"})
    migration.notes.any?(&.includes?("repris sous le code FRIN2 : le code FRINT est pris")).should be_true
  end

  it "ne modifie un taux du jeu initial que si son taux est identique" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    # INT (10 %) existe dans le jeu initial français.
    dataset.vat_rates << vat_rate("INT", "13", 903_i64)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    Partiduo::Api::Vat.rate_by_code(actor, "INT").present!.rate.should eq(BigDecimal.new(10))
    Partiduo::Api::Vat.rate_by_code(actor, "INT2").present!.rate.should eq(BigDecimal.new(13))
    # NOR (20 %) : même taux, mis à jour et gardé sous son code.
    migration.mapping.vat_rates["NOR"].should eq("NOR")
    migration.counts["vat_rates_updated"].should be > 0
  end

  it "reprend dans deux journaux distincts deux journaux source dont les codes se confondent" do
    PartiduoMigrate::SpecSupport.provision!
    rows = [
      B.row("BQ-1", "1", "20240105", "471000", debit: "10,00", receipt: "R1"),
      B.row("BQ-1", "1", "20240105", "580000", credit: "10,00", receipt: "R1"),
      B.row("BQ1", "1", "20240106", "471000", debit: "20,00", receipt: "R1"),
      B.row("BQ1", "1", "20240106", "580000", credit: "20,00", receipt: "R1"),
    ]
    migration = PartiduoMigrate::Migration.new(B.dataset(rows))
    migration.run.should be_true
    migration.problems.should be_empty
    migration.mapping.journals["BQ-1"].should eq("BQ1")
    migration.mapping.journals["BQ1"].should eq("BQ12")
    migration.mapping.receipts.should be_empty
    migration.notes.any?(&.includes?("journal distinct créé sous le code BQ12")).should be_true
    by_ledger = Partiduo::Api::Accounting.entries(actor).group_by(&.ledger_code)
    by_ledger.keys.sort!.should eq(%w[BQ1 BQ12])
    by_ledger.values.flat_map(&.map(&.receipt)).should eq(%w[R1 R1])
    migration.comparison.present!.after.journals.keys.sort!.should eq(%w[BQ1 BQ12])
  end
end

describe "Type des comptes créés depuis un FEC" do
  it "suit le plan comptable général : TVA déductible et charges constatées d'avance à l'actif, concours bancaires au passif" do
    PartiduoMigrate::SpecSupport.provision!
    rows = [
      B.row("OD", "1", "20240105", "445660", debit: "10,00"),
      B.row("OD", "1", "20240105", "486000", debit: "10,00"),
      B.row("OD", "1", "20240105", "409100", debit: "10,00"),
      B.row("OD", "1", "20240105", "425000", debit: "10,00"),
      B.row("OD", "1", "20240105", "476000", debit: "10,00"),
      B.row("OD", "1", "20240105", "519000", credit: "30,00"),
      B.row("OD", "1", "20240105", "445710", credit: "20,00"),
    ]
    PartiduoMigrate::Migration.new(B.dataset(rows)).run.should be_true
    kind = ->(number : String) { Partiduo::Api::Accounting.account(actor, number).kind.code }
    {"445660" => "asset", "486000" => "asset", "409100" => "asset", "425000" => "asset", "476000" => "asset",
     "519000" => "liability", "445710" => "liability"}.each do |number, expected|
      {number, kind.call(number)}.should eq({number, expected})
    end
  end
end

describe "Données relues mais non reprises" do
  it "relève les montants en devise, les dates de lettrage et de pièce au rapport" do
    PartiduoMigrate::SpecSupport.provision!
    row = B.row("VT", "1", "20240105", "411000", debit: "120,00", aux: "C1", letter: "A").split('\t')
    row[16] = "130,00"
    row[17] = "USD"
    row[9] = "20240103"
    rows = [row.join('\t'),
            B.row("VT", "1", "20240105", "706000", credit: "120,00"),
            B.row("BQ", "1", "20240120", "471000", debit: "120,00"),
            B.row("BQ", "1", "20240120", "411000", credit: "120,00", aux: "C1", letter: "A")]
    dataset = B.dataset(rows)
    currency = dataset.all_unported.find! { |item| item.kind == "currency" }
    currency.reference.should eq("VT n° 1")
    currency.detail.should start_with("130,00 USD")
    dataset.letter_dates.should eq(2)
    dataset.receipt_dates.should eq(1)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    dir = PartiduoMigrate::SpecSupport.report_dir
    PartiduoMigrate::Report.new(dir, migration).write
    report = File.read(File.join(dir, "rapport.adoc"))
    report.should contain("|montant en devise |1")
    report.should contain("|Dates de lettrage relues, non reprises")
    File.read(File.join(dir, "non-repris.csv")).should contain("VT n° 1")
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end
end
