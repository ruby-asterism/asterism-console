# A running console server holds the storage directory's lock shared for its
# lifetime, so `bin/asterism restore` refuses to replace the databases under
# it (lib/console_backup.rb). Only the server: a one-off command (setup, a
# backup, the tests) does not take it.
if defined?(Rails::Server)
  Rails.application.config.after_initialize do
    ConsoleBackup::Lock.hold_shared(ENV["ASTERISM_STORAGE_DIR"].presence || Rails.root.join("storage").to_s)
  end
end
