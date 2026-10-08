class CreateWatches < ActiveRecord::Migration[8.1]
  def change
    create_table :watches do |t|
      t.string :key, null: false
      t.string :error

      t.timestamps
    end
    add_index :watches, :key, unique: true
  end
end
