# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias B = PartiduoMigrate::SpecSupport::FecBuilder

private def cli(*args : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = PartiduoMigrate::CLI.new(stdout, stderr).run(args.to_a)
  {status, stdout.to_s, stderr.to_s}
end

private def read(rows : Array(String), header = B::HEADER) : {PartiduoMigrate::Source::Dataset, Array(String)}
  reader = PartiduoMigrate::Fec::Reader.new
  dataset = reader.read(([header] + rows).join("\n").to_slice, "123456789FEC20241231.txt")
  {dataset, reader.problems.map(&.to_s)}
end

private def test_database_url : String
  Partiduo::Config.database_url
end

describe "Lecture d'un FEC : défauts relevés" do
  it "signale une ligne qui a moins de zones que l'en-tête" do
    _, problems = read([B.row("OD", "1", "20240105", "512000", debit: "10,00").split('\t').first(10).join('\t')])
    problems.should eq(["ligne 2 : 10 zones au lieu de 18"])
  end

  it "signale une écriture dont les lignes n'ont pas la même date" do
    _, problems = read([
      B.row("OD", "1", "20240105", "512000", debit: "10,00"),
      B.row("OD", "1", "20240106", "580000", credit: "10,00"),
    ])
    problems.should eq(["ligne 3, EcritureDate : écriture OD n° 1 : date 20240106 différente de 20240105"])
  end

  it "signale les zones obligatoires vides" do
    _, problems = read([B.row("OD", "", "20240105", "", debit: "10,00")])
    problems.should contain("ligne 2, EcritureNum : zone vide")
    problems.should contain("ligne 2, CompteNum : zone vide")
  end

  it "signale un sens illisible dans la variante Montant / Sens" do
    header = (PartiduoMigrate::Fec::COLUMNS - %w[Debit Credit] + %w[Montant Sens]).join('\t')
    line = ["OD", "Divers", "1", "20240105", "512000", "Banque", "", "", "P1", "20240105", "Virement", "", "", "",
            "", "", "10,00", "X"].join('\t')
    _, problems = read([line], header)
    problems.should contain("ligne 2, Sens : sens illisible : X")
  end

  it "passe un montant négatif de l'autre côté et solde débit et crédit d'une même ligne" do
    dataset, problems = read([
      B.row("OD", "1", "20240105", "512000", debit: "-10,00"),
      B.row("OD", "1", "20240105", "580000", debit: "15,00", credit: "5,00"),
    ])
    problems.should be_empty
    lines = dataset.entries.first.lines
    {lines[0].debit, lines[0].credit}.should eq({BigDecimal.new(0), BigDecimal.new(10)})
    {lines[1].debit, lines[1].credit}.should eq({BigDecimal.new(10), BigDecimal.new(0)})
  end

  it "distingue deux écritures de même numéro dans deux journaux" do
    dataset, problems = read([
      B.row("OD", "1", "20240105", "512000", debit: "10,00"),
      B.row("OD", "1", "20240105", "580000", credit: "10,00"),
      B.row("BQ", "1", "20240107", "512000", debit: "20,00"),
      B.row("BQ", "1", "20240107", "580000", credit: "20,00"),
    ])
    problems.should be_empty
    dataset.entries.map(&.reference).should eq(["OD n° 1", "BQ n° 1"])
  end

  it "lit un en-tête entre guillemets, en casse libre, précédé d'un BOM" do
    header = PartiduoMigrate::Fec::COLUMNS.map { |name| %("#{name.downcase}") }.join('\t')
    text = ([header, B.row("OD", "1", "20240105", "512000", debit: "10,00"),
             B.row("OD", "1", "20240105", "580000", credit: "10,00")]).join("\r\n")
    reader = PartiduoMigrate::Fec::Reader.new
    dataset = reader.read(PartiduoMigrate::Fec::Encoding::UTF8_BOM + text.to_slice)
    reader.problems.should be_empty
    reader.encoding.should eq("UTF-8")
    dataset.entries.size.should eq(1)
  end

  it "refuse un fichier vide" do
    _, problems = read([] of String, "")
    problems.should eq(["ligne 1 : fichier vide"])
  end

  it "ignore une date de clôture impossible dans le nom du fichier" do
    dataset = PartiduoMigrate::Source::Dataset.new("x")
    dataset.file_name = "123456789FEC20241331.txt"
    dataset.closing_date.should be_nil
  end
end

describe "Ligne de commande : sources illisibles et usage" do
  it "rend le code 2 pour un FEC introuvable" do
    status, _, stderr = cli("check", "--fec", File.join(Dir.tempdir, "absent-#{Random::Secure.hex(4)}.txt"))
    status.should eq(2)
    stderr.should contain("partiduo-migrate :")
  end

  it "rend le code 2 pour un FEC déclaré UTF-8 qui ne l'est pas" do
    path = File.join(Dir.tempdir, "fec-#{Random::Secure.hex(4)}.txt")
    File.write(path, PartiduoMigrate::Fec::Encoding.encode(B::HEADER + "\r\n" +
                                                           B.row("OD", "1", "20240105", "512000", label: "Été"), "ISO-8859-15"))
    status, _, stderr = cli("check", "--fec", path, "--encoding", "utf-8")
    status.should eq(2)
    stderr.should contain("UTF-8 valide")
    cli("check", "--fec", path, "--encoding", "ebcdic")[0].should eq(2)
  ensure
    path.try { |file| File.delete?(file) }
  end

  it "refuse (code 2) au contrôle un FEC à écriture déséquilibrée" do
    path = File.join(Dir.tempdir, "fec-#{Random::Secure.hex(4)}.txt")
    File.write(path, B.bytes([B.row("OD", "1", "20240105", "512000", debit: "10,00"),
                              B.row("OD", "1", "20240105", "580000", credit: "9,99")]))
    status, _, stderr = cli("check", "--fec", path)
    status.should eq(2)
    stderr.should contain("déséquilibrée (débit 10,00, crédit 9,99)")
  ensure
    path.try { |file| File.delete?(file) }
  end

  it "refuse les options invalides (code 2)" do
    fec = PartiduoMigrate::SpecSupport::DEMO_FEC
    cli("import", "--fec", fec, "--fiscal-start", "13")[2].should contain("--fiscal-start")
    cli("import", "--fec", fec, "--fiscal-start", "13")[0].should eq(2)
    cli("import", "--fec", fec, "--as-of", "2024-02-30")[0].should eq(2)
    cli("import", "--fec", fec, "--inconnue")[0].should eq(2)
    cli("import", "--fec")[0].should eq(2)
    cli("export-fec")[2].should contain("--legacy-db URL attendu")
    cli("export-fec", "--legacy-db", "x", "--separator", ";")[0].should eq(2)
  end

  it "rend le code 2 pour une base d'origine injoignable ou d'une autre version" do
    status, _, stderr = cli("check", "--legacy-db", "postgres:///partiduo_absente_#{Random::Secure.hex(4)}?host=/tmp")
    status.should eq(2)
    stderr.should contain("base d'origine illisible")
    # La base de test de Partiduo n'a pas la table `version` de l'application d'origine.
    expect_raises(PartiduoMigrate::Legacy::Error) { PartiduoMigrate::Legacy::Database.new(test_database_url).read }
  end

  it "ne modifie jamais la base d'origine lue (session en lecture seule)" do
    url = PartiduoMigrate::SpecSupport.legacy_url
    before = DB.open(url) { |db| db.query_one("SELECT count(*) FROM jrnx", as: Int64) }
    PartiduoMigrate::Legacy::Database.new(url).read(with_attachments: false)
    DB.open(url) { |db| db.query_one("SELECT count(*) FROM jrnx", as: Int64) }.should eq(before)
  end
end
