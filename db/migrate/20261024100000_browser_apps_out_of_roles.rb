# 0.3.12: the apps "Launch Web Studio" may start get a list of their own
# (BrowserApp, Admin > Studio apps). Before, each role had one
# (relay_roles.browser_app, "Opens in a browser page"), which tied an app to
# a set of permissions; a role is permissions only now.
#
# The roles' apps are copied first (the ones not blank, each path once,
# labelled with the name of a role that names it: one marked for the
# browsers if there is one, else the first by name), then the column goes.
# The menus list them by label, so in the roles' name order as before. Rooms offer the same list after
# ASTERISM_ROOM_APPS, as before.
class BrowserAppsOutOfRoles < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  class App < ActiveRecord::Base
    self.table_name = "browser_apps"
  end

  def up
    create_table :browser_apps do |t|
      # Shown in the menus next to the path (optional).
      t.string :label
      # What the page starts (RelayRole::APP before, BrowserApp::PATH).
      t.string :path, null: false
      # Where it goes in the menus (optional: the ones without come last,
      # by label, the unlabelled by path).
      t.integer :position
      t.timestamps
    end
    add_index :browser_apps, :path, unique: true

    App.reset_column_information
    rows = select_rows("SELECT name, browser_app FROM relay_roles " \
                       "WHERE browser_app IS NOT NULL AND browser_app <> '' ORDER BY for_browsers DESC, name")
    rows.map { |name, path| [ name, path.strip ] }.reject { _2.empty? }.uniq { _2 }.each do |name, path|
      App.create!(label: name, path: path)
    end
    say "copied #{App.count} app(s) from the roles" unless App.count.zero?

    # SQLite drops a column by copying the table. relay_peer_roles points at
    # relay_roles without ON DELETE CASCADE (see *_relay_roles.rb), so the
    # links survive the copy.
    remove_column :relay_roles, :browser_app
  end

  # The column comes back; an app labelled with a role's name goes back to
  # that role (what up made). Others are lost with the table.
  def down
    add_column :relay_roles, :browser_app, :string
    Role.reset_column_information
    select_rows("SELECT label, path FROM browser_apps WHERE label IS NOT NULL ORDER BY id").each do |label, path|
      Role.where(name: label, browser_app: nil).update_all(browser_app: path)
    end
    drop_table :browser_apps
  end
end
