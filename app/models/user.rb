# Someone who may sign in to the console. Admins also edit the call
# permissions (and, with W2b, the relay registry). Users are made with
# bin/rails console:user (lib/tasks/console.rake); there is no sign-up page.
#
# TOTP (a second factor) is optional per user: the user turns it on from
# the account page (the secret is shown once, to type into an authenticator
# app) and confirms it with a code. A code is accepted once (otp_last_step).
class User < ApplicationRecord
  OTP_ISSUER = "Asterism Console".freeze
  # Codes one step (30 s) old or ahead are still taken (clock drift).
  OTP_DRIFT = 30

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :bridge_requests, dependent: :nullify

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true,
                            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, allow_nil: true

  def otp_enabled?
    otp_enabled_at.present? && otp_secret.present?
  end

  # A fresh secret for turning TOTP on (not active until confirmed).
  def start_otp!
    update!(otp_secret: ROTP::Base32.random, otp_enabled_at: nil, otp_last_step: nil)
  end

  def otp_uri
    ROTP::TOTP.new(otp_secret, issuer: OTP_ISSUER).provisioning_uri(email_address)
  end

  # Checks a code; a code (its time step) is taken once.
  def verify_otp(code)
    return false if otp_secret.blank? || code.to_s !~ /\A\s*\d{6}\s*\z/
    totp = ROTP::TOTP.new(otp_secret, issuer: OTP_ISSUER)
    at = totp.verify(code.to_s.strip, drift_behind: OTP_DRIFT, drift_ahead: OTP_DRIFT,
                     after: otp_last_step && otp_last_step * totp.interval)
    return false unless at
    update!(otp_last_step: at / totp.interval)
    true
  end

  def confirm_otp!(code)
    return false unless verify_otp(code)
    update!(otp_enabled_at: Time.current)
  end

  def disable_otp!
    update!(otp_secret: nil, otp_enabled_at: nil, otp_last_step: nil)
  end
end
