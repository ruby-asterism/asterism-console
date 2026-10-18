# The group of an invite link (0.3.8, docs/rooms.md "Invite links"): a
# random string of its own, not secret and unrelated to the link's secret,
# that rooms.json gives each room made through the link ("group"). A game
# host keeps it with the rooms' game records, so the rooms of one invite
# link see each other's records. The invite links made before get one too.
require "securerandom"

class RoomInviteRecordsGroup < ActiveRecord::Migration[8.1]
  def up
    add_column :room_invites, :records_group, :string
    select_values("SELECT id FROM room_invites").each do |id|
      execute("UPDATE room_invites SET records_group = #{quote(SecureRandom.hex(16))} WHERE id = #{Integer(id)}")
    end
    change_column_null :room_invites, :records_group, false
    add_index :room_invites, :records_group, unique: true
  end

  def down
    remove_index :room_invites, :records_group
    remove_column :room_invites, :records_group
  end
end
