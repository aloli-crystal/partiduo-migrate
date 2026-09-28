# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private SOURCES = Dir.glob(File.join(PartiduoMigrate::SpecSupport::ROOT, "src", "**", "*.cr")).sort

describe "Frontière de partiduo-migrate (ADR-001 D5, ADR-003 D6)" do
  it "n'utilise du cœur que le contrat Partiduo::Api (et la version)" do
    offenders = SOURCES.flat_map do |path|
      File.read_lines(path).each_with_index.compact_map do |(line, index)|
        code = line.split('#').first
        uses = code.scan(/Partiduo::(\w+)/).map(&.[1]).reject(&.in?("Api", "API_VERSION"))
        "#{File.basename(path)}:#{index + 1} #{line.strip}" unless uses.empty?
      end
    end
    offenders.should be_empty
  end

  it "n'écrit jamais en SQL dans la base de l'instance" do
    offenders = SOURCES.flat_map do |path|
      File.read_lines(path).each_with_index.compact_map do |(line, index)|
        "#{File.basename(path)}:#{index + 1}" if line.matches?(/Marten::DB|\.exec\(|INSERT |UPDATE |DELETE /i) &&
                                                 !path.ends_with?("legacy/database.cr")
      end
    end
    offenders.should be_empty
  end

  it "ne lit dans la base d'origine ni les utilisateurs ni leurs secrets" do
    source = File.read(File.join(PartiduoMigrate::SpecSupport::ROOT, "src", "partiduo_migrate", "legacy", "database.cr"))
    source.should_not match(/\b(ac_users|user_sec_\w+|profile_user|jnt_use_dos|use_pass|use_login)\b/)
    source.scan(/\b(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)\b/i).should be_empty
  end

  it "commence chaque fichier source par l'en-tête SPDX" do
    files = Dir.glob(File.join(PartiduoMigrate::SpecSupport::ROOT, "{src,spec,config}", "**", "*.cr"))
    files.reject { |path| File.read_lines(path).first? == "# SPDX-License-Identifier: AGPL-3.0-or-later" }
      .should be_empty
  end

  it "ne cite pas le logiciel d'origine hors documentation (*.adoc, *.md)" do
    # Le nom est assemblé pour que ce fichier ne le contienne pas lui-même.
    name = "no" + "alyss"
    output = IO::Memory.new
    status = Process.run("git", ["grep", "-il", name, "--", ".", ":!*.adoc", ":!*.md"],
      chdir: PartiduoMigrate::SpecSupport::ROOT, output: output)
    status.exit_code.should be <= 1
    output.to_s.lines.should be_empty
  end
end
