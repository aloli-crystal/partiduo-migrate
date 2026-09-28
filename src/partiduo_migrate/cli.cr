# SPDX-License-Identifier: AGPL-3.0-or-later

require "option_parser"

module PartiduoMigrate
  # Ligne de commande.
  #
  # ```
  # partiduo-migrate import --fec 732829320FEC20241231.txt --report rapport/
  # partiduo-migrate import --legacy-db 'postgres:///dossier?host=/tmp' --report rapport/
  # partiduo-migrate import --fec F.txt --legacy-db URL     # FEC + compléments de la base d'origine
  # partiduo-migrate check --fec F.txt                    # contrôle du FEC, sans écrire
  # partiduo-migrate export-fec --legacy-db URL --output .  # FEC d'une base d'origine
  # ```
  #
  # L'instance cible est celle de l'environnement (`DATABASE_URL`,
  # `PARTIDUO_MODULES`, `PARTIDUO_MEDIA_ROOT`), comme pour les autres
  # commandes d'une instance. Langue des messages et du rapport : `--locale`
  # (`fr`, `en`, `nl` ; défaut `fr`). Codes de sortie : 0 réussite, 1 échec
  # de la reprise ou de la réconciliation, 2 source illisible ou usage
  # incorrect.
  class CLI
    EXIT_OK      = 0
    EXIT_FAILURE = 1
    EXIT_USAGE   = 2

    getter stdout : IO
    getter stderr : IO

    def initialize(@stdout : IO = STDOUT, @stderr : IO = STDERR)
      @fec = nil.as(String?)
      @legacy_db = nil.as(String?)
      @report = "rapport-reprise"
      @encoding = nil.as(String?)
      @as_of = nil.as(Time?)
      @dry_run = false
      @strict = false
      @fiscal_start = nil.as(Int32?)
      @output = "."
      @separator = '\t'
      @out_encoding = "ISO-8859-15"
      @siren = nil.as(String?)
    end

    private def t(key : String, **params) : String
      PartiduoMigrate.t("cli.#{key}", **params)
    end

    def run(args : Array(String)) : Int32
      locale, args = extract_locale(args)
      unless LOCALES.includes?(locale)
        @stderr.puts "partiduo-migrate : #{t("unknown_locale", locale: locale, locales: LOCALES.join(", "))}"
        return EXIT_USAGE
      end
      I18n.with_locale(locale) { dispatch(args) }
    end

    # `--locale X` ou `--locale=X`, lu avant tout le reste : les messages
    # d'erreur des options sont déjà dans la bonne langue.
    private def extract_locale(args : Array(String)) : {String, Array(String)}
      locale = "fr"
      rest = [] of String
      skip = false
      args.each_with_index do |arg, index|
        if skip
          skip = false
        elsif arg == "--locale"
          locale = args[index + 1]? || ""
          skip = true
        elsif arg.starts_with?("--locale=")
          locale = arg.lchop("--locale=")
        else
          rest << arg
        end
      end
      {locale.downcase, rest}
    end

    private def dispatch(args : Array(String)) : Int32
      command = args.first?
      rest = args.size > 1 ? args[1..] : [] of String
      case command
      when "import"     then import(rest)
      when "check"      then check(rest)
      when "export-fec" then export_fec(rest)
      when "-h", "--help", "help", nil
        @stdout.puts usage
        command.nil? ? EXIT_USAGE : EXIT_OK
      when "--version", "version"
        @stdout.puts "partiduo-migrate #{VERSION} (Partiduo::Api #{Partiduo::API_VERSION})"
        EXIT_OK
      else
        @stderr.puts "partiduo-migrate : #{t("unknown_command", command: command)}\n\n#{usage}"
        EXIT_USAGE
      end
    rescue ex : OptionParser::Exception | Fec::Error | Legacy::Error | ArgumentError | File::Error
      # Source illisible (fichier absent, droits) : code 2, comme un FEC
      # non conforme.
      @stderr.puts "partiduo-migrate : #{ex.message}"
      EXIT_USAGE
    end

    def usage : String
      t("usage", dbversion: Legacy::DBVERSION, locales: LOCALES.join(", "))
    end

    private def parse(args : Array(String), export : Bool = false) : Nil
      parser = OptionParser.new
      parser.on("--fec FILE", "FEC") { |value| @fec = value }
      parser.on("--legacy-db URL", "legacy database") { |value| @legacy_db = value }
      parser.on("--encoding NAME", "encoding") { |value| @encoding = value }
      parser.on("--report DIR", "report") { |value| @report = value }
      parser.on("--as-of DATE", "as-of") { |value| @as_of = parse_date(value) }
      parser.on("--fiscal-start MM", "fiscal-start") do |value|
        month = value.to_i? || raise ArgumentError.new(t("fiscal_start"))
        raise ArgumentError.new(t("fiscal_start")) unless 1 <= month <= 12
        @fiscal_start = month
      end
      parser.on("--dry-run", "dry-run") { @dry_run = true }
      parser.on("--strict", "strict") { @strict = true }
      parser.on("--output PATH", "output") { |value| @output = value }
      parser.on("--separator SEP", "separator") do |value|
        @separator = case value
                     when "tab", "\\t", "tabulation" then '\t'
                     when "pipe", "|"                then '|'
                     else                                 raise ArgumentError.new(t("separator"))
                     end
      end
      parser.on("--out-encoding NAME", "out-encoding") { |value| @out_encoding = Fec::Encoding.canonical(value) }
      parser.on("--siren NUMBER", "SIREN") { |value| @siren = value }
      parser.invalid_option { |flag| raise ArgumentError.new(t("invalid_option", option: flag)) }
      parser.missing_option { |flag| raise ArgumentError.new(t("missing_value", option: flag)) }
      parser.unknown_args do |rest|
        raise ArgumentError.new(t("unexpected_argument", argument: rest.join(' '))) unless rest.empty?
      end
      parser.parse(args)
      if !export && @fec.nil? && @legacy_db.nil?
        raise ArgumentError.new(t("source_expected"))
      end
    end

    private def parse_date(value : String) : Time
      Fec.parse_date(value) || raise ArgumentError.new(t("date_expected", value: value))
    end

    # Source lue : FEC seul, base d'origine seule (écritures comprises), ou FEC
    # complété par la base d'origine (fiches, TVA, exercices, pièces jointes
    # rapprochées par journal, date et pièce).
    private def load : {Source::Dataset, Array({String, String})}
      details = [] of {String, String}
      fec_dataset = nil
      if path = @fec
        reader = Fec::Reader.new(@encoding)
        fec_dataset = reader.read_file(path)
        details << {t("detail_fec"), t("detail_fec_value", file: File.basename(path), encoding: reader.encoding,
          separator: Fec.separator_name(reader.separator))}
        details << {t("detail_sha256"), Digest::SHA256.new.file(path).final.hexstring}
        reader.warnings.each do |warning|
          @stderr.puts "FEC : #{warning}"
          details << {t("detail_warning"), warning}
        end
        unless reader.problems.empty?
          reader.problems.first(50).each { |problem| @stderr.puts "FEC #{problem}" }
          @stderr.puts t("more_problems", total: reader.problems.size - 50) if reader.problems.size > 50
          raise Fec::Error.new(t("fec_rejected", total: reader.problems.size))
        end
      end
      legacy_dataset = @legacy_db.try do |url|
        database = Legacy::Database.new(url)
        database.warnings.each do |warning|
          @stderr.puts "#{t("detail_legacy")} : #{warning}"
          details << {t("detail_warning"), warning}
        end
        database.read
      end
      if legacy_dataset
        details << {t("detail_legacy"), t("detail_legacy_value", description: legacy_dataset.description,
          dbversion: Legacy::DBVERSION)}
      end
      if fec_dataset && legacy_dataset
        {Complement.merge(fec_dataset, legacy_dataset), details}
      elsif dataset = fec_dataset || legacy_dataset
        {dataset, details}
      else
        raise ArgumentError.new(t("source_expected"))
      end
    end

    private def import(args : Array(String)) : Int32
      parse(args)
      dataset, details = load
      migration = Migration.new(dataset, as_of: @as_of, dry_run: @dry_run, fiscal_start_month: @fiscal_start,
        source_details: details, strict: @strict)
      ok = migration.run
      files = Report.new(@report, migration).write
      summary(migration, files)
      ok ? EXIT_OK : EXIT_FAILURE
    end

    private def summary(migration : Migration, files : Array(String)) : Nil
      io = migration.success? ? @stdout : @stderr
      if migration.success?
        key = migration.dry_run? ? "success_dry_run" : "success"
        io.puts t(key, total: migration.counts["entries_created"])
      else
        io.puts t("failure", reason: migration.failure_reason)
        migration.problems.first(20).each do |problem|
          io.puts "  #{problem.step_label} #{problem.reference} : #{problem.message}"
        end
      end
      io.puts t("report", path: File.join(@report, "rapport.adoc"), total: files.size)
    end

    # Contrôle d'un FEC (ou d'une base d'origine) : lecture, conformité,
    # contrôle de lecture, chiffres « avant ».
    private def check(args : Array(String)) : Int32
      parse(args)
      dataset, _ = load
      figures = Reconciliation.before(dataset, Mapping.new, @as_of || dataset.closing_date || dataset.last_date || Time.utc)
      @stdout.puts t("check_summary", description: dataset.description, entries: dataset.entries.size,
        lines: dataset.lines.size, journals: dataset.journals.size, accounts: dataset.accounts.size,
        parties: dataset.parties.size)
      balanced = figures.total.debit == figures.total.credit
      @stdout.puts t(balanced ? "check_balanced" : "check_unbalanced", debit: Fec.format_amount(figures.total.debit),
        credit: Fec.format_amount(figures.total.credit))
      reading = Reconciliation.reading(dataset)
      failures = reading.sum { |section| section.rows.count { |row| !row.ok? } }
      @stdout.puts t(failures.zero? ? "check_reading_ok" : "check_reading_failures", total: failures)
      balanced && failures.zero? ? EXIT_OK : EXIT_FAILURE
    end

    private def export_fec(args : Array(String)) : Int32
      parse(args, export: true)
      url = @legacy_db || raise ArgumentError.new(t("legacy_expected"))
      database = Legacy::Database.new(url)
      database.warnings.each { |warning| @stderr.puts "#{t("detail_legacy")} : #{warning}" }
      dataset = database.read(with_attachments: false)
      last = dataset.last_date || raise ArgumentError.new(t("no_entries"))
      # Date de clôture du nom : fin de l'exercice de la dernière écriture.
      closing = dataset.fiscal_years.compact_map do |year|
        year.ends_on if year.starts_on <= last <= year.ends_on
      end.first? || last
      siren = @siren || database.siren || "000000000"
      path = @output
      path = File.join(path, Fec::Writer.file_name(siren, closing)) if Dir.exists?(path)
      File.open(path, "w") { |file| Fec::Writer.new(@separator, @out_encoding).write(dataset, file) }
      @stdout.puts t("exported", path: path, entries: dataset.entries.size, lines: dataset.lines.size,
        encoding: @out_encoding)
      EXIT_OK
    end
  end
end
