# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Reprises au-delà de la comptabilité générale (BLOCAGES B-MIG-001,
# B-CRIT-003, B-SEC-001 ; DECISIONS D-R5-011 à D-R5-014) : analytique non
# représentable, stock, prévisions, suivi, avertissements de sécurité.

# Données ajoutées à une copie de la base d'origine de démonstration.
private EXTRAS_SQL = <<-SQL
  -- Stock : un second dépôt, un code stock, une opération manuelle, un mouvement libre.
  insert into stock_repository (r_id, r_name, r_adress, r_city, r_country, r_phone)
    values (2, 'Entrepôt Nantes', '1 quai de la Fosse', 'Nantes', 'fr', '0240000000');
  update fiche_detail set ad_value = 'LIV' where f_id = 92 and ad_id = 19;
  insert into stock_change (c_id, c_comment, c_date, r_id, tech_user) values (50, 'Inventaire initial', '2024-03-01', 2, 'marie');
  insert into stock_goods (f_id, sg_code, sg_quantity, sg_type, sg_date, r_id, c_id)
    values (92, 'LIV', 10, 'd', '2024-03-01', 2, 50);
  insert into stock_goods (f_id, sg_code, sg_quantity, sg_type, sg_date, r_id, sg_comment)
    values (92, 'LIV', 3, 'c', '2024-04-02', 2, 'Vente au comptoir');
  insert into profile_sec_repository (p_id, r_id, ur_right) values (2, 2, 'R');
  -- Prévisions : un élément pour toutes les périodes, un propre à mars.
  insert into forecast (f_id, f_name, f_start_date, f_end_date) values (1, 'Budget 2024', 118, 129);
  insert into forecast_category (fc_id, fc_desc, f_id, fc_order) values (1, 'Ventes', 1, 1);
  insert into forecast_item (fi_text, fi_account, fi_order, fc_id, fi_amount, fi_pid, fi_amount_initial)
    values ('Conseil', '[706%]', 1, 1, 1000, 0, 0), ('Livres', '[707%]', 2, 1, 500, 120, 0);
  -- Suivi : étiquette, action vers un client (fiche concernée, commentaire),
  -- action interne réservée à un groupe, actions liées.
  insert into tags (t_id, t_tag, t_description, t_actif, t_color) values (1, 'Urgent', 'À traiter vite', 'Y', 3);
  insert into action_gestion (ag_id, ag_type, f_id_dest, ag_title, ag_timestamp, ag_ref, ag_hour, ag_priority, ag_dest, ag_state, ag_remind_date)
    values (1, 8, 83, 'Relance du devis', '2024-05-02 10:00', 'EML1', '14h30', 1, -1, 2, '2024-05-10'),
           (2, 1, null, 'Note interne', '2024-05-03 09:00', 'DIN1', '', 2, 1, 1, null);
  insert into action_tags (t_id, ag_id) values (1, 1);
  insert into action_person (ag_id, f_id) values (1, 84);
  insert into action_gestion_comment (ag_id, agc_date, agc_comment, tech_user) values (1, '2024-05-02 11:00', 'Client appelé', 'marie');
  insert into action_gestion_related (aga_least, aga_greatest) values (1, 2);
  -- Analytique non représentable : imputation de sens contraire à sa ligne.
  insert into operation_analytique (po_id, oa_amount, oa_debit, j_id, oa_date, oa_row, oa_description)
    values (1, 100, true, 29, '2024-02-05', 1, 'contraire');
  SQL

private def with_extras(&)
  name = "partiduo_test_r5_extras_#{Process.pid}"
  status = Process.run(File.join(PartiduoMigrate::SpecSupport::ROOT, "scripts", "legacy-demo"), [name],
    output: Process::Redirect::Close, error: Process::Redirect::Inherit)
  raise "scripts/legacy-demo #{name} en échec" unless status.success?
  url = PartiduoMigrate::SpecSupport.database_url(name)
  DB.open(url) do |db|
    EXTRAS_SQL.split(";\n").each do |statement|
      sql = statement.lines.reject(&.strip.starts_with?("--")).join("\n").strip.rchop(';')
      db.exec(sql) unless sql.empty?
    end
  end
  yield url
ensure
  name.try { |base| Process.run("dropdb", ["--if-exists", base]) }
end

