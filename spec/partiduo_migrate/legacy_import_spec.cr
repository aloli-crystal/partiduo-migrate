# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Reprise d'une base d'origine" do
  it "exporte de la base de démonstration exactement le FEC livré" do
    url = PartiduoMigrate::SpecSupport.legacy_url
    dataset = PartiduoMigrate::Legacy::Database.new(url).read(with_attachments: false)
    io = IO::Memory.new
    PartiduoMigrate::Fec::Writer.new.write(dataset, io)
    io.to_slice.should eq(File.read(PartiduoMigrate::SpecSupport::DEMO_FEC).to_slice)
    PartiduoMigrate::Legacy::Database.new(url).siren.should eq("732829320")
  end

  it "reprend la base : fiches complètes, TVA, exercice, pièces jointes, réconciliation au centime" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = PartiduoMigrate::Legacy::Database.new(PartiduoMigrate::SpecSupport.legacy_url).read
    migration = PartiduoMigrate::Migration.new(dataset)
    ok = migration.run
    ok.should be_true
    migration.problems.select(&.blocking).should be_empty
    migration.comparison.present!.ok?.should be_true
    Partiduo::Api::Accounting.count_entries(actor).should eq(133)
    migration.counts["attachments"].should eq(14)
    migration.counts["matchings"].should eq(43)

    # Fiche complète : adresse, SIREN, numéro de TVA, contact.
    card = Partiduo::Api::Cards.card_by_code(actor, "AUBEPINE").present!
    card.vat_number.should eq("FR40303265045")
    card.siren.should eq("303265045")
    card.contact_name.should eq("Claire Martin")
    card.email.should eq("contact@aubepine.example")
    card.address.present!.city.should eq("Nantes")
    card.address.present!.country_code.should eq("FR")
    Partiduo::Api::Accounting.card_account(actor, card.id).present!.account.number.should eq("4100002")
    item = Partiduo::Api::Cards.card_by_code(actor, "CONSEIL").present!
    item.kind.should eq("item")
    item.sale_price.should eq(BigDecimal.new("650"))
    item.vat_rate_code.should eq("NOR")

    # Paramètres de TVA : taux de la base, comptes de TVA.
    rate = Partiduo::Api::Vat.rate_by_code(actor, "INTS").present!
    rate.reverse_charge.should be_true
    accounts = Partiduo::Api::Accounting.vat_rate_account(actor, Partiduo::Api::Vat.rate_by_code(actor, "NOR").present!.id)
    accounts.present!.deductible_account.present!.number.should eq("445661")
    accounts.present!.collected_account.present!.number.should eq("44571")
    Partiduo::Api::Vat.rate_by_code(actor, "DNPR").should_not be_nil

    # Pièce jointe rattachée à l'écriture de loyer de janvier.
    entry = Partiduo::Api::Accounting.entries(actor, Partiduo::Api::Accounting::EntryQuery.new(receipt: "A-0001")).first
    attachment = Partiduo::Api::Core.attachment(actor, entry.attachment_id.present!)
    attachment.filename.should eq("loyer-2024-01.pdf")
    attachment.content_type.should eq("application/pdf")
    entry.due_date.should eq(Time.utc(2024, 1, 10))
    entry.source.should start_with("legacy:")

    # Échéances reprises : la balance âgée en tient compte.
    ageing = migration.comparison.present!.after.ageing["DUNE"]
    ageing.not_due.should eq(BigDecimal.new("3600.00"))

    # Analytique reprise par le contrat de l'Analytique, réconciliée par
    # poste (D-R5-011) ; plus rien en annexe.
    dataset.unported.count(&.kind.==("analytic")).should eq(0)
    {migration.counts["analytic_plans"], migration.counts["analytic_posts"], migration.counts["analytic_lines"]}
      .should eq({1, 3, 18})
    analytic = migration.comparison.present!.section("analytic").present!
    analytic.rows.map(&.key).should eq(["ACTIVITÉS/CONSEIL", "ACTIVITÉS/EDITION", "ACTIVITÉS/FORMATION"])
    analytic.rows.all?(&.ok?).should be_true
    plan = Partiduo::Api::Analytic.plans(actor).first
    balance = Partiduo::Api::Analytic.balance(actor, Partiduo::Api::Analytic::ReportQuery.new(plan_id: plan.id))
    balance.total.credit.should eq(dataset.analytic.rows.sum(BigDecimal.new(0), &.amount))

    # Numéros de relevé du journal financier : relevés rapprochés (D-R5-012).
    ledger = Partiduo::Api::Accounting.ledgers(actor).find!(&.code.==("F01"))
    statements = Partiduo::Api::Accounting.bank_statements(actor, ledger.id)
    statements.size.should eq(migration.counts["statements"])
    statements.size.should be > 0
    Partiduo::Api::Accounting.reconciliation(actor, ledger.id).unreconciled.should be_empty

    # Les utilisateurs de l'application d'origine ne sont jamais repris.
    Partiduo::Api::Auth.users(actor).should be_empty
  end

  it "complète un FEC par la base d'origine dont il est issu" do
    PartiduoMigrate::SpecSupport.provision!
    legacy = PartiduoMigrate::Legacy::Database.new(PartiduoMigrate::SpecSupport.legacy_url).read
    dataset = PartiduoMigrate::Complement.merge(demo_dataset, legacy)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    migration.counts["attachments"].should eq(14)
    entry = Partiduo::Api::Accounting.entries(actor, Partiduo::Api::Accounting::EntryQuery.new(receipt: "V24-0004")).first
    entry.source.should start_with("fec:")
    entry.attachment_id.should_not be_nil
    Partiduo::Api::Cards.card_by_code(actor, "BRISEMAR").present!.siren.should eq("404833048")
  end
end

describe "Reprise d'une fiche de la base d'origine aux valeurs refusées" do
  it "conserve en attribut propre un numéro de TVA que le socle refuse" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = PartiduoMigrate::Legacy::Database.new(PartiduoMigrate::SpecSupport.legacy_url).read
    index = dataset.cards.index!(&.code.==("CEDRE"))
    card = dataset.cards[index]
    attributes = card.attributes.dup
    attributes[13_i64] = "FR00123"
    dataset.cards[index] = card.copy_with(attributes: attributes)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    view = Partiduo::Api::Cards.card_by_code(actor, "CEDRE").present!
    view.vat_number.should eq("")
    view.extra["legacy_13"].as_s.should eq("FR00123")
    migration.notes.any?(&.includes?("vat_number « FR00123 » refusé")).should be_true
  end
end
