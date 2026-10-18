# Someone who may sign in to the console. Admins also edit the call
# permissions (and, with W2b, the relay registry). Users are made with
# bin/rails console:user (lib/tasks/console.rake); there is no sign-up page.
#
# The handle (G1.5b) is a short name the user chooses on the account page.
# A browser page the user opens from the console joins the network as
# <ASTERISM_BROWSER_NODE_PREFIX><handle> (wasm-<handle>), which every node
# sees, so it is the user's choice and never a part of the email address.
# Lower case letters, digits and single hyphens, HANDLE_MIN to HANDLE_MAX
# characters, starting with a letter; unique among the users. A handle
# given up (changed, or the user removed) stays reserved for its last owner
# for HANDLE_HOLD (ReleasedHandle): the network and its records still know
# it as that person's for a while, so nobody else can take it at once.
#
# TOTP (a second factor) is optional per user: the user turns it on from
# the account page (the secret is shown once, to type into an authenticator
# app) and confirms it with a code. A code is accepted once (otp_last_step).
class User < ApplicationRecord
  OTP_ISSUER = "Asterism Console".freeze
  # Codes one step (30 s) old or ahead are still taken (clock drift).
  OTP_DRIFT = 30
  HANDLE_MIN = 3
  HANDLE_MAX = 20
  HANDLE_FORMAT = /\A[a-z](?:[a-z0-9]|-(?=[a-z0-9]))*\z/
  HANDLE_HOLD = ENV.fetch("ASTERISM_HANDLE_HOLD_DAYS", 30).to_i.days

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :bridge_requests, dependent: :nullify
  has_many :browser_passes, dependent: :destroy
  has_many :revoked_passes, class_name: "BrowserPass", foreign_key: :revoked_by_id, dependent: :nullify
  has_one :invitation, dependent: :nullify
  has_many :created_invitations, class_name: "Invitation", foreign_key: :created_by_id, dependent: :nullify
  has_many :created_room_invites, class_name: "RoomInvite", foreign_key: :created_by_id, dependent: :nullify
  has_many :revoked_room_invites, class_name: "RoomInvite", foreign_key: :revoked_by_id, dependent: :nullify

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :handle, with: ->(h) { h.strip.downcase.presence }

  validates :email_address, presence: true, uniqueness: true,
                            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :handle, allow_nil: true, uniqueness: true, length: { in: HANDLE_MIN..HANDLE_MAX },
                     format: { with: HANDLE_FORMAT,
                               message: "may have lower case letters, digits and single hyphens, and starts with a letter" }
  validate :handle_not_held, if: -> { handle.present? && will_save_change_to_handle? }

  before_update :release_old_handle, if: -> { will_save_change_to_handle? && handle_in_database.present? }
  before_destroy { ReleasedHandle.release!(handle, id) if handle.present? }

  # How the console's own log names the user (never the email address: the
  # log is about the network, where only the handle is known).
  def log_name
    handle.present? ? "user #{id} (#{handle})" : "user #{id}"
  end

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

  private def handle_not_held
    return unless ReleasedHandle.held_for_another?(handle, id)
    errors.add(:handle, "was given up recently by someone else; it is free again after #{HANDLE_HOLD.inspect}")
  end

  private def release_old_handle
    ReleasedHandle.release!(handle_in_database, id)
  end
end
