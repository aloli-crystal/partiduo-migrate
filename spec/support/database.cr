# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module SpecSupport
    # Reconstruit le schéma de la base de test *par les migrations du cœur*
    # (comme partiduo-app, DECISIONS D-009) : contraintes et déclencheurs
    # d'intégrité présents pendant la reprise.
    def self.migrate_fresh! : Nil
      connection = Marten::DB::Connection.default
      name = Marten.settings.databases.first.name.to_s
      unless name.includes?("test")
        raise "Base de test refusée : « #{name} » ne contient pas « test » (voir DATABASE_URL)."
      end

      connection.open do |db|
        db.exec("DROP SCHEMA public CASCADE")
        db.exec("CREATE SCHEMA public")
      end
      Marten::DB::Management::Migrations::Runner.new(connection).execute
      Partiduo::Modules::State.reset_table_cache
    end
  end
end

Spec.before_suite { PartiduoMigrate::SpecSupport.migrate_fresh! }
