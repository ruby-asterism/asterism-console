class CreateGraphStates < ActiveRecord::Migration[8.1]
  def change
    create_table :graph_states do |t|
      t.integer :version, null: false, default: 0
      t.text :snapshot
      t.datetime :bridge_seen_at
      t.text :bridge_info

      t.timestamps
    end
  end
end
