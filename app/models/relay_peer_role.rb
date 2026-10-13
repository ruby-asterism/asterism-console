# A row of the relay registry has a role (G1.5).
class RelayPeerRole < ApplicationRecord
  belongs_to :relay_peer
  belongs_to :relay_role

  validates :relay_role_id, uniqueness: { scope: :relay_peer_id }
end
