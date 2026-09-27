# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module SpecSupport
    ROOT     = File.expand_path("../..", __DIR__)
    DEMO_FEC = File.join(ROOT, "demo", "732829320FEC20241231.txt")

    # Provisionne l'instance de test (régime français), comme
    # `bin/partiduo-provision` : société, plan comptable, journaux, taux.
    def self.provision! : Nil
      settings = Partiduo::Api::Core::SettingsInput.new(
        company_name: "Atelier Démo SARL", legal_form: "SARL", siren: "732 829 320",
        vat_number: "FR 44 732829320", street: "rue des Lilas", street_number: "12", postcode: "44000",
        city: "Nantes", tax_regime: "fr", domain: "demo.partiduo.localhost",
      )
      input = Partiduo::Api::Core::ProvisionInput.new(settings: settings)
      Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, input).value!
    end

    # Base NOALYSS de démonstration (DBVERSION 208), créée par
    # `scripts/noalyss-demo` si elle n'existe pas. `NOALYSS_DEMO_URL` : URL
    # complète (CI, PostgreSQL en TCP) ; sinon socket Unix `/tmp`.
    def self.noalyss_url : String
      name = ENV["NOALYSS_DEMO_DB"]? || "partiduo_noalyss_demo"
      url = ENV["NOALYSS_DEMO_URL"]?.presence || "postgres:///#{name}?host=/tmp"
      exists = begin
        DB.open(url) { |db| db.query_one("SELECT max(val) FROM version", as: Int32?) == Noalyss::DBVERSION }
      rescue
        false
      end
      unless exists
        status = Process.run(File.join(ROOT, "scripts", "noalyss-demo"), [name], output: Process::Redirect::Close,
          error: Process::Redirect::Inherit)
        raise "scripts/noalyss-demo #{name} en échec" unless status.success?
      end
      url
    end

    def self.report_dir : String
      File.join(Dir.tempdir, "partiduo-migrate-spec-#{Process.pid}-#{Random::Secure.hex(4)}")
    end
  end
end

def actor : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

def demo_dataset : PartiduoMigrate::Source::Dataset
  reader = PartiduoMigrate::Fec::Reader.new
  dataset = reader.read_file(PartiduoMigrate::SpecSupport::DEMO_FEC)
  reader.problems.should be_empty
  dataset
end

# Valeur attendue présente : la spec échoue sinon (au lieu de `not_nil!`).
class Object
  def present! : self
    self
  end
end

struct Nil
  def present! : NoReturn
    fail "valeur absente"
  end
end
