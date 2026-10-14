# A room (G2, docs/rooms.md): a time-limited key space on the cloud router
# that anyone with the room's link joins through the door, without an
# account. An admin makes one (name, the app the link opens, how long, how
# many connections); it takes a free room slot, whose certificate and ACL
# were made once (Relay::RoomSlots), so making a room restarts nothing.
#
# The link carries the room's key (Relay::RoomToken) in its fragment: the
# signer signs it, the console keeps nothing of it (only how many links it
# made), and the door checks it with the signer's public keys. Every key
# of a room says the same room, slot, end and connection limit; another
# link for the same room is another key with the same claims.
#
# A room ends at expires_at, or earlier when an admin closes it (closed_at).
# Either way the door refuses its keys and cuts its connections
# (Relay::RoomFiles tells the door; a key's own end is checked by the door
# too). Its slot is free again from then on; the door cuts what is left of
# the old room on that slot before it lets the new room in.
require "securerandom"

class Room < ApplicationRecord
  NAME = /\A[[:print:]]{1,60}\z/
  APP = %r{\A[A-Za-z0-9_./-]{0,200}\z}

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :closed_by, class_name: "User", optional: true

  validates :uid, format: { with: Relay::RoomToken::ROOM }, uniqueness: true
  validates :name, format: { with: NAME }
  validates :app, format: { with: APP }, allow_nil: true
  validates :slot, format: { with: Relay::RoomToken::SLOT }
  validates :max_connections, numericality: { only_integer: true, in: 1..Relay::RoomToken::MAX_CONNECTIONS }
  validate :ends_within_the_cap, on: :create

  class Full < StandardError; end

  # Tests put a stand-in for the signer here.
  class << self
    attr_accessor :signer
  end

  def self.signer_client
    signer || Relay::SignerClient.from_env(root: Rails.root.to_s)
  end

  # One room is made at a time in this process (the console is one Puma
  # process), so two admins cannot take the same free slot.
  OPENING = Mutex.new

  # Open: not closed early and not ended.
  scope :open_now, ->(at = Time.current) { where(closed_at: nil).where("expires_at > ?", at) }

  # The slots a room can take: those whose certificate is in place and in
  # the ACL (bin/asterism setup, then an apply).
  def self.ready_slots
    names = Relay::Settings.slot_names
    peers = RelayPeer.includes(:certificates).where(room_slot: true, name: names.map { Relay::Settings.slot_peer_name(_1) })
    certs = Relay::RoomSlots.certs_dir
    names.select do |slot|
      peer = peers.find { _1.name == Relay::Settings.slot_peer_name(slot) }
      peer&.in_acl? && File.exist?(File.join(certs, "#{peer.name}.key"))
    end
  end

  # A free slot: ready, with no open room; of those, the one whose last room
  # ended longest ago (so a slot just freed rests while there are others).
  def self.free_slot(at = Time.current)
    busy = open_now(at).pluck(:slot)
    free = ready_slots - busy
    last_end = where(slot: free).group(:slot).maximum(Arel.sql("COALESCE(closed_at, expires_at)"))
    free.min_by { [ last_end[_1] || Time.at(0), _1 ] }
  end

  # Makes a room on a free slot. Raises Full when there is none.
  def self.open!(name:, app:, hours:, max_connections:, by:)
    default_hours, max_hours = Relay::Settings.room_hours
    hours = (hours.presence || default_hours).to_f
    raise ArgumentError, "hours must be more than 0 and at most #{max_hours}" unless hours.positive? && hours <= max_hours
    OPENING.synchronize do
      slot = free_slot or raise Full, "every room slot is taken (#{Relay::Settings.room_slots} slots)"
      create!(uid: SecureRandom.hex(8), name: name.to_s.strip, app: app.presence, slot: slot,
              max_connections: max_connections.presence || Relay::Settings.room_max_connections,
              expires_at: Time.current + hours * 3600, created_by: by)
    end
  end

  def open?(at = Time.current)
    closed_at.nil? && expires_at > at
  end

  def status(at = Time.current)
    return "closed" if closed_at
    return "ended" if expires_at <= at
    "open"
  end

  # The key space on the wire.
  def key_space = "room/#{slot}"

  # A new key for the room, signed by the signer: the token (shown once,
  # in the link).
  def mint_key!(signer: self.class.signer_client)
    raise ArgumentError, "the room is #{status}" unless open?
    ans = signer.room_token(room: uid, slot: slot, exp: expires_at.to_i, max: max_connections)
    increment!(:links_made)
    ans.fetch("token")
  end

  def close!(by, reason: "closed by an admin")
    update!(closed_at: Time.current, closed_by: by, close_reason: reason) if closed_at.nil?
  end

  private

  def ends_within_the_cap
    return unless expires_at
    _, max_hours = Relay::Settings.room_hours
    errors.add(:expires_at, "is more than #{max_hours} hours ahead") if expires_at > Time.current + max_hours * 3600 + 60
    errors.add(:expires_at, "is not ahead") if expires_at <= Time.current
  end
end
