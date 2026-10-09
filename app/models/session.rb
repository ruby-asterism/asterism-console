# A signed-in browser. The cookie holds the id (signed); a session older
# than LIFETIME is not taken any more (sign in again).
class Session < ApplicationRecord
  LIFETIME = 12.hours

  belongs_to :user

  def self.live(id)
    return nil if id.blank?
    find_by(id: id, created_at: LIFETIME.ago..)
  end
end