describe "Reprise de l'analytique, du stock, des prévisions et du suivi" do
  it "reprend le stock, les prévisions et le suivi, avertit des restrictions non reproduites et réconcilie" do
    with_extras do |url|
      PartiduoMigrate::SpecSupport.provision!
      %w[STOCK FOLLOWUP].each { |code| Partiduo::Api::Modules.activate(actor, code).value! }
      dataset = PartiduoMigrate::Legacy::Database.new(url).read(with_attachments: false)
      migration = PartiduoMigrate::Migration.new(dataset)
      migration.run.should be_true
      migration.problems.select(&.blocking).should be_empty

      # Analytique : la ligne à l'imputation contraire va en annexe (ses deux
      # imputations), les autres sont reprises et réconciliées.
      migration.counts["analytic_lines"].should eq(17)
      unported = dataset.unported.select(&.kind.==("analytic"))
      unported.size.should eq(2)
      unported.first.detail.should contain("sens contraire")
      migration.comparison.present!.section("analytic").present!.rows.all?(&.ok?).should be_true

      # Stock : dépôts, article suivi sous son code, deux opérations.
      repositories = Partiduo::Api::Stock.repositories(actor)
      repositories.map(&.name).sort!.should eq(["Dépôt par défaut", "Entrepôt Nantes"])
      nantes = repositories.find! { |item| item.name == "Entrepôt Nantes" }
      nantes.country_code.should eq("FR")
      livres = Partiduo::Api::Cards.card_by_code(actor, "LIVRES").present!
      Partiduo::Api::Stock.item(actor, livres.id).present!.stock_code.should eq("LIV")
      movements = Partiduo::Api::Stock.movements(actor, Partiduo::Api::Stock::MovementQuery.new(repository_id: nantes.id))
      movements.map { |movement| {movement.direction, movement.quantity} }.sort!
        .should eq([{"in", BigDecimal.new(10)}, {"out", BigDecimal.new(3)}])
      migration.counts["stock_changes"].should eq(2)

      # Prévisions : un élément sur toutes les périodes, un propre à mars.
      forecast = Partiduo::Api::Accounting.forecasts(actor).find! { |item| item.name == "Budget 2024" }
      view = Partiduo::Api::Accounting.forecast(actor, forecast.id)
      items = view.categories.first.items
      items.map(&.label).should eq(["Conseil", "Livres"])
      items[0].amount.should eq(BigDecimal.new(1000))
      items[1].period_amounts.map(&.amount).should eq([BigDecimal.new(500)])

      # Suivi : actions, fiche, fiche concernée, étiquette, commentaire daté,
      # heure normalisée, état, action liée.
      actions = Partiduo::Api::Followup.actions(actor, Partiduo::Api::Followup::ActionQuery.new(open_only: false))
      actions.size.should eq(2)
      relance = Partiduo::Api::Followup.action(actor, actions.find! { |item| item.title == "Relance du devis" }.id)
      {relance.state, relance.priority, relance.hour, relance.card.present!.code}.should eq({"follow", 1, "14:30", "AUBEPINE"})
      relance.concerned.map(&.code).should eq(["BRISEMAR"])
      relance.tags.map(&.label).should eq(["Urgent"])
      relance.comments.first.text.should eq("[2024-05-02 11:00, marie] Client appelé")
      relance.related.size.should eq(1)

      # Restrictions de la source non reproduites : avertissements (B-SEC-001).
      warnings = migration.problems.select { |problem| problem.step == "security" }
      warnings.map(&.reference).sort!.should eq(["action_gestion.ag_dest", "profile_sec_repository"])
      warnings.none?(&.blocking).should be_true
      warnings.map(&.message).join(" ").should contain("B-SEC-001")

      # Rapport : tableau analytique par poste, annexe, compteurs.
      dir = PartiduoMigrate::SpecSupport.report_dir
      PartiduoMigrate::Report.new(dir, migration).write
      report = File.read(File.join(dir, "rapport.adoc"))
      report.should contain("== Analytique par poste")
      report.should contain("Relevés bancaires rapprochés")
      File.read(File.join(dir, "analytique.csv")).should contain("ACTIVITÉS/CONSEIL")
      File.read(File.join(dir, "non-repris.csv")).should contain("sens contraire")
    ensure
      %w[FOLLOWUP STOCK].each { |code| Partiduo::Api::Modules.deactivate(actor, code) }
    end
  end

  it "consigne en annexe les données d'un module inactif, sans échec" do
    with_extras do |url|
      PartiduoMigrate::SpecSupport.provision!
      %w[FOLLOWUP STOCK ANALYTIC].each { |code| Partiduo::Api::Modules.deactivate(actor, code) }
      dataset = PartiduoMigrate::Legacy::Database.new(url).read(with_attachments: false)
      migration = PartiduoMigrate::Migration.new(dataset)
      migration.run.should be_true
      dataset.unported.count(&.kind.==("analytic")).should eq(19)
      dataset.unported.count(&.kind.==("stock")).should eq(2)
      dataset.unported.count(&.kind.==("followup")).should eq(2)
      migration.notes.count(&.includes?("inactif")).should eq(3)
    ensure
      Partiduo::Api::Modules.activate(actor, "ANALYTIC")
      %w[FOLLOWUP STOCK].each { |code| Partiduo::Api::Modules.deactivate(actor, code) }
    end
  end
end
