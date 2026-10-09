class CreateCallPermissions < ActiveRecord::Migration[8.1]
  def change
    # One allowed combination of <node>/<app>/<object> and method, each a
    # pattern where * matches any run of characters. No rows: nothing can
    # be called.
    create_table :call_permissions do |t|
      t.string :node, null: false
      t.string :app, null: false
      t.string :object, null: false
      t.string :method_name, null: false
      t.string :note
      t.references :created_by, foreign_key: { to_table: :users }

      t.timestamps
    end
  end
end
