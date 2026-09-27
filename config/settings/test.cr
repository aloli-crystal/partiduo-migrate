# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :test do |config|
  # Base de test propre à chaque agent ou job : DATABASE_URL (le nom doit
  # contenir « test »), vidée et reconstruite par les migrations du cœur.
  config.database do |db|
    db.from_url(Partiduo::Config.database_url)
  end
  config.media_files.root = File.join(Dir.tempdir, "partiduo-migrate-media-#{Process.pid}")
  config.cache_store = Marten::Cache::Store::Null.new
end
