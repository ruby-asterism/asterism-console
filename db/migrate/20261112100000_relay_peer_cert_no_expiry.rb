# Certificates without an end, chosen per client row (0.3.20): a row with
# cert_no_expiry has its certificates signed with notAfter 99991231235959Z
# (RFC 5280's "no well-defined expiration date") instead of cert_days.
# Off for every row: nothing changes until an admin ticks "No expiry".
class RelayPeerCertNoExpiry < ActiveRecord::Migration[8.1]
  def change
    add_column :relay_peers, :cert_no_expiry, :boolean, null: false, default: false
  end
end
