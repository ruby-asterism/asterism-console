# An open Terminal page (docs/terminal.md): a random token per page, renewed
# while the page is open (TerminalsController#lease, every 10 s; it lasts
# LIFETIME). The page's output stream is for its user only
# (ConsoleChannel, stream "terminal"), and the bridge stops the commands
# of a page whose row is gone (released on pagehide) or ran out.
#
# remote: the machine the page is in (the remote shell, docs/terminal.md),
# as JSON {"node", "commands" => {name => "read" | "write"}}: the bridge's
# copy for Rails, written by the bridge when the machine let the page in
# and cleared when it leaves (and when a bridge starts: what it held in
# memory, the machine's session number, is gone). The session number never
# leaves the bridge.
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

  # {"node", "commands"} of the machine the page is in, or nil.
  def remote_value
    v = remote.present? ? JSON.parse(remote) : nil
    v.is_a?(Hash) && v["node"].is_a?(String) ? v : nil
  rescue JSON::ParserError
    nil
  end

  def remote_node = remote_value&.dig("node")

  # Written by the bridge (nil: the page left the machine).
  def self.set_remote(page, value)
    where(page: page.to_s).update_all(remote: value && JSON.generate(value), updated_at: Time.current)
  end
end
