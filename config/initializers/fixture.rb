# Fixture mode (development only): the page shows a recorded network
# (Bridge::Fixture, test/fixtures/files/busy_network.json for "1") from its
# own database (config/database.yml), and the bridge does not run.
#
#   CONSOLE_FIXTURE=1 bin/rails server
fixture = ENV["CONSOLE_FIXTURE"].to_s
Rails.application.config.x.console_fixture =
  if Rails.env.development? && !fixture.empty? && fixture != "0"
    Rails.root.join(fixture == "1" ? "test/fixtures/files/busy_network.json" : fixture).to_s
  end
if (file = Rails.application.config.x.console_fixture)
  Rails.application.config.after_initialize do
    Rails.logger.warn("console: fixture mode, showing #{file} (no bridge)")
  end
end
