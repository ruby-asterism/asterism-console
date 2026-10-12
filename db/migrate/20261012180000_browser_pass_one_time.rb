# G1: a browser pass opens one connection. The first successful check
# consumes it (used_at); later checks with it are refused.
class BrowserPassOneTime < ActiveRecord::Migration[8.1]
  def change
    add_column :browser_passes, :used_at, :datetime
  end
end
