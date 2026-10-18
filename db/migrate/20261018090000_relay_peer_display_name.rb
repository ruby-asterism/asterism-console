# A display name an admin gives a member (CM1, 0.3.5): "Tab5" for the row
# fmruby-aaaaaa. Optional; the existing rows keep none and look as before.
# The name (the certificate's common name, the ACL's subject) is unchanged.
class RelayPeerDisplayName < ActiveRecord::Migration[8.1]
  def change
    add_column :relay_peers, :display_name, :string
  end
end
