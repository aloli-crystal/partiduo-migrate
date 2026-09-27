# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

module PartiduoMigrate
  # Rapport de réconciliation écrit dans un dossier : `rapport.adoc`
  # (lisible, publiable) et un CSV par tableau (`balance-generale.csv`,
  # `balance-agee.csv`, `journaux.csv`, `periodes.csv`, `lecture-source.csv`,
  # `ecarts.csv`, `anomalies.csv`, `correspondances.csv`, `non-repris.csv`).
  # Textes dans la langue active (`--locale`) ; noms de fichiers fixes.
  # Montants à point décimal dans les CSV, à virgule dans l'AsciiDoc. Les
  # cellules de texte des CSV sont neutralisées contre l'interprétation en
  # formule par un tableur (`cell`).
  class Report
    FILES = {"accounts" => "balance-generale.csv", "ageing" => "balance-agee.csv", "journals" => "journaux.csv",
             "periods" => "periodes.csv"}

    getter directory : String

    def initialize(@directory : String, @migration : Migration)
    end

    private def t(key : String, **params) : String
      PartiduoMigrate.t("report.#{key}", **params)
    end

    private def column(key : String) : String
      PartiduoMigrate.t("columns.#{key}")
    end

    private def section_name(key : String) : String
      PartiduoMigrate.t("sections.#{key}")
    end

    def write : Array(String)
      Dir.mkdir_p(@directory)
      files = [] of String
      comparison = @migration.comparison
      if comparison
        FILES.each do |key, name|
          section = comparison.section(key) || next
          files << csv(name, section)
        end
        files << write_file("lecture-source.csv", CSV.build do |csv|
          csv.row t("csv.section"), t("csv.key"), t("csv.value"), t("csv.source"), t("csv.model"), t("csv.status")
          comparison.reading.each do |section|
            section.rows.each do |row|
              section.columns.each_with_index do |name, index|
                csv.row cell(section_name(section.key)), cell(row.key), cell(column(name)), number(row.before[index]),
                  number(row.after[index]), row.differences[index].zero? ? t("ok") : t("difference")
              end
            end
          end
        end)
        files << write_file("ecarts.csv", CSV.build do |csv|
          csv.row t("csv.section"), t("csv.key"), t("csv.value"), t("csv.before"), t("csv.after"), t("csv.difference")
          comparison.failures.each do |(section, row)|
            row.differences.each_with_index do |difference, index|
              next if difference.zero?
              csv.row cell(section_name(section.key)), cell(row.key), cell(column(section.columns[index]? || index.to_s)),
                number(row.before[index]), number(row.after[index]), number(difference)
            end
          end
        end)
      end
      files << write_file("anomalies.csv", CSV.build do |csv|
        csv.row t("csv.step"), t("csv.reference"), t("csv.blocking"), t("csv.message")
        @migration.problems.each do |problem|
          csv.row cell(problem.step_label), cell(problem.reference), problem.blocking ? t("yes") : t("no"),
            cell(problem.message)
        end
      end)
      files << write_file("correspondances.csv", CSV.build do |csv|
        csv.row t("csv.object"), t("csv.source"), t("csv.instance")
        @migration.mapping.renamed.each { |(kind, from, to)| csv.row cell(kind), cell(from), cell(to) }
      end)
      files << write_file("non-repris.csv", CSV.build do |csv|
        csv.row t("csv.kind"), t("csv.reference"), t("csv.detail")
        @migration.dataset.all_unported.each do |item|
          csv.row cell(PartiduoMigrate.t("unported.#{item.kind}")), cell(item.reference), cell(item.detail)
        end
      end)
      files << write_file("rapport.adoc", adoc)
      files
    end

    private def csv(name : String, section : Reconciliation::Section) : String
      write_file(name, CSV.build do |csv|
        columns = [t("csv.#{section.key}_key")]
        columns << t("csv.label") if section.labelled
        section.columns.each { |key| columns << t("csv.before_column", column: column(key)) }
        section.columns.each { |key| columns << t("csv.after_column", column: column(key)) }
        columns << t("csv.status")
        csv.row columns
        section.rows.each do |row|
          values = [cell(row.key)]
          values << cell(row.label) if section.labelled
          values.concat(row.before.map { |value| number(value) })
          values.concat(row.after.map { |value| number(value) })
          values << (row.ok? ? t("ok") : t("difference"))
          csv.row values
        end
      end)
    end

    # Cellule de texte d'un CSV : une valeur qui commence par `=`, `+`,
    # `-`, `@`, une tabulation ou un retour chariot serait lue comme une
    # formule par un tableur ; elle est précédée d'une apostrophe. Les
    # colonnes numériques (`number`) ne passent pas par ici.
    def self.cell(text : String) : String
      text[0]?.in?('=', '+', '-', '@', '\t', '\r') ? "'#{text}" : text
    end

    private def cell(text : String) : String
      Report.cell(text)
    end

    private def write_file(name : String, content : String) : String
      path = File.join(@directory, name)
      File.write(path, content)
      path
    end

    private def number(value : BigDecimal) : String
      text = value.to_s
      text.includes?('.') ? text.rstrip('0').rstrip('.') : text
    end

    private def amount(value : BigDecimal) : String
      Fec.format_amount(value.round(4))
    end

    private def count(value : BigDecimal) : String
      value.to_i64.to_s
    end

    # --- AsciiDoc ------------------------------------------------------------

    private def adoc : String
      String.build do |io|
        io << "= " << t("title") << "\n"
        io << ":toc: left\n:toc-title: " << t("toc") << "\n:icons: font\n\n"
        header(io)
        synthesis(io)
        @migration.comparison.try { |comparison| comparison_sections(io, comparison) }
        problems(io)
        adjustments(io)
        unported(io)
        io << "== " << t("files_title") << "\n\n"
        io << "`balance-generale.csv`, `balance-agee.csv`, `journaux.csv`, `periodes.csv`, `lecture-source.csv`, " \
              "`ecarts.csv`, `anomalies.csv`, `correspondances.csv`, `non-repris.csv`.\n"
      end
    end

    private def header(io : IO) : Nil
      m = @migration
      verdict = m.success? ? t("verdict_success") : t("verdict_failure", reason: m.failure_reason)
      io << "[cols=\"1,3\"]\n|===\n"
      io << "|" << t("source") << " |" << escape(m.dataset.description) << "\n"
      m.source_details.each { |label, value| io << "|" << escape(label) << " |" << escape(value) << "\n" }
      io << "|" << t("instance") << " |" << escape(m.instance_description) << "\n"
      io << "|" << t("run_at") << " |" << m.started_at.to_s("%Y-%m-%d %H:%M:%S UTC") << "\n"
      io << "|" << t("as_of") << " |" << m.as_of.to_s("%Y-%m-%d") << "\n"
      io << "|" << t("mode") << " |" << (m.dry_run? ? t("mode_dry_run") : t("mode_import")) << "\n"
      io << "|" << t("result") << " |" << verdict << "\n"
      io << "|" << t("data") << " |" << (m.committed? ? t("data_kept") : t("data_rolled_back")) << "\n"
      io << "|===\n\n"
    end

    private def synthesis(io : IO) : Nil
      m = @migration
      dataset = m.dataset
      io << "== " << t("synthesis") << "\n\n"
      io << "[cols=\"3,1\"]\n|===\n"
      io << "|" << t("source_entries") << " |" << dataset.entries.size << "\n"
      io << "|" << t("source_lines") << " |" << dataset.lines.size << "\n"
      io << "|" << t("zero_lines") << " |" << dataset.zero_lines << "\n" if dataset.zero_lines > 0
      io << "|" << t("letter_dates") << " |" << dataset.letter_dates << "\n" if dataset.letter_dates > 0
      io << "|" << t("receipt_dates") << " |" << dataset.receipt_dates << "\n" if dataset.receipt_dates > 0
      m.counts.map { |key, value| {PartiduoMigrate.t("counts.#{key}"), value} }.sort!.each do |(label, value)|
        io << "|" << label << " |" << value << "\n"
      end
      io << "|===\n\n"
    end

    private def comparison_sections(io : IO, comparison : Reconciliation::Comparison) : Nil
      differences(io, comparison)
      reading(io, comparison)
      {"total" => "totals_title", "accounts" => "accounts_title", "ageing" => "ageing_title",
       "journals" => "journals_title", "periods" => "periods_title"}.each do |key, title|
        section = comparison.section(key) || next
        key == "ageing" ? ageing_table(io, comparison, section) : totals_table(io, t(title), section)
      end
    end

    private def differences(io : IO, comparison : Reconciliation::Comparison) : Nil
      failures = comparison.failures
      io << "== " << t("differences_title") << "\n\n"
      if failures.empty?
        io << t("no_difference") << "\n\n"
        return
      end
      io << "[WARNING]\n====\n" << t("differences_warning", total: failures.size) << "\n====\n\n"
      io << "[cols=\"2,2,2,1,1,1\",options=\"header\"]\n|===\n|" << t("csv.section") << " |" << t("csv.key") <<
        " |" << t("csv.value") << " |" << t("csv.before") << " |" << t("csv.after") << " |" << t("csv.difference") << "\n"
      failures.first(200).each do |(section, row)|
        row.differences.each_with_index do |difference, index|
          next if difference.zero?
          io << "|" << section_name(section.key) << " |" << escape(row.key) << " |" <<
            column(section.columns[index]? || index.to_s) << " |" << number(row.before[index]) << " |" <<
            number(row.after[index]) << " |" << number(difference) << "\n"
        end
      end
      io << "|===\n\n"
    end

    # Contrôle de lecture : la source relue indépendamment face au modèle.
    private def reading(io : IO, comparison : Reconciliation::Comparison) : Nil
      sections = comparison.reading
      return if sections.empty?
      io << "== " << t("reading_title") << "\n\n"
      io << t(sections.first.columns.size > 2 ? "reading_intro_noalyss" : "reading_intro_fec") << "\n\n"
      failures = sections.sum { |section| section.rows.count { |row| !row.ok? } }
      if failures.zero?
        io << t("reading_ok", accounts: sections[0].rows.size, journals: sections[1].rows.size,
          periods: sections[2].rows.size) << "\n\n"
      else
        io << "[WARNING]\n====\n" << t("reading_failures", total: failures) << "\n====\n\n"
      end
      sections.each do |section|
        io << "=== " << section_name(section.key) << "\n\n"
        widths = (["2"] + ["1"] * (section.columns.size * 2) + ["1"]).join(',')
        io << "[cols=\"" << widths << "\",options=\"header\"]\n|===\n|" << t("csv.key")
        section.columns.each { |name| io << " |" << t("csv.source_column", column: column(name)) }
        section.columns.each { |name| io << " |" << t("csv.model_column", column: column(name)) }
        io << " |" << t("csv.status") << "\n"
        section.rows.each do |row|
          io << "|" << escape(row.key)
          (row.before + row.after).each_with_index do |value, index|
            io << " |" << (index % section.columns.size == 0 ? count(value) : amount(value))
          end
          io << " |" << (row.ok? ? t("ok") : "*#{t("difference")}*") << "\n"
        end
        io << "|===\n\n"
      end
    end

    private def problems(io : IO) : Nil
      list = @migration.problems
      return if list.empty?
      io << "== " << t("problems_title") << "\n\n"
      io << "[cols=\"1,2,1,4\",options=\"header\"]\n|===\n|" << t("csv.step") << " |" << t("csv.reference") << " |" <<
        t("csv.blocking") << " |" << t("csv.message") << "\n"
      list.first(500).each do |problem|
        io << "|" << escape(problem.step_label) << " |" << escape(problem.reference) << " |" <<
          (problem.blocking ? t("yes") : t("no")) << " |" << escape(problem.message) << "\n"
      end
      io << "|===\n\n"
    end

    private def adjustments(io : IO) : Nil
      renamed = @migration.mapping.renamed
      notes = @migration.notes
      return if renamed.empty? && notes.empty?
      io << "== " << t("adjustments_title") << "\n\n"
      notes.first(500).each { |note| io << "* " << escape(note) << "\n" }
      io << "\n" unless notes.empty?
      return if renamed.empty?
      io << "[cols=\"1,2,2\",options=\"header\"]\n|===\n|" << t("csv.object") << " |" << t("csv.source") << " |" <<
        t("csv.instance") << "\n"
      renamed.first(500).each { |(kind, from, to)| io << "|" << escape(kind) << " |" << escape(from) << " |" << escape(to) << "\n" }
      io << "|===\n\n"
    end

    private def unported(io : IO) : Nil
      list = @migration.dataset.all_unported
      return if list.empty?
      io << "== " << t("unported_title") << "\n\n"
      io << t("unported_intro") << "\n\n"
      io << "[cols=\"3,1\",options=\"header\"]\n|===\n|" << t("csv.kind") << " |" << t("count") << "\n"
      list.map { |item| PartiduoMigrate.t("unported.#{item.kind}") }.tally.to_a.sort!.each do |(kind, number)|
        io << "|" << kind << " |" << number << "\n"
      end
      io << "|===\n\n"
    end

    private def totals_table(io : IO, title : String, section : Reconciliation::Section) : Nil
      io << "== " << title << "\n\n"
      width = (["2"] + (section.labelled ? ["3"] : [] of String) + ["1"] * (section.columns.size * 2) + ["1"]).join(',')
      io << "[cols=\"" << width << "\",options=\"header\"]\n|===\n"
      io << "|" << t("csv.#{section.key}_key")
      io << " |" << t("csv.label") if section.labelled
      section.columns.each { |name| io << " |" << t("csv.before_column", column: column(name)).capitalize }
      section.columns.each { |name| io << " |" << t("csv.after_column", column: column(name)).capitalize }
      io << " |" << t("csv.status").capitalize << "\n"
      section.rows.each do |row|
        io << "|" << escape(row.key)
        io << " |" << escape(row.label) if section.labelled
        (row.before + row.after).each_with_index do |value, index|
          io << " |" << (index % section.columns.size == 0 ? count(value) : amount(value))
        end
        io << " |" << (row.ok? ? t("ok") : "*#{t("difference")}*") << "\n"
      end
      io << "|===\n\n"
    end

    private def ageing_table(io : IO, comparison : Reconciliation::Comparison, section : Reconciliation::Section) : Nil
      io << "== " << t("ageing_title") << "\n\n"
      io << t("ageing_intro", date: comparison.as_of.to_s("%Y-%m-%d")) << "\n\n"
      if section.rows.empty?
        io << t("no_party") << "\n\n"
        return
      end
      io << "[cols=\"2," << (["1"] * (section.columns.size * 2 + 1)).join(',') << "\",options=\"header\"]\n|===\n|" <<
        t("csv.ageing_key")
      section.columns.each { |name| io << " |" << t("csv.before_column", column: column(name)).capitalize }
      section.columns.each { |name| io << " |" << t("csv.after_column", column: column(name)).capitalize }
      io << " |" << t("csv.status").capitalize << "\n"
      section.rows.each do |row|
        io << "|" << escape(row.key)
        (row.before + row.after).each { |value| io << " |" << amount(value) }
        io << " |" << (row.ok? ? t("ok") : "*#{t("difference")}*") << "\n"
      end
      io << "|===\n\n"
    end

    private def escape(text : String) : String
      text.gsub('|', "\\|")
    end
  end
end
