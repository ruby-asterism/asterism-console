# G1.5: roles in the relay registry. A role is a name and key templates
# (Relay::CloudConfig expands ${node} with the nodes a row speaks for); a
# row picks any number of roles. Replaces the G0 "player" flag and the one
# game app of ASTERISM_RELAY_GAME: the rows that were players get the role
# "match", seeded here with the same keys (plus calls only under the
# caller's own name). The browsers (the ws/ subject) had the game rules
# whenever the console let them in; "match" is given to them.
class RelayRoles < ActiveRecord::Migration[8.1]
  # The seeded example, for the app the G0 players used.
  def self.match_role(app)
    {
      name: "match",
      description: "Play a game against others: write at your own nodes' #{app} app, read every node's, " \
                   "call others only under your own name.",
      rw_templates: [ "asterism/${node}", "asterism/${node}/#{app}/**", "asterism/${node}/@profile" ].join("\n"),
      read_templates: [ "asterism/*", "asterism/*/#{app}/**", "asterism/*/@profile" ].join("\n"),
      ask_templates: [ "asterism/*/@profile", "asterism/*/#{app}/*/meta", "asterism/*/#{app}/*/call/${node}" ].join("\n"),
      watch_templates: "asterism/**",
      browser_app: nil,
      for_browsers: true
    }
  end

  class Peer < ActiveRecord::Base
    self.table_name = "relay_peers"
  end

  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  class PeerRole < ActiveRecord::Base
    self.table_name = "relay_peer_roles"
  end

  def up
    players = select_values("SELECT id FROM relay_peers WHERE player = 1 OR player = 't'").map(&:to_i)
    create_table :relay_roles do |t|
      t.string :name, null: false
      t.string :description
      t.text :rw_templates
      t.text :read_templates
      t.text :ask_templates
      t.text :watch_templates
      # What a browser page opened from the console starts with (optional).
      t.string :browser_app
      # The browsers (the ws/ subject, nodes <prefix>$*) have this role.
      t.boolean :for_browsers, default: false, null: false
      t.timestamps
    end
    add_index :relay_roles, :name, unique: true

    create_table :relay_peer_roles do |t|
      # No ON DELETE CASCADE: SQLite drops a column of relay_peers by copying
      # the table, and a cascade would silently take every link with it
      # (seen: a later remove_column emptied this table). Without it the
      # links survive the copy; the models delete them themselves.
      t.references :relay_peer, null: false, foreign_key: true
      t.references :relay_role, null: false, foreign_key: true
      t.timestamps
    end
    add_index :relay_peer_roles, %i[relay_peer_id relay_role_id], unique: true

    rename_column :relay_peers, :player_nodes, :nodes
    Role.reset_column_information
    Peer.reset_column_information

    app = ENV["ASTERISM_RELAY_GAME"].presence || "game"
    app = "game" unless app.match?(/\A[A-Za-z0-9_.-]{1,64}\z/)
    role = Role.create!(self.class.match_role(app))
    # The column goes before the rows are linked: SQLite drops a column by
    # copying the table, which would take the new links with it.
    remove_column :relay_peers, :player
    players.each { PeerRole.create!(relay_peer_id: _1, relay_role_id: role.id) }
  end

  def down
    role = Role.find_by(name: "match")
    players = role ? PeerRole.where(relay_role_id: role.id).pluck(:relay_peer_id) : []
    add_column :relay_peers, :player, :boolean, default: false, null: false
    Peer.reset_column_information
    Peer.where(id: players).update_all(player: true)
    rename_column :relay_peers, :nodes, :player_nodes
    drop_table :relay_peer_roles
    drop_table :relay_roles
  end
end
