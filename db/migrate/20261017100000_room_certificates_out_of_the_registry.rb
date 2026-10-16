# 0.3.1 (docs/rooms.md "Seats"): the rooms' certificates leave the relay
# registry. From 0.2.0 to 0.3.0 bin/asterism setup made a registry row,
# marked room_slot, for each room slot (room-01 ..) and, from 0.3.0, for
# each of its seats (room-01-s01 ..), with their ledger entries. The seats'
# certificates stay where they are, in the rooms' store (the rooms
# volume's certs/, Relay::RoomCerts), and the ACL takes them from there;
# the slots' own certificates are not used any more (setup removes their
# files). This removes the rows, their certificates' ledger entries and
# their roles (setup gives a room row none), and the column.
class RoomCertificatesOutOfTheRegistry < ActiveRecord::Migration[8.1]
  ROWS = "SELECT id FROM relay_peers WHERE room_slot".freeze

  def up
    n = select_value("SELECT COUNT(*) FROM relay_peers WHERE room_slot").to_i
    suppress_messages do
      execute("DELETE FROM relay_certificates WHERE relay_peer_id IN (#{ROWS})")
      execute("DELETE FROM relay_peer_roles WHERE relay_peer_id IN (#{ROWS})")
      execute("DELETE FROM relay_peers WHERE room_slot")
    end
    say "removed #{n} room row(s) (the room slots' and seats' certificates) from the relay registry"
    remove_column :relay_peers, :room_slot
  end

  def down
    add_column :relay_peers, :room_slot, :boolean, null: false, default: false
  end
end
