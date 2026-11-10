# Whom a user's browser receives files from (T8, docs/files.md "Browsers"):
# the same lists as a member row's (0.3.16, ReceiverLists), for the page
# that comes through the door with the user's certificate (wasm-<handle>,
# Relay::BrowserCerts). Nothing is filled in: a browser receives from
# nobody through the console until an admin chooses.
class UserBrowserReceivers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :receive_files_from, :text
    add_column :users, :receive_checkpoints_from, :text
    add_column :users, :receivers_changed_at, :datetime
    add_column :users, :receivers_delivered, :text
  end
end
