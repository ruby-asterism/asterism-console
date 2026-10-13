# G1.5: a pass made by "Open the browser build" names the node the page
# joins as (Relay::BrowserNode) and the app it opens, so that a second page
# of the same user gets another name and the admin's list says whose node
# is whose.
class BrowserPassNode < ActiveRecord::Migration[8.1]
  def change
    add_column :browser_passes, :node, :string
    add_column :browser_passes, :app, :string
  end
end
