# What the open plot and log pages want from the bridge (V3): for a plot,
# a topic (or an Asterism key) and the fields drawn from it; for the log
# list, "*" (/rosout and the Asterism log keys). One row per page and
# target, each until it runs out unless the page renews it. The bridge
# writes what it knows of the target (its type and fields) into meta.
class CreateStreamLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :stream_leases do |t|
      t.string :kind, null: false
      t.string :page, null: false
      t.string :target, null: false
      t.text :fields
      t.text :meta
      t.references :user, foreign_key: true
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :stream_leases, %i[kind page target], unique: true
    add_index :stream_leases, %i[kind target]
  end
end
