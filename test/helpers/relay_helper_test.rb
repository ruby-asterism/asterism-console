require "test_helper"

# Times on the server's pages are in the console's time zone
# (CONSOLE_TIME_ZONE, config.time_zone), with the zone's name.
class RelayHelperTest < ActionView::TestCase
  include ApplicationHelper
  test "when_text and iso_when write the console's time zone" do
    t = Time.utc(2026, 10, 14, 12, 30)
    assert_equal "2026-10-14 12:30 UTC", when_text(t)
    Time.use_zone("Asia/Tokyo") do
      assert_equal "2026-10-14 21:30 JST", when_text(t)
      assert_equal "2026-10-14 21:30 JST", iso_when("2026-10-14T12:30:00.000Z")
      assert_equal "at 2026-10-14 21:30 JST", RelayApply.new(mode: "at", run_at: t).when_text
    end
    assert_equal "-", when_text(nil)
    assert_equal "not a time", iso_when("not a time")
  end

  test "the backups' warning in the console's time zone" do
    Dir.mktmpdir do |dir|
      ConsoleBackup::Status.record(dir, ok: false, error: "disk full", now: Time.utc(2026, 10, 14, 3, 0))
      old = ENV["ASTERISM_BACKUP_DIR"]
      ENV["ASTERISM_BACKUP_DIR"] = dir
      Time.use_zone("Asia/Tokyo") { assert_match(/failed \(2026-10-14 12:00 JST\): disk full/, backup_warning) }
      assert_match(/failed \(2026-10-14 03:00 UTC\)/, ConsoleBackup::Status.warning(dir))
    ensure
      ENV["ASTERISM_BACKUP_DIR"] = old
    end
  end
end
