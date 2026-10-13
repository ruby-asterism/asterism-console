# G1.5b: an apply can wait (when nobody is connected, or until a time)
# before it writes the configuration and restarts the cloud router, and a
# waiting apply can be cancelled. started_at is when it began to run (the
# "already running" guard looks at it: a waiting apply may be hours old).
class RelayApplyWaiting < ActiveRecord::Migration[8.1]
  def up
    add_column :relay_applies, :mode, :string, null: false, default: "now"
    add_column :relay_applies, :run_at, :datetime
    add_column :relay_applies, :started_at, :datetime
    add_column :relay_applies, :cancelled_at, :datetime
    add_column :relay_applies, :cancelled_by_id, :integer
    execute "UPDATE relay_applies SET started_at = created_at"
    add_index :relay_applies, :status
  end

  def down
    execute "DELETE FROM relay_applies WHERE status IN ('waiting', 'cancelled')"
    remove_index :relay_applies, :status
    remove_column :relay_applies, :cancelled_by_id
    remove_column :relay_applies, :cancelled_at
    remove_column :relay_applies, :started_at
    remove_column :relay_applies, :run_at
    remove_column :relay_applies, :mode
  end
end
