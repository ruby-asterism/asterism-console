# G1.5b: a pass belongs to the one page that used it first, while it is
# open (until open_until, the door's lifetime from the first connection).
# The page names itself with a random key of its own on every connection;
# only the key's SHA-256 is kept (page_digest), so the same page can
# connect again after the router restarts and another page cannot.
class BrowserPassPage < ActiveRecord::Migration[8.1]
  def change
    add_column :browser_passes, :page_digest, :string
    add_column :browser_passes, :open_until, :datetime
  end
end
