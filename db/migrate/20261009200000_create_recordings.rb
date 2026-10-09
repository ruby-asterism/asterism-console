# V4: recordings (MCAP files under storage/recordings) and playbacks to the
# network. A recording row is also the bridge's lease on what it records:
# the bridge subscribes while the row is "recording" and closes the file
# when it is stopped or reaches a limit. Uploaded files are rows too
# (source "uploaded"). A playback row is a request to republish a
# recording on the network; the rows are its audit log.
class CreateRecordings < ActiveRecord::Migration[8.1]
  def change
    create_table :recordings do |t|
      t.references :user, foreign_key: true
      t.string :name, null: false
      t.string :source, null: false, default: "recorded"
      t.string :status, null: false, default: "pending"
      t.string :filename, null: false
      t.text :selection
      t.bigint :max_bytes, null: false
      t.integer :max_seconds, null: false
      t.bigint :messages, null: false, default: 0
      t.bigint :bytes, null: false, default: 0
      t.bigint :lost, null: false, default: 0
      t.float :duration_s, null: false, default: 0
      t.text :channel_counts
      t.string :stop_reason
      t.text :error
      t.text :info
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :recordings, :status
    add_index :recordings, :filename, unique: true

    create_table :playbacks do |t|
      t.references :user, foreign_key: true
      t.references :recording, foreign_key: { on_delete: :nullify }
      t.string :recording_name
      t.float :speed, null: false, default: 1.0
      t.string :status, null: false, default: "pending"
      t.text :channels
      t.bigint :start_ns
      t.bigint :messages_sent, null: false, default: 0
      t.text :skipped
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :playbacks, :status
  end
end
