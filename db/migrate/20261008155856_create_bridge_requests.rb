class CreateBridgeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :bridge_requests do |t|
      t.string :kind
      t.string :path
      t.string :method_name
      t.text :args
      t.text :kwargs
      t.float :timeout_s, null: false, default: 2.0
      t.string :status, null: false, default: "pending"
      t.text :result
      t.string :error_class
      t.text :error_message
      t.float :took_ms
      t.datetime :finished_at

      t.timestamps
    end
    add_index :bridge_requests, :status
  end
end
