# A handle that its owner gave up (changed it, or was removed): reserved for
# that owner for User::HANDLE_HOLD, so that nobody else takes, at once, a
# name the network and its records still know as someone's. The owner can
# take it back at any time.
class ReleasedHandle < ApplicationRecord
  def self.release!(handle, user_id, at = Time.current)
    return if handle.blank?
    create!(handle: handle, user_id: user_id, released_at: at)
  end

  # Whether someone other than user_id gave up handle within the hold.
  def self.held_for_another?(handle, user_id, at = Time.current)
    where(handle: handle).where(released_at: (at - User::HANDLE_HOLD)..).where.not(user_id: user_id).exists?
  end
end
