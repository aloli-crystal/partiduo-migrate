# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def legacy_dataset : PartiduoMigrate::Source::Dataset
  PartiduoMigrate::Legacy::Database.new(PartiduoMigrate::SpecSupport.legacy_url).read(with_attachments: false)
end

# Périodes mensuelles de `months` mois à partir de `start`.
private def monthly(start : Time, months : Int32) : Array(PartiduoMigrate::Source::Period)
  (0...months).map do |index|
    first = start.shift(months: index)
    PartiduoMigrate::Source::Period.new(first, first.shift(months: 1, days: -1))
  end
end

private def year(label : String, start : Time, months : Int32) : PartiduoMigrate::Source::FiscalYear
  PartiduoMigrate::Source::FiscalYear.new(label, start, months, monthly(start, months))
end

private def fiscal_year_id(day : Time) : Int64
  Partiduo::Api::Core.period_for(actor, day).present!.fiscal_year_id
end

describe "Exercices d'une base d'origine" do
  it "reprend un premier exercice de 18 mois et aligne sur lui l'exercice 1/7-30/6 qui manque" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    dataset.fiscal_years.clear
    # 1er janvier 2023 → 30 juin 2024 ; les écritures de juillet à décembre
    # 2024 ne sont couvertes par aucun exercice de la source.
    dataset.fiscal_years << year("2023-2024", Time.utc(2023, 1, 1), 18)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    migration.problems.select(&.blocking).should be_empty
    migration.counts["fiscal_years_created"].should eq(2)
    fiscal_year_id(Time.utc(2023, 1, 1)).should eq(fiscal_year_id(Time.utc(2024, 6, 30)))
    fiscal_year_id(Time.utc(2024, 7, 1)).should eq(fiscal_year_id(Time.utc(2025, 6, 30)))
    fiscal_year_id(Time.utc(2024, 7, 1)).should_not eq(fiscal_year_id(Time.utc(2024, 6, 30)))
    Partiduo::Api::Core.period_for(actor, Time.utc(2025, 7, 1)).should be_nil
    Partiduo::Api::Accounting.count_entries(actor).should eq(133)
  end

  it "crée avant un exercice 1/7-30/6 de la source l'exercice qui couvre les écritures antérieures" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    dataset.fiscal_years.clear
    dataset.fiscal_years << year("2024-2025", Time.utc(2024, 7, 1), 12)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    migration.counts["fiscal_years_created"].should eq(2)
    fiscal_year_id(Time.utc(2023, 7, 1)).should eq(fiscal_year_id(Time.utc(2024, 6, 30)))
    fiscal_year_id(Time.utc(2024, 7, 1)).should eq(fiscal_year_id(Time.utc(2025, 6, 30)))
    Partiduo::Api::Core.period_for(actor, Time.utc(2023, 6, 30)).should be_nil
  end

  it "reprend la période de clôture d'un jour (13 périodes) et ne ferme pas décembre quand elle seule est close" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    periods = monthly(Time.utc(2024, 1, 1), 11)
    periods << PartiduoMigrate::Source::Period.new(Time.utc(2024, 12, 1), Time.utc(2024, 12, 30))
    periods << PartiduoMigrate::Source::Period.new(Time.utc(2024, 12, 31), Time.utc(2024, 12, 31), closed: true)
    dataset.fiscal_years.clear
    dataset.fiscal_years << PartiduoMigrate::Source::FiscalYear.new("2024", Time.utc(2024, 1, 1), 12, periods)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    closing = Partiduo::Api::Core.period_for(actor, Time.utc(2024, 12, 31)).present!
    closing.single_day?.should be_true
    closing.closed?.should be_true
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 12, 15)).present!.closed?.should be_false
    migration.counts["periods_closed"].should eq(1)
  end

  it "laisse ouverte une période dont une partie seulement des périodes de la source est close" do
    PartiduoMigrate::SpecSupport.provision!
    dataset = legacy_dataset
    periods = monthly(Time.utc(2024, 1, 1), 11)
    periods << PartiduoMigrate::Source::Period.new(Time.utc(2024, 12, 1), Time.utc(2024, 12, 15), closed: true)
    periods << PartiduoMigrate::Source::Period.new(Time.utc(2024, 12, 16), Time.utc(2024, 12, 31))
    dataset.fiscal_years.clear
    dataset.fiscal_years << PartiduoMigrate::Source::FiscalYear.new("2024", Time.utc(2024, 1, 1), 12, periods)
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    Partiduo::Api::Core.period_for(actor, Time.utc(2024, 12, 10)).present!.closed?.should be_false
    migration.counts["periods_closed"].should eq(0)
    migration.notes.any?(&.includes?("Période 2024-12-01 – 2024-12-31 laissée ouverte")).should be_true
  end
end
