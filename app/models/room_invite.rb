# An invite link to make rooms (0.3.5, docs/rooms.md "Invite links"). Rooms
# are made by admins; an invite link lets someone without an account make
# them too, on a page of its own (/invite) that does nothing else: choose
# the app (one of the link's), how long (3 hours unless they say, at most
# MAX_HOURS = 12) and an optional name, get the room's link, see and close
# the rooms made through the same invite link. An admin gives it an end, a limit of rooms open at once
# through it and the apps it may open (of ASTERISM_ROOM_APPS), and may
# revoke it at any time.
#
# An admin may also write a message for each invite link (0.3.6): its page
# shows it above the form, as plain text (no HTML, no links made), e.g. how
# to make a room, in the visitors' language. A new invite link starts with
# the message of the one made last.
#
# Each invite link has a group (0.3.8): a random hex string made with it,
# not secret and unrelated to the secret, that the door's file gives each
# room made through it (rooms.json "group", Relay::RoomFiles). A game host
# keeps it with the rooms' game records, so the rooms of one invite link
# see each other's records (asterism-games 0.16.0). It never changes, a
# revoked link's included.
#
# The secret travels in the link's fragment (/invite#invite=<secret>), so
# neither nginx's nor Rails' log sees it: the page hands it to the console
# in a form's body. The console keeps only its SHA-256 (as for the users'
# invitations), shows the whole link once, when it is made, and never
# again.
#
# Rooms made through an invite link are rooms like any other: they take a
# free slot (the slots are the limit of all rooms, whoever made them), the
# door lets them in the same way, and an admin sees and closes them on the
# rooms' page, which says which invite link made each.
require "digest"
require "json"
require "securerandom"

class RoomInvite < ApplicationRecord
  NAME = /\A[[:print:]]{1,60}\z/
  SECRET = /\A[A-Za-z0-9_-]{40,100}\z/
  MAX_HOURS = 12
  DEFAULT_HOURS = 3
  DEFAULT_DAYS = 7
  MAX_DAYS = 90
  DEFAULT_MAX_ROOMS = 1
  MAX_MESSAGE = 4000
  GROUP = /\A\h{32}\z/

  # Why a room was not made through an invite link (the page shows the message).
  class Refused < StandardError; end

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true
  has_many :rooms, dependent: :nullify

  validates :name, format: { with: NAME }
  validates :token_digest, presence: true, uniqueness: true
  validates :max_rooms, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 99 }
  validates :message, length: { maximum: MAX_MESSAGE }
  validates :records_group, format: { with: GROUP }, uniqueness: true
  validate :apps_listed
  validate :apps_offered, on: :create

  before_validation(on: :create) { self.records_group ||= SecureRandom.hex(16) }

  normalizes :name, with: ->(v) { v.to_s.gsub(/[[:cntrl:]]/, " ").squeeze(" ").strip }
  # Line ends as "\n", no other control characters but tabs, no blank lines
  # around it; an empty message is none (nil).
  normalizes :message, with: ->(v) { v.to_s.gsub(/\r\n?/, "\n").gsub(/[[:cntrl:]&&[^\n\t]]/, "").strip.presence }

  attr_reader :token

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # The apps an invite link may offer: those of ASTERISM_ROOM_APPS
  # ([[label, path]]).
  def self.app_choices(env = ENV) = RoomPage.listed_apps(env)

  # Makes an invite link; its secret is #token on the returned record (the
  # only time it exists outside the link).
  def self.issue!(by:, name:, days: DEFAULT_DAYS, max_rooms: DEFAULT_MAX_ROOMS, apps: [], message: nil)
    days = Integer(days.presence || DEFAULT_DAYS, exception: false)
    raise ArgumentError, "days must be 1..#{MAX_DAYS}" unless days&.between?(1, MAX_DAYS)
    token = SecureRandom.urlsafe_base64(32)
    create!(created_by: by, name: name, token_digest: digest(token), expires_at: days.days.from_now,
            max_rooms: max_rooms.presence || DEFAULT_MAX_ROOMS, apps: JSON.generate(Array(apps).compact_blank.uniq),
            message: message)
      .tap { _1.instance_variable_set(:@token, token) }
  end

  # The message a new invite link starts with: that of the one made last.
  def self.last_message = order(:id).last&.message

  # The invite link of a secret, open or not (nil for a secret that is no
  # invite link's).
  def self.find_by_secret(token)
    return nil unless token.is_a?(String) && token.match?(SECRET)
    find_by(token_digest: digest(token))
  end

  def app_paths = JSON.parse(apps.to_s)

  # The apps its rooms may open now: its own, of those still in
  # ASTERISM_ROOM_APPS ([[label, path]]).
  def app_choices(env = ENV)
    mine = app_paths
    self.class.app_choices(env).select { mine.include?(_1[1]) }
  end

  def status(at = Time.current)
    return "revoked" if revoked_at
    return "expired" if expires_at <= at
    "open"
  end

  def open?(at = Time.current) = status(at) == "open"

  # Why it does not let anyone in (nil when it does), for its page.
  def closed_reason(at = Time.current)
    case status(at)
    when "revoked" then "This invite link was revoked by an admin."
    when "expired" then "This invite link expired #{expires_at.utc.strftime('%Y-%m-%d %H:%M UTC')}."
    end
  end

  def open_rooms(at = Time.current) = rooms.open_now(at)

  # The longest room it makes: MAX_HOURS, or less when the console's own
  # longest (ASTERISM_ROOM_MAX_HOURS, 24 unless set) is less. Unless the
  # visitor says otherwise, DEFAULT_HOURS (or the longest, when less).
  def self.max_hours = [ MAX_HOURS, Relay::Settings.room_hours[1] ].min
  def self.default_hours = [ DEFAULT_HOURS, max_hours ].min

  # Makes a room through this invite link (Room.open! checks the end, the
  # app and its limit of open rooms in the same lock as the slot).
  def open_room!(name:, app:, hours:)
    hours = (hours.presence || self.class.default_hours).to_f
    raise Refused, "a room lasts more than 0 and at most #{self.class.max_hours} hours" unless hours.positive? && hours <= self.class.max_hours
    raise Refused, "this invite link cannot open that app" unless app_choices.any? { _1[1] == app.to_s }
    name = name.to_s.gsub(/[[:cntrl:]]/, " ").strip.presence || "#{self.name} #{Time.current.strftime('%H:%M')}"[0, 60]
    Room.open!(name: name, app: app, hours: hours, max_connections: nil, by: nil, invite: self)
  end

  def revoke!(by)
    update!(revoked_at: Time.current, revoked_by: by) if revoked_at.nil?
  end

  private

  def apps_listed
    list = JSON.parse(apps.to_s)
    errors.add(:apps, "must have one app or more") unless list.is_a?(Array) && list.any?
    errors.add(:apps, "must be paths like /app/test/othello.app.rb") unless list.is_a?(Array) && list.all? { _1.is_a?(String) && _1.present? && Room::APP.match?(_1) }
  rescue JSON::ParserError
    errors.add(:apps, "is not a list")
  end

  def apps_offered
    offered = self.class.app_choices.map(&:last)
    extra = app_paths - offered
    errors.add(:apps, "not in ASTERISM_ROOM_APPS: #{extra.join(', ')}") if extra.any?
  rescue JSON::ParserError
    nil
  end
end
