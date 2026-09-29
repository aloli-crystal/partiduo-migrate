# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def reencode(tab_iso : String, separator : Char, encoding : String) : Bytes
  text = String.new(File.read(tab_iso).to_slice, "ISO-8859-15")
  text = text.gsub('\t', separator) if separator != '\t'
  PartiduoMigrate::Fec::Encoding.encode(text, encoding)
end

describe "Reprise d'un FEC" do
  it "importe le FEC de démonstration avec un rapport juste au centime" do
    PartiduoMigrate::SpecSupport.provision!
    migration = PartiduoMigrate::Migration.new(demo_dataset)
    migration.run.should be_true
    migration.problems.should be_empty
    migration.committed?.should be_true
    comparison = migration.comparison.present!
    comparison.ok?.should be_true
    comparison.failures.should be_empty

    # Chiffres relus par le contrat.
    Partiduo::Api::Accounting.count_entries(actor).should eq(133)
    totals = comparison.after.total
    totals.debit.should eq(BigDecimal.new("246290.77"))
    totals.credit.should eq(totals.debit)
    comparison.after.accounts["510001"].balance.should eq(BigDecimal.new("-33987.00"))
    comparison.after.journals.keys.sort!.should eq(%w[A01 F01 O01 V01])
    comparison.after.periods.size.should eq(12)
    migration.counts["matchings"].should eq(43)

    # Balance âgée au 31 décembre 2024 : facture de décembre non échue… sans
    # échéance dans le FEC, référence = date ; créance de 2023 à plus de
    # 60 jours ; reliquat du règlement partiel d'octobre à 31–60 jours.
    brise = comparison.after.ageing["BRISEMAR"]
    brise.over_60.should eq(BigDecimal.new("1800.00") + BigDecimal.new("1672.50"))
    cedre = comparison.after.ageing["CEDRE"]
    cedre.days_31_60.should eq(BigDecimal.new("3540.00"))
    comparison.after.ageing["TELCOM"].remaining.should eq(BigDecimal.new("-107.88"))

    # Tiers repris en fiches, rattachés à leur compte.
    card = Partiduo::Api::Cards.card_by_code(actor, "AUBEPINE").present!
    card.kind.should eq("customer")
    card.name.should eq("Librairie L'Aubépine")
    Partiduo::Api::Accounting.card_account(actor, card.id).present!.account.number.should eq("4100002")
    Partiduo::Api::Cards.card_by_code(actor, "LOCAPRO").present!.kind.should eq("supplier")
    # Aucun compte calculé laissé par la création des fiches.
    Partiduo::Api::Accounting.chart(actor).map(&.account.number).should_not contain("4100006")

    # Écriture reprise : pièce, source, lettrage.
    entry = Partiduo::Api::Accounting.entries(actor,
      Partiduo::Api::Accounting::EntryQuery.new(receipt: "V24-0001")).first
    entry.source.should eq("fec:V01:4")
    entry.lines.find! { |line| line.account_number == "4100002" }.matching_code.should_not be_nil
    statement = Partiduo::Api::Accounting.account_statement(actor,
      Partiduo::Api::Accounting::StatementQuery.new(card: "DUNE", as_of: Time.utc(2024, 12, 31)))
    statement.remaining.should eq(BigDecimal.new("3600.00"))
  end

  it "écrit le rapport en AsciiDoc et en CSV" do
    PartiduoMigrate::SpecSupport.provision!
    migration = PartiduoMigrate::Migration.new(demo_dataset)
    migration.run.should be_true
    dir = PartiduoMigrate::SpecSupport.report_dir
    files = PartiduoMigrate::Report.new(dir, migration).write
    files.map { |path| File.basename(path) }.sort!.should eq(%w[analytique.csv anomalies.csv balance-agee.csv balance-generale.csv
      correspondances.csv ecarts.csv editions.csv fec-relu.csv journaux.csv lecture-source.csv non-repris.csv
      periodes.csv rapport.adoc])
    report = File.read(File.join(dir, "rapport.adoc"))
    report.should contain("*RÉUSSIE*")
    report.should contain("== Balance générale")
    report.should contain("== Balance âgée des tiers")
    report.should contain("|V01 |19 |36444,25 |36444,25 |19 |36444,25 |36444,25 |ok")
    rows = CSV.parse(File.read(File.join(dir, "balance-generale.csv")))
    rows.first.first(3).should eq(["compte", "libellé", "lignes avant"])
    rows.find! { |row| row[0] == "510001" }.last.should eq("ok")
    CSV.parse(File.read(File.join(dir, "ecarts.csv"))).size.should eq(1)
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end

  it "lit le même FEC en UTF-8 à barre verticale" do
    PartiduoMigrate::SpecSupport.provision!
    reader = PartiduoMigrate::Fec::Reader.new
    bytes = reencode(PartiduoMigrate::SpecSupport::DEMO_FEC, '|', "UTF-8")
    dataset = reader.read(bytes, "732829320FEC20241231.txt")
    reader.problems.should be_empty
    reader.encoding.should eq("UTF-8")
    reader.separator.should eq('|')
    PartiduoMigrate::Migration.new(dataset).run.should be_true
    Partiduo::Api::Cards.card_by_code(actor, "DUNE").present!.name.should eq("Dune Évènements")
  end

  it "fait un essai à blanc sans rien conserver" do
    PartiduoMigrate::SpecSupport.provision!
    migration = PartiduoMigrate::Migration.new(demo_dataset, dry_run: true)
    migration.run.should be_true
    migration.committed?.should be_false
    migration.comparison.present!.ok?.should be_true
    Partiduo::Api::Accounting.count_entries(actor).should eq(0)
    Partiduo::Api::Cards.card_by_code(actor, "AUBEPINE").should be_nil
  end

  it "refuse une instance qui a déjà des écritures" do
    PartiduoMigrate::SpecSupport.provision!
    PartiduoMigrate::Migration.new(demo_dataset).run.should be_true
    again = PartiduoMigrate::Migration.new(demo_dataset)
    again.run.should be_false
    again.problems.map(&.message).first.should contain("133 écriture(s)")
    again.comparison.should be_nil
    Partiduo::Api::Accounting.count_entries(actor).should eq(133)
  end

  it "refuse une instance non provisionnée" do
    migration = PartiduoMigrate::Migration.new(demo_dataset)
    migration.run.should be_false
    migration.problems.first.message.should contain("non provisionnée")
  end

  it "annule toute la reprise quand un lettrage ne peut être repris" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = demo_dataset
    # Lettre « ZZ » portée par une seule ligne : lettrage impossible.
    entry = dataset.entries.find! { |candidate| candidate.receipt == "V24-0019" }
    index = entry.lines.index!(&.account.starts_with?("41"))
    entry.lines[index] = entry.lines[index].copy_with(letter: "ZZ")
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_false
    migration.committed?.should be_false
    problem = migration.problems.find! { |candidate| candidate.step == "matching" }
    problem.blocking.should be_true
    problem.reference.should contain("ZZ")
    migration.failure_reason.should contain("1 anomalie(s) de reprise")
    Partiduo::Api::Accounting.count_entries(actor).should eq(0)
  end

  it "renomme les pièces en double dans un journal et le consigne" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = demo_dataset
    first, second = dataset.entries.select { |entry| entry.journal_code == "O01" }.first(2)
    duplicate = PartiduoMigrate::Source::Entry.new(second.journal_code, second.number, second.date, first.receipt,
      second.receipt_date, second.label, second.due_date, second.lines)
    dataset.entries[dataset.entries.index!(second)] = duplicate
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    migration.mapping.receipts.should eq([{"O01", "O-AN2024", "O-AN2024-2"}])
    Partiduo::Api::Accounting.entries(actor, Partiduo::Api::Accounting::EntryQuery.new(receipt: "O-AN2024-2")).size
      .should eq(1)
  end
end
