# G1.5b: a browser page's node ID is wasm-<handle>, a short name the user
# chooses on the account page, not a part of the email address (every node
# on the network sees node IDs). Existing users start without one and choose
# it the next time they open the browser build: nothing made from an email
# address is kept.
#
# released_handles: a handle given up (changed, or its user removed) stays
# reserved for its last owner for a while (User::HANDLE_HOLD), so nobody
# else can take a name that the network (and its records) still know as
# someone's.
class UserHandles < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :handle, :string
    add_index :users, :handle, unique: true
    create_table :released_handles do |t|
      t.string :handle, null: false
      t.integer :user_id
      t.datetime :released_at, null: false
      t.timestamps
    end
    add_index :released_handles, :handle
  end
end
