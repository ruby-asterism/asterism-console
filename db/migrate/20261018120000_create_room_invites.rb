# Invite links to make rooms (0.3.5, docs/rooms.md "Invite links"): an admin
# makes a link with an end, a limit of rooms open at once and the apps it may
# open; whoever opens it makes rooms on a page of its own, without an
# account. Only the SHA-256 of the link's secret is kept. A room made
# through one says so (rooms.room_invite_id).
class CreateRoomInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :room_invites do |t|
      t.string :name, null: false
      t.string :token_digest, null: false   # SHA-256 (hex) of the link's secret
      t.datetime :expires_at, null: false
      t.integer :max_rooms, null: false     # rooms open at once through this link
      t.text :apps, null: false             # JSON: the paths its rooms may open
      t.datetime :revoked_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :room_invites, :token_digest, unique: true
    add_reference :rooms, :room_invite, foreign_key: true
  end
end
