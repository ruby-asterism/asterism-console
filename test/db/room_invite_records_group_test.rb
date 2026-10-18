require "test_helper"
require Rails.root.join("db/migrate/20261018180000_room_invite_records_group").to_s

# The invite links made before 0.3.8 get a group of their own when the
# migration runs.
class RoomInviteRecordsGroupTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    RoomInvite.delete_all
    RoomInvite.reset_column_information
  end

  test "the invite links made before get a group each" do
    m = RoomInviteRecordsGroup.new
    m.verbose = false
    m.migrate(:down)
    RoomInvite.reset_column_information
    c = ActiveRecord::Base.connection
    2.times do |i|
      c.execute("INSERT INTO room_invites (name, token_digest, expires_at, max_rooms, apps, created_at, updated_at) " \
                "VALUES ('old #{i}', '#{'%064x' % i}', '2030-01-01', 1, '[]', '2026-10-18', '2026-10-18')")
    end
    m.migrate(:up)
    RoomInvite.reset_column_information
    groups = RoomInvite.pluck(:records_group)
    assert_equal 2, groups.compact.size
    assert(groups.all? { _1.match?(RoomInvite::GROUP) })
    assert_equal 2, groups.uniq.size
  end
end
