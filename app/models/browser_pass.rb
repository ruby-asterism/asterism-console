# A short-lived pass for the browser build's wss:// connection to the
# router (W4). A signed-in user makes one; the proxy in front of the
# router's ws/ listener asks the console (BrowserPassesController#check,
# nginx auth_request) whether it may open each WebSocket. Only the
# SHA-256 of the pass is kept; the pass itself is shown once.
#
# A pass belongs to ONE open page, while it is open (G1.5b):
# - The first successful check takes it (used_at): within TTL of being
#   made, unused and not revoked. From then on it is open until open_until
#   (LIFETIME after that first connection; the door closes a connection at
#   that time too).
# - The page names itself on every connection with a random key it made
#   when it was loaded (the "page" parameter next to the pass; only its
#   SHA-256 is kept, page_digest). While the pass is open, a check with the
#   same pass and the same key is let through again: the page connecting
#   again after the router restarted or the line dropped. Another page
#   (another key, or none) is refused, as before.
# - A page that sends no key (an older page) gets one connection, as before
#   G1.5b.
# A connection that is open stays open when the pass is revoked (the check
# is made when a connection opens; the router has no way to ask later); a
# revoked pass lets nothing connect again.
require "digest"
require "securerandom"

class BrowserPass < ApplicationRecord
  TTL = ENV.fetch("ASTERISM_PASS_TTL", 600).to_i.seconds
  # How long a pass stays open for its page after the first connection.
  # The door (bin/ws_door) closes connections at the same time, so keep it
  # equal to (or below) WS_DOOR_MAX_SECONDS.
  LIFETIME = ENV.fetch("ASTERISM_PASS_LIFETIME", 14_400).to_i.seconds
  # Open passes per user at a time (older ones are revoked).
  PER_USER = 3
  PAGE_KEY = /\A[A-Za-z0-9_-]{16,128}\z/

  belongs_to :user
  belongs_to :revoked_by, class_name: "User", optional: true

  attr_reader :token

  # Not used yet (waiting for its page's first connection).
  scope :live, ->(at = Time.current) { where(revoked_at: nil, used_at: nil).where("expires_at > ?", at) }
  # Taken by a page that may still connect again.
  scope :open_for_page, lambda { |at = Time.current|
    where(revoked_at: nil).where.not(used_at: nil).where.not(page_digest: nil).where("open_until > ?", at)
  }

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # Makes a pass for user; the pass (token) is readable once, on the
  # returned record.
  def self.issue!(user, ip: nil, ttl: TTL, node: nil, app: nil)
    token = SecureRandom.urlsafe_base64(32)
    transaction do
      live = user.browser_passes.live.order(:id).to_a
      live.first([ live.size - (PER_USER - 1), 0 ].max).each { _1.revoke!(user) }
      create!(user: user, token_digest: digest(token), created_ip: ip, expires_at: ttl.from_now,
              node: node, app: app.presence).tap do |p|
        p.instance_variable_set(:@token, token)
      end
    end
  end

  # The pass for token whatever its state, or nil. A blank or malformed
  # token is nil.
  def self.find_by_token(token)
    return nil unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9_-]{20,100}\z/)
    find_by(token_digest: digest(token))
  end

  # The live (unused) pass for token, or nil.
  def self.find_live(token, at = Time.current)
    pass = find_by_token(token)
    pass if pass&.live?(at)
  end

  # A page's key, or nil when it is not one.
  def self.page_key(key)
    key.is_a?(String) && key.match?(PAGE_KEY) ? key : nil
  end

  def live?(at = Time.current)
    revoked_at.nil? && used_at.nil? && expires_at > at
  end

  # Taken by a page and still open for it.
  def open?(at = Time.current)
    revoked_at.nil? && !used_at.nil? && !page_digest.nil? && !open_until.nil? && open_until > at
  end

  def status(at = Time.current)
    return "revoked" if revoked_at
    return (open?(at) ? "open" : "closed") if used_at && page_digest
    return "used" if used_at
    return "expired" if expires_at <= at
    "live"
  end

  # Whether it can still be revoked to some effect.
  def revocable?(at = Time.current)
    live?(at) || open?(at)
  end

  # Lets one connection in: the page's first (takes the pass for the page)
  # or the same page again (while open). True when let in. Each is one
  # UPDATE that only matches a row in the right state, so two checks racing
  # for the same pass cannot both take it.
  def admit!(ip, page = nil, at = Time.current)
    page = self.class.page_key(page)
    return true if consume!(ip, at, page: page)
    return false unless page
    n = self.class.open_for_page(at).where(id: id, page_digest: self.class.digest(page))
            .update_all([ "uses = uses + 1, last_used_at = ?, last_used_ip = ?", at, ip.to_s[0, 64] ])
    n == 1
  end

  # Takes the pass for its first connection (and for page, when the page
  # named itself). True when this call took it.
  def consume!(ip, at = Time.current, page: nil)
    sets = [ "used_at = ?, uses = uses + 1, last_used_at = ?, last_used_ip = ?", at, at, ip.to_s[0, 64] ]
    if page
      sets[0] += ", page_digest = ?, open_until = ?"
      sets.push(self.class.digest(page), at + LIFETIME)
    end
    n = self.class.live(at).where(id: id).update_all(sets)
    n == 1
  end

  def revoke!(by)
    update!(revoked_at: Time.current, revoked_by: by) unless revoked_at
  end
end
