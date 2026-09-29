# SPDX-License-Identifier: AGPL-3.0-or-later

# Outil de reprise d'un dossier dans une instance Partiduo neuve
# (ADR-001 D5). Le cœur n'est vu qu'à travers son contrat `Partiduo::Api`.
require "digest/sha256"
require "partiduo"

require "./partiduo_migrate/version"
require "./partiduo_migrate/i18n"
require "./partiduo_migrate/source"
require "./partiduo_migrate/fec/format"
require "./partiduo_migrate/fec/encoding"
require "./partiduo_migrate/fec/reader"
require "./partiduo_migrate/fec/writer"
require "./partiduo_migrate/legacy/database"
require "./partiduo_migrate/complement"
require "./partiduo_migrate/mapping"
require "./partiduo_migrate/importer"
require "./partiduo_migrate/importer_extras"
require "./partiduo_migrate/reconciliation"
require "./partiduo_migrate/migration"
require "./partiduo_migrate/report"
require "./partiduo_migrate/cli"
