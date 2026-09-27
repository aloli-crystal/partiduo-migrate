# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def cli(*args : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = PartiduoMigrate::CLI.new(stdout, stderr).run(args.to_a)
  {status, stdout.to_s, stderr.to_s}
end

describe PartiduoMigrate::CLI do
  it "reprend le FEC de démonstration et écrit le rapport (code 0)" do
    PartiduoMigrate::SpecSupport.provision!
    dir = PartiduoMigrate::SpecSupport.report_dir
    status, stdout, _ = cli("import", "--fec", PartiduoMigrate::SpecSupport::DEMO_FEC, "--report", dir)
    status.should eq(0)
    stdout.should contain("Reprise réussie : 133 écriture(s), réconciliation au centime.")
    File.read(File.join(dir, "rapport.adoc")).should contain("|Empreinte SHA-256 du FEC |")
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end

  it "échoue (code 1) sur une instance déjà alimentée" do
    PartiduoMigrate::SpecSupport.provision!
    dir = PartiduoMigrate::SpecSupport.report_dir
    cli("import", "--fec", PartiduoMigrate::SpecSupport::DEMO_FEC, "--report", dir)[0].should eq(0)
    status, _, stderr = cli("import", "--fec", PartiduoMigrate::SpecSupport::DEMO_FEC, "--report", dir)
    status.should eq(1)
    stderr.should contain("Reprise en échec")
    File.read(File.join(dir, "rapport.adoc")).should contain("*ÉCHEC*")
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end

  it "refuse (code 2) un FEC non conforme sans toucher l'instance" do
    PartiduoMigrate::SpecSupport.provision!
    path = File.join(Dir.tempdir, "fec-#{Random::Secure.hex(4)}.txt")
    File.write(path, "JournalCode;JournalLib\n")
    status, _, stderr = cli("import", "--fec", path)
    status.should eq(2)
    stderr.should contain("FEC non conforme")
    Partiduo::Api::Accounting.count_entries(actor).should eq(0)
  ensure
    path.try { |file| File.delete?(file) }
  end

  it "contrôle un FEC sans rien écrire" do
    status, stdout, _ = cli("check", "--fec", PartiduoMigrate::SpecSupport::DEMO_FEC)
    status.should eq(0)
    stdout.should contain("133 écriture(s), 354 ligne(s)")
    stdout.should contain("Total débit 246290,77, crédit 246290,77 : équilibré.")
  end

  it "exporte le FEC d'une base NOALYSS" do
    dir = PartiduoMigrate::SpecSupport.report_dir
    Dir.mkdir_p(dir)
    status, stdout, _ = cli("export-fec", "--noalyss", PartiduoMigrate::SpecSupport.noalyss_url, "--output", dir)
    status.should eq(0)
    stdout.should contain("732829320FEC20241231.txt")
    File.read(File.join(dir, "732829320FEC20241231.txt")).should eq(File.read(PartiduoMigrate::SpecSupport::DEMO_FEC))
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end

  it "explique son usage" do
    cli("--help")[1].should contain("Usage : partiduo-migrate")
    status, _, stderr = cli("import")
    status.should eq(2)
    stderr.should contain("source attendue")
    cli("inconnue")[0].should eq(2)
  end
end
