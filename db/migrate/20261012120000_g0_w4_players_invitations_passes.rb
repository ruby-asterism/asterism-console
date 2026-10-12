# G0 / W4: players in the relay registry (the game's keys), invitations
# (no sign-up page), and short-lived passes for the browser build's wss://.
class G0W4PlayersInvitationsPasses < ActiveRecord::Migration[8.1]
  def change
    # A player gets the game rules of the ACL (Relay::CloudConfig): it may
    # write only at the nodes it speaks for (its own name when empty; a
    # home router lists the boards behind it).
    add_column :relay_peers, :player, :boolean, default: false, null: false
    add_column :relay_peers, :player_nodes, :text

    create_table :invitations do |t|
      t.string :token_digest, null: false
      t.string :note
      t.boolean :admin, default: false, null: false
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :user, foreign_key: true
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :invitations, :token_digest, unique: true

    create_table :browser_passes do |t|
      t.string :token_digest, null: false
      t.references :user, null: false, foreign_key: true
      t.string :created_ip
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.datetime :last_used_at
      t.string :last_used_ip
      t.integer :uses, default: 0, null: false
      t.integer :refused, default: 0, null: false
      t.timestamps
    end
    add_index :browser_passes, :token_digest, unique: true
    add_index :browser_passes, :expires_at
  end
end
