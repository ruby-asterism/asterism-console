# What the pages want the bridge to measure (topic rates): "*" for all ROS
# 2 topics, or one topic id; each until it runs out unless renewed.
class CreateRateLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :rate_leases do |t|
      t.string :key, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :rate_leases, :key, unique: true
  end
end
