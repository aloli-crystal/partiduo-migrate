# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # Une reprise complète : contrôle de l'instance, écriture par le contrat
  # (`Importer`), réconciliation, décision. Le tout dans *une* transaction :
  # une reprise qui ne réconcilie pas au centime, ou qui laisse une
  # anomalie bloquante, est annulée et l'instance reste neuve (ADR-001 D5 :
  # « un échec, pas un avertissement »). En essai à blanc, elle est annulée
  # dans tous les cas.
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
      reasons << "#{blocking} anomalie(s) de reprise" if blocking > 0
      if comparison = @comparison
        reasons << "#{comparison.failures.size} ligne(s) en écart" unless comparison.ok?
      else
        reasons << "réconciliation non faite"
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
        @comparison = Reconciliation::Comparison.new(before, after, @as_of)
        if success? && !@dry_run
          Partiduo::Api::Result(Nil).success(nil)
        else
          Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("migrate.rolled_back"))
        end
      end
      @committed = result.success?
      success?
    end

    private def describe_instance : String
      database = Marten.settings.databases.first.name.to_s
      settings = Partiduo::Api::Core.settings(@actor)
      "#{settings.company_name} (#{settings.domain}, base #{database}, régime #{settings.tax_regime})"
    rescue Partiduo::Api::NotFound
      "base #{Marten.settings.databases.first.name}"
    end
  end
end
