# SPDX-License-Identifier: AGPL-3.0-or-later

require "option_parser"

module PartiduoMigrate
  # Ligne de commande.
  #
  # ```
  # partiduo-migrate import --fec 732829320FEC20241231.txt --report rapport/
  # partiduo-migrate import --noalyss 'postgres:///dossier?host=/tmp' --report rapport/
  # partiduo-migrate import --fec F.txt --noalyss URL     # FEC + compléments NOALYSS
  # partiduo-migrate check --fec F.txt --report rapport/  # contrôle du FEC, sans écrire
  # partiduo-migrate export-fec --noalyss URL --output .  # FEC d'une base NOALYSS
  # ```
  #
  # L'instance cible est celle de l'environnement (`DATABASE_URL`,
  # `PARTIDUO_MODULES`, `PARTIDUO_MEDIA_ROOT`), comme pour les autres
  # commandes d'une instance. Codes de sortie : 0 réussite, 1 échec de la
  # reprise ou de la réconciliation, 2 source illisible ou usage incorrect.
  class CLI
    EXIT_OK      = 0
    EXIT_FAILURE = 1
    EXIT_USAGE   = 2

    getter stdout : IO
    getter stderr : IO

    def initialize(@stdout : IO = STDOUT, @stderr : IO = STDERR)
      @fec = nil.as(String?)
      @noalyss = nil.as(String?)
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

    def run(args : Array(String)) : Int32
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
        @stdout.puts "partiduo-migrate #{VERSION} (contrat Partiduo::Api #{Partiduo::API_VERSION})"
        EXIT_OK
      else
        @stderr.puts "partiduo-migrate : commande inconnue « #{command} »\n\n#{usage}"
        EXIT_USAGE
      end
    rescue ex : OptionParser::Exception | Fec::Error | Noalyss::Error | ArgumentError
      @stderr.puts "partiduo-migrate : #{ex.message}"
      EXIT_USAGE
    end

    def usage : String
      <<-TEXT
        Usage : partiduo-migrate <commande> [options]

        Commandes :
          import      reprend un dossier dans l'instance de DATABASE_URL (instance neuve)
          check       contrôle un FEC et calcule ses chiffres, sans rien écrire
          export-fec  écrit le FEC d'une base NOALYSS (DBVERSION #{Noalyss::DBVERSION})

        Sources (import, check) :
          --fec FICHIER          fichier des écritures comptables (tabulation ou barre verticale)
          --noalyss URL          base NOALYSS, par socket Unix : postgres:///dossier?host=/tmp
          --encoding NOM         encodage du FEC (utf-8, iso-8859-15, windows-1252) ; défaut : reconnu

        Reprise (import) :
          --report DOSSIER       dossier du rapport de réconciliation (défaut rapport-reprise)
          --as-of AAAA-MM-JJ     date de référence de la balance âgée (défaut : clôture du FEC)
          --fiscal-start MM      premier mois des exercices créés pour un FEC (défaut : d'après le nom)
          --dry-run              essai à blanc : tout est fait puis annulé
          --strict               un avertissement (fiche, TVA, pièce jointe) fait aussi échouer

        Export (export-fec) :
          --output DOSSIER|FICHIER   défaut : dossier courant, nom réglementaire SIRENFECAAAAMMJJ.txt
          --separator tab|pipe       défaut tab
          --out-encoding NOM         défaut iso-8859-15
          --siren NUMÉRO             défaut : paramètres du dossier NOALYSS
        TEXT
    end

    private def parse(args : Array(String), export : Bool = false) : Nil
      parser = OptionParser.new
      parser.on("--fec FICHIER", "FEC") { |value| @fec = value }
      parser.on("--noalyss URL", "base NOALYSS") { |value| @noalyss = value }
      parser.on("--encoding NOM", "encodage du FEC") { |value| @encoding = value }
      parser.on("--report DOSSIER", "dossier du rapport") { |value| @report = value }
      parser.on("--as-of DATE", "date de la balance âgée") { |value| @as_of = parse_date(value) }
      parser.on("--fiscal-start MM", "premier mois") do |value|
        month = value.to_i? || raise ArgumentError.new("--fiscal-start : mois attendu (1 à 12)")
        raise ArgumentError.new("--fiscal-start : mois attendu (1 à 12)") unless 1 <= month <= 12
        @fiscal_start = month
      end
      parser.on("--dry-run", "essai à blanc") { @dry_run = true }
      parser.on("--strict", "avertissements bloquants") { @strict = true }
      parser.on("--output CHEMIN", "sortie du FEC") { |value| @output = value }
      parser.on("--separator SEP", "séparateur") do |value|
        @separator = case value
                     when "tab", "\\t", "tabulation" then '\t'
                     when "pipe", "|"                then '|'
                     else                                 raise ArgumentError.new("--separator : tab ou pipe")
                     end
      end
      parser.on("--out-encoding NOM", "encodage du FEC écrit") { |value| @out_encoding = Fec::Encoding.canonical(value) }
      parser.on("--siren NUMÉRO", "SIREN") { |value| @siren = value }
      parser.invalid_option { |flag| raise ArgumentError.new("option inconnue : #{flag}") }
      parser.missing_option { |flag| raise ArgumentError.new("valeur manquante : #{flag}") }
      parser.unknown_args { |rest| raise ArgumentError.new("argument inattendu : #{rest.join(' ')}") unless rest.empty? }
      parser.parse(args)
      if !export && @fec.nil? && @noalyss.nil?
        raise ArgumentError.new("source attendue : --fec FICHIER et/ou --noalyss URL")
      end
    end

    private def parse_date(value : String) : Time
      Fec.parse_date(value) || raise ArgumentError.new("date attendue : #{value}")
    end

    # Source lue : FEC seul, base NOALYSS seule (écritures comprises), ou FEC
    # complété par la base NOALYSS (fiches, TVA, exercices, pièces jointes
    # rapprochées par journal, date et pièce).
    private def load : {Source::Dataset, Array({String, String})}
      details = [] of {String, String}
      fec_dataset = nil
      if path = @fec
        reader = Fec::Reader.new(@encoding)
        fec_dataset = reader.read_file(path)
        details << {"FEC", "#{File.basename(path)} (#{reader.encoding}, séparateur #{Fec::SEPARATORS[reader.separator]? || reader.separator})"}
        details << {"Empreinte SHA-256 du FEC", Digest::SHA256.new.file(path).final.hexstring}
        unless reader.problems.empty?
          reader.problems.first(50).each { |problem| @stderr.puts "FEC #{problem}" }
          @stderr.puts "… #{reader.problems.size - 50} autre(s)" if reader.problems.size > 50
          raise Fec::Error.new("FEC non conforme : #{reader.problems.size} défaut(s), rien n'est importé")
        end
      end
      noalyss_dataset = @noalyss.try { |url| Noalyss::Database.new(url).read }
      if noalyss_dataset
        details << {"Base NOALYSS", "#{noalyss_dataset.description}, DBVERSION #{Noalyss::DBVERSION}"}
      end
      if fec_dataset && noalyss_dataset
        {Complement.merge(fec_dataset, noalyss_dataset), details}
      elsif dataset = fec_dataset || noalyss_dataset
        {dataset, details}
      else
        raise ArgumentError.new("source attendue : --fec FICHIER et/ou --noalyss URL")
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
        io.puts "Reprise #{migration.dry_run? ? "réussie à blanc (annulée)" : "réussie"} : " \
                "#{migration.counts["écritures créées"]} écriture(s), réconciliation au centime."
      else
        io.puts "Reprise en échec (#{migration.failure_reason}) : l'instance n'a pas été modifiée."
        migration.problems.first(20).each do |problem|
          io.puts "  #{problem.step} #{problem.reference} : #{problem.message}"
        end
      end
      io.puts "Rapport : #{File.join(@report, "rapport.adoc")} (#{files.size} fichiers)"
    end

    # Contrôle d'un FEC : lecture, conformité, chiffres « avant ».
    private def check(args : Array(String)) : Int32
      parse(args)
      dataset, _ = load
      figures = Reconciliation.before(dataset, Mapping.new, @as_of || dataset.closing_date || dataset.last_date || Time.utc)
      @stdout.puts "#{dataset.description} : #{dataset.entries.size} écriture(s), #{dataset.lines.size} ligne(s), " \
                   "#{dataset.journals.size} journal(aux), #{dataset.accounts.size} compte(s), " \
                   "#{dataset.parties.size} compte(s) auxiliaire(s)."
      @stdout.puts "Total débit #{Fec.format_amount(figures.total.debit)}, crédit #{Fec.format_amount(figures.total.credit)}" \
                   "#{figures.total.debit == figures.total.credit ? " : équilibré." : " : DÉSÉQUILIBRÉ."}"
      figures.total.debit == figures.total.credit ? EXIT_OK : EXIT_FAILURE
    end

    private def export_fec(args : Array(String)) : Int32
      parse(args, export: true)
      url = @noalyss || raise ArgumentError.new("--noalyss URL attendu")
      database = Noalyss::Database.new(url)
      dataset = database.read(with_attachments: false)
      last = dataset.last_date || raise ArgumentError.new("aucune écriture dans la base NOALYSS")
      # Date de clôture du nom : fin de l'exercice de la dernière écriture.
      closing = dataset.fiscal_years.compact_map do |year|
        ends = year.starts_on.shift(months: year.months, days: -1)
        ends if year.starts_on <= last <= ends
      end.first? || last
      siren = @siren || database.siren || "000000000"
      path = @output
      path = File.join(path, Fec::Writer.file_name(siren, closing)) if Dir.exists?(path)
      File.open(path, "w") { |file| Fec::Writer.new(@separator, @out_encoding).write(dataset, file) }
      @stdout.puts "FEC écrit : #{path} (#{dataset.entries.size} écriture(s), #{dataset.lines.size} ligne(s), " \
                   "#{@out_encoding})"
      EXIT_OK
    end
  end
end
