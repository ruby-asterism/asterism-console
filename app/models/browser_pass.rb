# A short-lived pass for the browser build's wss:// connection to the
# router (W4). A signed-in user makes one; the proxy in front of the
# router's ws/ listener asks the console (BrowserPassesController#check,
# nginx auth_request) whether it may open each WebSocket. Only the
# SHA-256 of the pass is kept; the pass itself is shown once.
#
# A pass opens ONE connection (G1): the first successful check consumes it
# (used_at), and every later check with it is refused, also before it
# expires. A connection that is open stays open when the pass expires or is
# revoked (the check is made when a connection opens; the router has no way
# to ask later); the router door closes it after a few hours at most
# (deploy/vps: the door relay), and the browser needs a fresh pass then.
require "digest"
require "securerandom"

class BrowserPass < ApplicationRecord
  TTL = ENV.fetch("ASTERISM_PASS_TTL", 600).to_i.seconds
  # Open passes per user at a time (older ones are revoked).
  PER_USER = 3

  belongs_to :user
  belongs_to :revoked_by, class_name: "User", optional: true

  attr_reader :token

  scope :live, ->(at = Time.current) { where(revoked_at: nil, used_at: nil).where("expires_at > ?", at) }

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

  # The live pass for token, or nil. A blank or malformed token is nil.
  def self.find_live(token, at = Time.current)
    return nil unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9_-]{20,100}\z/)
    live(at).find_by(token_digest: digest(token))
  end

  def live?(at = Time.current)
    revoked_at.nil? && used_at.nil? && expires_at > at
  end

  def status(at = Time.current)
    return "revoked" if revoked_at
    return "used" if used_at
    return "expired" if expires_at <= at
    "live"
  end

  # Consumes the pass for one connection. True when this call took it: one
  # UPDATE that only matches a live, unused row, so two checks racing for
  # the same pass cannot both win.
  def consume!(ip, at = Time.current)
    n = self.class.live(at).where(id: id)
            .update_all([ "used_at = ?, uses = uses + 1, last_used_at = ?, last_used_ip = ?", at, at, ip.to_s[0, 64] ])
    n == 1
  end

  def revoke!(by)
    update!(revoked_at: Time.current, revoked_by: by) unless revoked_at
  end
end
