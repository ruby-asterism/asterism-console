# Files sent to the machines and received from them (T4, docs/files.md):
# one row per file, the record of who, when, what, to or from which node
# and how it ended. A new table; nothing else changes.
class CreateFileTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :file_transfers do |t|
      t.string :direction, null: false            # send / receive
      t.string :status, null: false
      t.references :user, foreign_key: { on_delete: :nullify } # who sent it (nil for a received file)
      t.string :node, null: false                 # the other end
      t.string :name, null: false                 # the file's name as sent
      t.string :placed_name                       # where the receiver put it (name(1) ...)
      t.bigint :size, null: false, default: 0
      t.string :sha256
      t.bigint :done_bytes, null: false, default: 0 # what the receiver holds (progress)
      t.boolean :overwrite, null: false, default: false
      t.boolean :sd, null: false, default: false
      t.string :stored                            # the upload waiting in the outbox (send)
      t.text :reason
      t.integer :piece
      t.integer :window
      t.float :took_ms
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :file_transfers, [ :direction, :status ]
  end
end
