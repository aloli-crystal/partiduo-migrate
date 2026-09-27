# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée de `bin/partiduo-migrate` : réglages de l'instance lus dans
# l'environnement (`DATABASE_URL`, `PARTIDUO_MODULES`, `PARTIDUO_MEDIA_ROOT`).
require "./partiduo-migrate"
require "../config/settings/base"
require "../config/settings/**"

Marten.setup
exit PartiduoMigrate::CLI.new.run(ARGV)
