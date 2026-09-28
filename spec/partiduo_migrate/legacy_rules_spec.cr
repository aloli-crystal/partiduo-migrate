# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def legacy_dataset : PartiduoMigrate::Source::Dataset
  PartiduoMigrate::Legacy::Database.new(PartiduoMigrate::SpecSupport.legacy_url).read(with_attachments: false)
end

describe "Règles de reprise d'une base d'origine" do
  it "reprend la nature des journaux (jrn_def_type) et la fiche Banque du journal financier" do
    PartiduoMigrate::SpecSupport.provision!
    PartiduoMigrate::Migration.new(legacy_dataset).run.should be_true
    ledger = ->(code : String) { Partiduo::Api::Accounting.ledger_by_code(actor, code) }
    ledger.call("F01").kind.code.should eq("financial")
    ledger.call("V01").kind.code.should eq("sale")
    ledger.call("A01").kind.code.should eq("purchase")
    ledger.call("O01").kind.code.should eq("misc")
    ledger.call("F01").bank_card_code.should eq("BANQUE")
  end

  it "reprend le type des comptes et leur usage direct (pcm_type, pcm_direct_use)" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    dataset.accounts["53"].direct_use.should be_false
    PartiduoMigrate::Migration.new(dataset).run.should be_true
    # Tout compte mouvementé dans la source est utilisable en saisie.
    used = dataset.lines.map(&.account).uniq!
    used.each { |number| Partiduo::Api::Accounting.account(actor, number).direct_use.should be_true }
  end

  it "ferme après les écritures les périodes closes dans la base d'origine (p_closed)" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    year = dataset.fiscal_years.first
    year.months.should eq(12)
    periods = year.periods.map { |period| period.starts_on.month <= 2 ? period.copy_with(closed: true) : period }
    dataset.fiscal_years[0] = year.copy_with(periods: periods)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    migration.counts["periods_closed"].should eq(2)
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 1, 15)).present!.closed?.should be_true
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 2, 15)).present!.closed?.should be_true
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 3, 15)).present!.closed?.should be_false
    # Les écritures de janvier sont bien passées avant la fermeture.
    Partiduo::Api::Accounting.count_entries(actor).should eq(133)
  end

  it "désactive après les écritures les fiches désactivées dans la base d'origine (f_enable)" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    index = dataset.cards.index!(&.code.==("DUNE"))
    dataset.cards[index] = dataset.cards[index].copy_with(enabled: false)
    PartiduoMigrate::Migration.new(dataset).run.should be_true
    Partiduo::Api::Cards.card_by_code(actor, "DUNE").present!.enabled.should be_false
    # Ses écritures sont reprises malgré tout.
    statement = Partiduo::Api::Accounting.account_statement(actor,
      Partiduo::Api::Accounting::StatementQuery.new(card: "DUNE", as_of: Time.utc(2024, 12, 31)))
    statement.remaining.should eq(BigDecimal.new("3600.00"))
  end

  it "refuse une base qui n'est pas en DBVERSION 208" do
    name = "partiduo_test_m_specs_v207"
    Process.run("dropdb", ["--if-exists", name])
    Process.run("createdb", [name]).success?.should be_true
    url = PartiduoMigrate::SpecSupport.database_url(name)
    DB.open(url) do |db|
      db.exec("CREATE TABLE version (val integer)")
      db.exec("INSERT INTO version VALUES (206), (207)")
    end
    error = expect_raises(PartiduoMigrate::Legacy::Error) { PartiduoMigrate::Legacy::Database.new(url).read }
    error.message.to_s.should contain("DBVERSION 207, 208 attendue")
  ensure
    name.try { |base| Process.run("dropdb", ["--if-exists", base]) }
  end

  it "rapproche les pièces jointes d'un FEC complété par journal, date, pièce et montant" do
    fec = demo_dataset
    legacy = PartiduoMigrate::Legacy::Database.new(PartiduoMigrate::SpecSupport.legacy_url).read
    # Écriture retirée du FEC : sa pièce jointe est relevée en annexe.
    target = fec.entries.find! { |entry| entry.receipt == "A-0001" }
    fec.entries.delete(target)
    merged = PartiduoMigrate::Complement.merge(fec, legacy)
    merged.entries.count(&.attachment).should eq(13)
    orphan = merged.unported.find! { |item| item.kind == "orphan_attachment" }
    orphan.detail.should contain("écriture absente du FEC")
    merged.full_chart?.should be_true
    merged.accounts.has_key?("53").should be_true
  end
end
