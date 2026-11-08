# An open Terminal page (docs/terminal.md): a random token per page, renewed
# while the page is open (TerminalsController#lease, every 10 s; it lasts
# LIFETIME). The page's output stream is for its user only
# (ConsoleChannel, stream "terminal"), and the bridge stops the commands
# of a page whose row is gone (released on pagehide) or ran out.
class TerminalSession < ApplicationRecord
  LIFETIME = 30.seconds
  PAGE = /\A[A-Za-z0-9_-]{16,64}\z/

  belongs_to :user

  validates :page, format: { with: PAGE }

  scope :live, -> { where(expires_at: Time.current..) }

  # Opens or renews the page's row for user. nil when the token is another
  # user's (or not a token).
  def self.renew(page:, user:)
    return nil unless PAGE.match?(page.to_s)
    row = find_or_initialize_by(page: page.to_s)
    return nil if row.persisted? && row.user_id != user.id
    row.user = user
    row.expires_at = LIFETIME.from_now
    row.save!
    row
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def self.release(page:, user:)
    where(page: page.to_s, user: user).delete_all
  end

  # The pages open now (their tokens), the expired rows removed.
  def self.live_pages
    where(expires_at: ...Time.current).delete_all
    live.pluck(:page)
  end

  def self.owned?(page, user)
    live.exists?(page: page.to_s, user: user)
  end
end
