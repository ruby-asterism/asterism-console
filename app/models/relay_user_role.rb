# A user's browser has a role (0.4.2): given to the page the door connects
# with the user's certificate only (Relay::CloudConfig, "browser_certs"),
# never to the shared ws/ subject.
class RelayUserRole < ApplicationRecord
  belongs_to :user
  belongs_to :relay_role

  validates :relay_role_id, uniqueness: { scope: :user_id }
end
