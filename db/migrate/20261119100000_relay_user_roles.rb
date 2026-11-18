# Roles for a user's browser (0.4.2): the roles an admin picks for one
# user, which the router gives only to the page the door connects with
# that user's certificate (wasm-<handle>, Relay::BrowserCerts). A new table
# only: no role, row or user changes, and a console without picks makes
# the same configuration as before.
class RelayUserRoles < ActiveRecord::Migration[8.1]
  def change
    # No ON DELETE CASCADE, as relay_peer_roles (20261013100000): the models
    # delete the links themselves.
    create_table :relay_user_roles do |t|
      t.references :user, null: false, foreign_key: true
      t.references :relay_role, null: false, foreign_key: true
      t.timestamps
    end
    add_index :relay_user_roles, %i[user_id relay_role_id], unique: true
  end
end
