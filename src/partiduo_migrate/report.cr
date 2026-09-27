# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

module PartiduoMigrate
  # Rapport de réconciliation écrit dans un dossier : `rapport.adoc`
  # (lisible, publiable) et un CSV par tableau (`balance-generale.csv`,
  # `balance-agee.csv`, `journaux.csv`, `periodes.csv`, `ecarts.csv`,
  # `anomalies.csv`, `correspondances.csv`, `non-repris.csv`). Montants à
  # point décimal dans les CSV, à virgule dans l'AsciiDoc.
  class Report
    TOTALS_HEADERS = ["lignes/écritures", "débit", "crédit"]
    AGEING_HEADERS = ["non échu", "1 à 30 j", "31 à 60 j", "plus de 60 j", "reste dû"]

    getter directory : String

    def initialize(@directory : String, @migration : Migration)
    end

    def write : Array(String)
      Dir.mkdir_p(@directory)
      files = [] of String
      comparison = @migration.comparison
      if comparison
        files << csv("balance-generale.csv", ["compte", "libellé"], TOTALS_HEADERS + ["solde"], comparison.accounts)
        files << csv("balance-agee.csv", ["fiche", ""], AGEING_HEADERS, comparison.ageing)
        files << csv("journaux.csv", ["journal", ""], TOTALS_HEADERS, comparison.journals)
        files << csv("periodes.csv", ["période", ""], TOTALS_HEADERS, comparison.periods)
        files << write_file("ecarts.csv", CSV.build do |csv|
          csv.row "tableau", "clé", "valeur", "avant", "après", "écart"
          comparison.failures.each do |(section, row)|
            headers = section == "balance âgée" ? AGEING_HEADERS : TOTALS_HEADERS + ["solde"]
            row.differences.each_with_index do |difference, index|
              next if difference.zero?
              csv.row section, row.key, headers[index]? || index.to_s, number(row.before[index]),
                number(row.after[index]), number(difference)
            end
          end
        end)
      end
      files << write_file("anomalies.csv", CSV.build do |csv|
        csv.row "étape", "référence", "bloquant", "message"
        @migration.problems.each { |problem| csv.row problem.step, problem.reference, problem.blocking ? "oui" : "non", problem.message }
      end)
      files << write_file("correspondances.csv", CSV.build do |csv|
        csv.row "objet", "source", "instance"
        @migration.mapping.renamed.each { |(kind, from, to)| csv.row kind, from, to }
      end)
      files << write_file("non-repris.csv", CSV.build do |csv|
        csv.row "nature", "référence", "détail"
        @migration.dataset.unported.each { |item| csv.row item.kind, item.reference, item.detail }
      end)
      files << write_file("rapport.adoc", adoc)
      files
    end

    private def csv(name : String, keys : Array(String), headers : Array(String), rows : Array(Reconciliation::Row)) : String
      write_file(name, CSV.build do |csv|
        columns = [keys[0]]
        columns << keys[1] unless keys[1].empty?
        headers.each { |header| columns << "#{header} avant" }
        headers.each { |header| columns << "#{header} après" }
        columns << "statut"
        csv.row columns
        rows.each do |row|
          values = [row.key]
          values << row.label unless keys[1].empty?
          values.concat(row.before.map { |value| number(value) })
          values.concat(row.after.map { |value| number(value) })
          values << (row.ok? ? "ok" : "ÉCART")
          csv.row values
        end
      end)
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
        io << "= Rapport de réconciliation — reprise Partiduo\n"
        io << ":toc: left\n:toc-title: Table des matières\n:icons: font\n\n"
        header(io)
        synthesis(io)
        @migration.comparison.try { |comparison| comparison_sections(io, comparison) }
        problems(io)
        adjustments(io)
        unported(io)
        io << "== Fichiers\n\n"
        io << "`balance-generale.csv`, `balance-agee.csv`, `journaux.csv`, `periodes.csv`, `ecarts.csv`, " \
              "`anomalies.csv`, `correspondances.csv`, `non-repris.csv`.\n"
      end
    end

    private def header(io : IO) : Nil
      m = @migration
      verdict = m.success? ? "*RÉUSSIE* : la reprise réconcilie au centime près." : "*ÉCHEC* : #{m.failure_reason}"
      io << "[cols=\"1,3\"]\n|===\n"
      io << "|Source |" << escape(m.dataset.description) << "\n"
      m.source_details.each { |label, value| io << "|" << label << " |" << escape(value) << "\n" }
      io << "|Instance |" << escape(m.instance_description) << "\n"
      io << "|Exécution |" << m.started_at.to_s("%Y-%m-%d %H:%M:%S UTC") << "\n"
      io << "|Date de référence de la balance âgée |" << m.as_of.to_s("%Y-%m-%d") << "\n"
      io << "|Mode |" << (m.dry_run? ? "essai à blanc (rien n'est conservé)" : "reprise") << "\n"
      io << "|Résultat |" << verdict << "\n"
      io << "|Données de l'instance |" << (m.committed? ? "*conservées*" : "*annulées* (aucune écriture conservée)") << "\n"
      io << "|===\n\n"
    end

    private def synthesis(io : IO) : Nil
      m = @migration
      io << "== Synthèse\n\n"
      io << "[cols=\"3,1\"]\n|===\n"
      io << "|Écritures de la source |" << m.dataset.entries.size << "\n"
      io << "|Lignes de la source |" << m.dataset.lines.size << "\n"
      io << "|Lignes à zéro ignorées |" << m.dataset.zero_lines << "\n" if m.dataset.zero_lines > 0
      m.counts.to_a.sort_by!(&.[0]).each { |(label, value)| io << "|" << label.sub(/\A./, &.upcase) << " |" << value << "\n" }
      io << "|===\n\n"
    end

    private def comparison_sections(io : IO, comparison : Reconciliation::Comparison) : Nil
      differences(io, comparison)
      totals_table(io, "Totaux", [comparison.totals], label: false, header: "Ensemble", counts: "écritures")
      totals_table(io, "Balance générale", comparison.accounts, label: true, header: "Compte", counts: "lignes",
        balance: true)
      ageing_table(io, comparison)
      totals_table(io, "Totaux par journal", comparison.journals, label: false, header: "Journal", counts: "écritures")
      totals_table(io, "Totaux par période", comparison.periods, label: false, header: "Période", counts: "écritures")
    end

    private def differences(io : IO, comparison : Reconciliation::Comparison) : Nil
      failures = comparison.failures
      io << "== Écarts\n\n"
      if failures.empty?
        io << "Aucun écart : balance générale, balance âgée, journaux, périodes et totaux identiques avant et après.\n\n"
        return
      end
      io << "[WARNING]\n====\n" << failures.size << " ligne(s) en écart : la reprise est un échec. " \
                                                    "Détail dans `ecarts.csv`.\n====\n\n"
      io << "[cols=\"2,2,1,1,1\",options=\"header\"]\n|===\n|Tableau |Clé |Avant |Après |Écart\n"
      failures.first(200).each do |(section, row)|
        row.differences.each_with_index do |difference, index|
          next if difference.zero?
          io << "|" << section << " |" << escape(row.key) << " |" << number(row.before[index]) << " |" <<
            number(row.after[index]) << " |" << number(difference) << "\n"
        end
      end
      io << "|===\n\n"
    end

    private def problems(io : IO) : Nil
      list = @migration.problems
      return if list.empty?
      io << "== Anomalies de reprise\n\n"
      io << "[cols=\"1,2,1,4\",options=\"header\"]\n|===\n|Étape |Référence |Bloquant |Message\n"
      list.first(500).each do |problem|
        io << "|" << escape(problem.step) << " |" << escape(problem.reference) << " |" <<
          (problem.blocking ? "oui" : "non") << " |" << escape(problem.message) << "\n"
      end
      io << "|===\n\n"
    end

    private def adjustments(io : IO) : Nil
      renamed = @migration.mapping.renamed
      notes = @migration.notes
      return if renamed.empty? && notes.empty?
      io << "== Correspondances et ajustements\n\n"
      notes.first(500).each { |note| io << "* " << escape(note) << "\n" }
      io << "\n" unless notes.empty?
      return if renamed.empty?
      io << "[cols=\"1,2,2\",options=\"header\"]\n|===\n|Objet |Source |Instance\n"
      renamed.first(500).each { |(kind, from, to)| io << "|" << kind << " |" << escape(from) << " |" << escape(to) << "\n" }
      io << "|===\n\n"
    end

    private def unported(io : IO) : Nil
      list = @migration.dataset.unported
      return if list.empty?
      io << "== Données non reprises\n\n"
      io << "Portées par la source, sans contrat Partiduo pour les recevoir à ce jour ; " \
            "détail dans `non-repris.csv`. Elles n'entrent pas dans la réconciliation comptable.\n\n"
      io << "[cols=\"3,1\",options=\"header\"]\n|===\n|Nature |Nombre\n"
      list.map(&.kind).tally.to_a.sort!.each { |(kind, count)| io << "|" << kind << " |" << count << "\n" }
      io << "|===\n\n"
    end

    private def totals_table(io : IO, title : String, rows : Array(Reconciliation::Row), label : Bool, header : String,
                             counts : String, balance : Bool = false) : Nil
      io << "== " << title << "\n\n"
      columns = label ? 2 : 1
      width = (["2"] + (label ? ["3"] : [] of String) + ["1"] * ((balance ? 4 : 3) * 2) + ["1"]).join(',')
      io << "[cols=\"" << width << "\",options=\"header\"]\n|===\n"
      io << "|" << header
      io << " |Libellé" if label
      names = [counts, "débit", "crédit"]
      names << "solde" if balance
      names.each { |name| io << " |" << name.capitalize << " avant" }
      names.each { |name| io << " |" << name.capitalize << " après" }
      io << " |Statut\n"
      rows.each do |row|
        io << "|" << escape(row.key)
        io << " |" << escape(row.label) if columns == 2
        (row.before + row.after).each_with_index do |value, index|
          io << " |" << (index % names.size == 0 ? count(value) : amount(value))
        end
        io << " |" << (row.ok? ? "ok" : "*ÉCART*") << "\n"
      end
      io << "|===\n\n"
    end

    private def ageing_table(io : IO, comparison : Reconciliation::Comparison) : Nil
      io << "== Balance âgée des tiers\n\n"
      io << "Au " << comparison.as_of.to_s("%Y-%m-%d") << ", montants signés débit − crédit (positif : le tiers doit).\n\n"
      rows = comparison.ageing
      if rows.empty?
        io << "Aucun tiers.\n\n"
        return
      end
      io << "[cols=\"2," << (["1"] * 11).join(',') << "\",options=\"header\"]\n|===\n|Fiche"
      AGEING_HEADERS.each { |name| io << " |" << name.capitalize << " avant" }
      AGEING_HEADERS.each { |name| io << " |" << name.capitalize << " après" }
      io << " |Statut\n"
      rows.each do |row|
        io << "|" << escape(row.key)
        (row.before + row.after).each { |value| io << " |" << amount(value) }
        io << " |" << (row.ok? ? "ok" : "*ÉCART*") << "\n"
      end
      io << "|===\n\n"
    end

    private def escape(text : String) : String
      text.gsub('|', "\\|")
    end
  end
end
