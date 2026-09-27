# SPDX-License-Identifier: AGPL-3.0-or-later

# Réglages de l'outil : ceux du cœur (base de l'instance par `DATABASE_URL`,
# langues, pièces jointes par `PARTIDUO_MEDIA_ROOT`), sans serveur HTTP.
Marten.configure do |config|
  config.secret_key = ENV["MARTEN_SECRET_KEY"]? || "__partiduo_migrate_cli_only__"
  Partiduo.apply_settings(config)
  config.middleware = [] of Marten::Middleware.class
  config.log_level = ::Log::Severity::Warn
end
