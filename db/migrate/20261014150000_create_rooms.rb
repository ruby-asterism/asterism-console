# Rooms (G2, docs/rooms.md): a time-limited key space on the cloud router
# that anyone with the room's link may join through the door, without an
# account. A room takes one of the room slots (room-01 .. room-NN, whose
# certificates and ACL are made once, Relay::RoomSlots); relay_peers marks
# those slots' rows.
class CreateRooms < ActiveRecord::Migration[8.1]
  def change
    create_table :rooms do |t|
      t.string :uid, null: false            # the "room" claim of its keys (16 hex)
      t.string :name, null: false
      t.string :app                         # what the link opens ("" / nil: the page's own start)
      t.string :slot, null: false           # "01" .. : its key space is room/<slot>/**
      t.integer :max_connections, null: false
      t.datetime :expires_at, null: false
      t.datetime :closed_at                 # closed early (deleted): its keys are refused, its connections cut
      t.string :close_reason
      t.integer :links_made, null: false, default: 0
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :closed_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :rooms, :uid, unique: true
    add_index :rooms, %i[slot expires_at]
    add_column :relay_peers, :room_slot, :boolean, null: false, default: false
  end
end
