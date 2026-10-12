# Joining the console (W4): there is no sign-up page. An admin makes an
# invitation, which is a link with a one-time token (only its SHA-256 is
# kept); whoever opens it before it expires chooses an email address and a
# password and becomes a user (an admin if the invitation says so). An
# invitation is used once.
require "digest"
require "securerandom"

class Invitation < ApplicationRecord
  TTL = 72.hours

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :user, optional: true

  attr_reader :token

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.issue!(by:, note: nil, admin: false, ttl: TTL)
    token = SecureRandom.urlsafe_base64(32)
    create!(created_by: by, note: note.to_s[0, 200].presence, admin: admin, token_digest: digest(token),
            expires_at: ttl.from_now).tap { _1.instance_variable_set(:@token, token) }
  end

  def self.find_open(token, at = Time.current)
    return nil unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9_-]{20,100}\z/)
    where(used_at: nil, revoked_at: nil).where("expires_at > ?", at).find_by(token_digest: digest(token))
  end

  def status(at = Time.current)
    return "used" if used_at
    return "revoked" if revoked_at
    return "expired" if expires_at <= at
    "open"
  end

  # Makes the user and closes the invitation, in one transaction (a second
  # use of the same link finds it closed).
  def accept!(email_address:, password:, password_confirmation:)
    transaction do
      lock!
      raise ActiveRecord::RecordNotFound, "the invitation is closed" unless status == "open"
      u = User.create!(email_address: email_address, password: password, password_confirmation: password_confirmation,
                       admin: admin)
      update!(user: u, used_at: Time.current)
      u
    end
  end

  def revoke!
    update!(revoked_at: Time.current) if status == "open"
  end
end
