class CreateNodeIcons < ActiveRecord::Migration[8.1]
  def change
    # The icons of the nodes' profiles (V2.5), by their icon_hash: written
    # by the bridge, served by IconsController, shared by every node with
    # the same icon and by the recordings' rewind.
    create_table :node_icons do |t|
      t.string :icon_hash, null: false
      t.binary :png, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.timestamps
    end
    add_index :node_icons, :icon_hash, unique: true
  end
end
