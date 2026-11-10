# A browser that need not type the TOTP code again for LIFETIME (T8c): the
# user ticks "Remember this browser for 30 days" on the code page. The
# browser keeps a signed cookie (COOKIE: httponly, secure, same_site lax)
# with a random value; only its SHA-256 is kept here, with the user, when it
# was made and the browser's user agent (for the account page).
#
# On the next sign-in the password is still asked, every time and as before
# (sessions last Session::LIFETIME); a good password and a cookie that
# matches a row of the same user, not expired, skip the code. The account page
# lists the rows and forgets one or all; a new password, and turning TOTP
# on, off or to a new secret forget them all (User). Nothing else changes:
# an admin who must have TOTP still has it on, and a browser without the
# cookie is asked for the code.
require "digest"
require "securerandom"

class RememberedBrowser < ApplicationRecord
  LIFETIME = 30.days
  COOKIE = :remembered_browser

  belongs_to :user

  scope :live, ->(at = Time.current) { where("expires_at > ?", at) }

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # A new row for user; returns [row, token] (the token goes into the
  # cookie and is not kept).
  def self.remember!(user, user_agent:, ip:, at: Time.current)
    token = SecureRandom.urlsafe_base64(32)
    user.remembered_browsers.where(expires_at: ..at).delete_all
    row = user.remembered_browsers.create!(token_digest: digest(token), user_agent: user_agent.to_s[0, 255],
                                           created_ip: ip.to_s[0, 64], expires_at: at + LIFETIME)
    [ row, token ]
  end

  # The live row of user that token (the cookie's value) names, or nil.
  def self.find_for(user, token, at = Time.current)
    return nil unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9_-]{20,100}\z/)
    user.remembered_browsers.live(at).find_by(token_digest: digest(token))
  end
end
