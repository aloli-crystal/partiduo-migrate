# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias B = PartiduoMigrate::SpecSupport::FecBuilder

private def cli(*args : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = PartiduoMigrate::CLI.new(stdout, stderr).run(args.to_a)
  {status, stdout.to_s, stderr.to_s}
end

private def reading_failures(dataset : PartiduoMigrate::Source::Dataset) : Array({String, String})
  PartiduoMigrate::Reconciliation.reading(dataset).flat_map do |section|
    section.rows.reject(&.ok?).map { |row| {section.key, row.key} }
  end
end

# Copie de travail de la base NOALYSS de démonstration, propre à ce
# processus, que la spec peut altérer.
private def with_noalyss_copy(&)
  name = "partiduo_test_m_noalyss_#{Process.pid}"
  status = Process.run(File.join(PartiduoMigrate::SpecSupport::ROOT, "scripts", "noalyss-demo"), [name],
    output: Process::Redirect::Close, error: Process::Redirect::Inherit)
  raise "scripts/noalyss-demo #{name} en échec" unless status.success?
  yield PartiduoMigrate::SpecSupport.database_url(name)
ensure
  name.try { |base| Process.run("dropdb", ["--if-exists", base]) }
end

describe "Contrôle de lecture de la source" do
  it "concorde pour le FEC et la base NOALYSS de démonstration" do
    reading_failures(demo_dataset).should be_empty
    dataset = PartiduoMigrate::Noalyss::Database.new(PartiduoMigrate::SpecSupport.noalyss_url).read(with_attachments: false)
    sections = PartiduoMigrate::Reconciliation.reading(dataset)
    sections.map(&.key).should eq(%w[reading_accounts reading_journals reading_periods])
    sections.first.columns.should eq(%w[lines debit credit balance])
    reading_failures(dataset).should be_empty
    sections[1].rows.map(&.key).should eq(%w[A01 F01 O01 V01])
  end

  it "compare le FEC brut au modèle sur le solde quand une ligne porte débit et crédit" do
    dataset = B.dataset([
      B.row("OD", "1", "20240105", "512000", debit: "15,00", credit: "5,00"),
      B.row("OD", "1", "20240105", "580000", credit: "10,00"),
    ])
    PartiduoMigrate::Reconciliation.reading(dataset).first.columns.should eq(%w[lines balance])
    reading_failures(dataset).should be_empty
  end

  it "voit un modèle FEC qui ne correspond plus au fichier lu" do
    dataset = B.dataset([
      B.row("OD", "1", "20240105", "512000", debit: "10,00"),
      B.row("OD", "1", "20240105", "580000", credit: "10,00"),
    ])
    entry = dataset.entries.first
    entry.lines[0] = entry.lines[0].copy_with(debit: BigDecimal.new("10.01"))
    reading_failures(dataset).should eq([{"reading_accounts", "512000"}, {"reading_journals", "OD"},
                                         {"reading_periods", "2024-01"}])
  end

  it "fait échouer la reprise d'une base NOALYSS mal lue (ligne sans opération, ligne dédoublée)" do
    with_noalyss_copy do |url|
      DB.open(url) do |db|
        # Deux lignes `operation_currency` pour une même ligne : le LEFT JOIN
        # de la lecture des écritures la dédouble.
        db.exec("INSERT INTO operation_currency (oc_amount, j_id) VALUES (1, 1), (1, 1)")
        # Ligne d'écriture sans opération (`jrn`) : absente de la jointure.
        db.exec("INSERT INTO jrnx (j_date, j_montant, j_poste, j_grpt, j_jrn_def, j_debit, j_tech_user, j_tech_per) " \
                "SELECT j_date, 5, j_poste, 999999, j_jrn_def, true, j_tech_user, j_tech_per FROM jrnx WHERE j_id = 2")
      end
      dataset = PartiduoMigrate::Noalyss::Database.new(url).read(with_attachments: false)
      failures = reading_failures(dataset)
      failures.should contain({"reading_accounts", "510001"})
      failures.should contain({"reading_accounts", "4100003"})
      PartiduoMigrate::SpecSupport.provision!
      migration = PartiduoMigrate::Migration.new(dataset)
      migration.run.should be_false
      migration.comparison.present!.reading_ok?.should be_false
      Partiduo::Api::Accounting.count_entries(actor).should eq(0)
    end
  end

  it "rend compte du contrôle de lecture à la commande check" do
    status, stdout, _ = cli("check", "--fec", PartiduoMigrate::SpecSupport::DEMO_FEC)
    status.should eq(0)
    stdout.should contain("Contrôle de lecture : la source relue indépendamment concorde avec son modèle.")
  end
end

describe "Lecture d'un FEC : zones et encodage" do
  it "refuse une ligne qui a plus de zones que l'en-tête (séparateur dans un libellé)" do
    reader = PartiduoMigrate::Fec::Reader.new
    row = B.row("OD", "1", "20240105", "512000", debit: "10,00", label: "Virement\tbanque")
    reader.read(B.bytes([row]), "123456789FEC20241231.txt")
    reader.problems.map(&.to_s).should eq(["ligne 2 : 19 zones au lieu de 18"])
  end

  it "tolère un séparateur terminal annoncé par l'en-tête" do
    reader = PartiduoMigrate::Fec::Reader.new
    rows = [B::HEADER + "\t", B.row("OD", "1", "20240105", "512000", debit: "10,00") + "\t",
            B.row("OD", "1", "20240105", "580000", credit: "10,00") + "\t"]
    dataset = reader.read(rows.join("\r\n").to_slice, "123456789FEC20241231.txt")
    reader.problems.should be_empty
    dataset.entries.first.total_debit.should eq(BigDecimal.new(10))
  end

  it "lit en Windows-1252 un fichier dont l'ISO 8859-15 donnerait des caractères de contrôle" do
    text = B::HEADER + "\r\n" + B.row("OD", "1", "20240105", "512000", debit: "10,00", label: "Frais 5 €") + "\r\n" +
           B.row("OD", "1", "20240105", "580000", credit: "10,00", label: "Frais 5 €")
    reader = PartiduoMigrate::Fec::Reader.new
    dataset = reader.read(text.encode("WINDOWS-1252"), "123456789FEC20241231.txt")
    reader.problems.should be_empty
    reader.encoding.should eq("WINDOWS-1252")
    reader.warnings.should be_empty
    dataset.entries.first.label.should eq("Frais 5 €")
  end

  it "avertit quand un octet de contrôle reste inexpliqué" do
    bytes = B.bytes([B.row("OD", "1", "20240105", "512000", debit: "10,00", label: "X"),
                     B.row("OD", "1", "20240105", "580000", credit: "10,00", label: "X")])
    bytes = String.new(bytes).sub("\tX\t", "\tX\u{1}\t").to_slice.dup
    index = bytes.index!(0x01_u8)
    bytes[index] = 0x81_u8 # indéfini en Windows-1252, C1 en ISO 8859-15
    reader = PartiduoMigrate::Fec::Reader.new
    reader.read(bytes, "123456789FEC20241231.txt")
    reader.encoding.should eq("ISO-8859-15")
    reader.warnings.first.should contain("caractères de contrôle C1")
  end
end

describe "Rapport : cellules CSV et URL de la source" do
  it "neutralise les cellules de texte qui seraient lues comme une formule" do
    PartiduoMigrate::Report.cell("=HYPERLINK(\"x\")").should eq("'=HYPERLINK(\"x\")")
    %w[+1 -1 @SUM].each { |text| PartiduoMigrate::Report.cell(text).should eq("'#{text}") }
    PartiduoMigrate::Report.cell("\tx").should eq("'\tx")
    PartiduoMigrate::Report.cell("Banque").should eq("Banque")

    PartiduoMigrate::SpecSupport.provision!
    row = B.row("OD", "1", "20240105", "471000", debit: "10,00").split('\t')
    row[5] = "=1+2"
    dataset = B.dataset([row.join('\t'), B.row("OD", "1", "20240105", "580000", credit: "10,00")])
    migration = PartiduoMigrate::Migration.new(dataset)
    migration.run.should be_true
    dir = PartiduoMigrate::SpecSupport.report_dir
    PartiduoMigrate::Report.new(dir, migration).write
    rows = CSV.parse(File.read(File.join(dir, "balance-generale.csv")))
    rows.find! { |cells| cells[0] == "471000" }[1].should eq("'=1+2")
    # Les montants négatifs ne sont pas touchés.
    rows.find! { |cells| cells[0] == "580000" }.should contain("-10")
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end

  it "masque utilisateur et mot de passe de l'URL NOALYSS dans les messages" do
    database = PartiduoMigrate::Noalyss::Database.new("postgres://compta:secret@127.0.0.1:1/dossier")
    database.safe_url.should_not contain("secret")
    database.safe_url.should_not contain("compta")
    database.warnings.first.should contain("socket Unix")
    error = expect_raises(PartiduoMigrate::Noalyss::Error) { database.read }
    error.message.to_s.should_not contain("secret")

    socket = PartiduoMigrate::Noalyss::Database.new("postgres:///dossier?host=/tmp&password=secret")
    socket.warnings.should be_empty
    socket.safe_url.should eq("postgres:///dossier?host=%2Ftmp")
  end
end

describe "Langues de l'outil" do
  it "a les mêmes clés en français, en anglais et en néerlandais" do
    keys = ->(locale : String) do
      flatten = uninitialized Proc(YAML::Any, String, Array(String))
      flatten = ->(node : YAML::Any, prefix : String) do
        if hash = node.as_h?
          hash.flat_map { |key, value| flatten.call(value, "#{prefix}.#{key.as_s}") }
        else
          [prefix]
        end
      end
      path = File.join(PartiduoMigrate::SpecSupport::ROOT, "config", "locales", "#{locale}.yml")
      flatten.call(YAML.parse(File.read(path))[locale], "").sort
    end
    french = keys.call("fr")
    keys.call("en").should eq(french)
    keys.call("nl").should eq(french)
    french.should contain(".migrate.rolled_back")
  end

  it "parle anglais ou néerlandais avec --locale" do
    status, stdout, _ = cli("check", "--fec", PartiduoMigrate::SpecSupport::DEMO_FEC, "--locale", "en")
    status.should eq(0)
    stdout.should contain("133 entry(ies), 354 line(s)")
    stdout.should contain("balanced.")
    cli("--locale=nl", "--help")[1].should contain("Gebruik: partiduo-migrate")
    status, _, stderr = cli("--locale", "de", "check")
    status.should eq(2)
    stderr.should contain("langue inconnue « de »")
  end

  it "écrit le rapport dans la langue choisie" do
    PartiduoMigrate::SpecSupport.provision!
    dir = PartiduoMigrate::SpecSupport.report_dir
    status, stdout, _ = cli("import", "--locale", "en", "--fec", PartiduoMigrate::SpecSupport::DEMO_FEC,
      "--report", dir, "--dry-run")
    status.should eq(0)
    stdout.should contain("Dry run succeeded (rolled back): 133 entry(ies)")
    report = File.read(File.join(dir, "rapport.adoc"))
    report.should contain("= Reconciliation report — Partiduo migration")
    report.should contain("== Source reading check")
    report.should_not contain("missing translation")
    CSV.parse(File.read(File.join(dir, "balance-generale.csv"))).first.first(3).should eq(["account", "label",
                                                                                           "lines before"])
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end
end
