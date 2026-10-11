class CreateMachineNames < ActiveRecord::Migration[8.1]
  def change
    create_table :machine_names do |t|
      t.string :name, null: false
      # The ROS 2 node names of the group it was given to (JSON array).
      t.text :members, null: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }, null: true
      t.timestamps
    end
  end
end
