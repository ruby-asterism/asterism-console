require "test_helper"
require Rails.root.join("db/migrate/20261109150000_member_receivers").to_s

# 0.3.16 (db/migrate/*_member_receivers.rb, T6): the rows get their senders'
# lists, empty: nothing is sent to a machine until an admin chooses, and the
# rows keep what they had.
class MemberReceiversMigrationTest < ActiveSupport::TestCase
  COLUMNS = %i[receive_files_from receive_checkpoints_from receivers_changed_at receivers_delivered].freeze

  def migrate(direction)
    old = $stdout
    $stdout = StringIO.new
    MemberReceivers.new.migrate(direction)
  ensure
    $stdout = old
    RelayPeer.reset_column_information
  end

  teardown { RelayPeer.reset_column_information }

  test "down and up: the rows stay, their lists start empty and unmanaged" do
    RelayPeer.delete_all
    migrate(:down)
    c = ActiveRecord::Base.connection
    COLUMNS.each { refute c.column_exists?(:relay_peers, _1) }
    c.execute("INSERT INTO relay_peers (name, kind, cert_days, files_from_console, created_at, updated_at) " \
              "VALUES ('fmruby-aaaaaa', 'client', 90, 1, '2026-11-09', '2026-11-09')")
    migrate(:up)
    COLUMNS.each { assert c.column_exists?(:relay_peers, _1) }
    p = RelayPeer.find_by!(name: "fmruby-aaaaaa")
    assert p.files_from_console?
    assert_equal [ [], [], false ], [ p.receivers("file"), p.receivers("checkpoint"), p.managed_receivers? ]
    assert_empty RelayPeer.managed
  end
end
