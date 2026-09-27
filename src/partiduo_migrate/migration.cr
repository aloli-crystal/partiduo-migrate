# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # Une reprise complète : contrôle de l'instance, écriture par le contrat
  # (`Importer`), réconciliation, décision. Le tout dans *une* transaction :
  # une reprise qui ne réconcilie pas au centime, ou qui laisse une
  # anomalie bloquante, est annulée et l'instance reste neuve (ADR-001 D5 :
  # « un échec, pas un avertissement »). En essai à blanc, elle est annulée
  # dans tous les cas. Une exception (refus d'accès, fiche introuvable,
  # erreur SQL) annule la transaction et devient une anomalie bloquante
  # « interne » : le rapport est écrit, la commande sort en échec.
  class Migration
    getter dataset : Source::Dataset
    getter as_of : Time
    getter started_at : Time
    getter comparison : Reconciliation::Comparison? = nil
    getter source_details : Array({String, String})
    getter? dry_run : Bool
    getter? committed = false
    getter? strict : Bool
    getter instance_description = ""

    @importer : Importer

    def initialize(@dataset : Source::Dataset, as_of : Time? = nil, @dry_run : Bool = false,
                   fiscal_start_month : Int32? = nil, @source_details = [] of {String, String},
                   @strict : Bool = false, @actor : Partiduo::Api::Actor = Partiduo::Api::Actor.system)
      @as_of = as_of || @dataset.closing_date || @dataset.last_date || Partiduo::Api::Core.today
      @started_at = Time.utc
      @importer = Importer.new(@dataset, @actor, fiscal_start_month)
      @preconditions = [] of Importer::Problem
    end

    def mapping : Mapping
      @importer.mapping
    end

    def problems : Array(Importer::Problem)
      @preconditions + @importer.problems
    end

    def notes : Array(String)
      @importer.notes
    end

    def counts : Hash(String, Int32)
      @importer.counts
    end

    # Reprise réussie : aucune anomalie bloquante (ni d'avertissement en
    # mode strict) et aucun écart.
    def success? : Bool
      return false if problems.any? { |problem| problem.blocking || @strict }
      comparison.try(&.ok?) || false
    end

    def failure_reason : String
      reasons = [] of String
      blocking = problems.count { |problem| problem.blocking || @strict }
      reasons << PartiduoMigrate.t("migration.problems", total: blocking) if blocking > 0
      if comparison = @comparison
        reasons << PartiduoMigrate.t("migration.differences", total: comparison.failures.size) unless comparison.ok?
      else
        reasons << PartiduoMigrate.t("migration.not_reconciled")
      end
      reasons.join(", ")
    end

    def run : Bool
      @instance_description = describe_instance
      Importer.preconditions(@actor).each do |message|
        @preconditions << Importer::Problem.new("instance", "", message)
      end
      return false unless @preconditions.empty?

      result = Partiduo::Api::Transaction.run do
        @importer.run
        before = Reconciliation.before(@dataset, @importer.mapping, @as_of)
        after = Reconciliation.after(@as_of, @actor)
        @comparison = Reconciliation::Comparison.new(before, after, @as_of, Reconciliation.reading(@dataset))
        if success? && !@dry_run
          Partiduo::Api::Result(Nil).success(nil)
        else
          Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("migrate.rolled_back"))
        end
      end
      @committed = result.success?
      success?
    rescue ex
      # La transaction est déjà annulée (`Transaction.run` relance après
      # l'annulation) : l'exception devient une anomalie bloquante.
      @committed = false
      @preconditions << Importer::Problem.new("internal", ex.class.name,
        PartiduoMigrate.t("migration.exception", message: ex.message || ex.class.name))
      false
    end

    private def describe_instance : String
      database = Marten.settings.databases.first.name.to_s
      settings = Partiduo::Api::Core.settings(@actor)
      PartiduoMigrate.t("migration.instance", company: settings.company_name, domain: settings.domain,
        database: database, regime: settings.tax_regime)
    rescue Partiduo::Api::NotFound
      PartiduoMigrate.t("migration.instance_database", database: Marten.settings.databases.first.name.to_s)
    end
  end
end
