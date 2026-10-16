# One router or client of the relay (the registry). Its name is the common
# name of its certificates, its subject in the cloud router's ACL and, by
# convention, its Asterism node ID (a client) or its router name (a
# router's metadata/name): the graph matches nodes to the registry by it.
class RelayPeer < ApplicationRecord
  KINDS = %w[router client].freeze
  NAME = Relay::CertAuthority::NAME_RE
  # A Zenoh key expression, one per line: no spaces, no ? # $ ...
  KEY = %r{\A[A-Za-z0-9_\-.*@~%:+=/]{1,200}\z}

  has_many :certificates, -> { order(id: :desc) }, class_name: "RelayCertificate", dependent: :destroy
  # Roles (G1.5): what the cloud router's ACL gives it, with ${node} expanded
  # to the nodes it speaks for (node_list).
  has_many :peer_roles, class_name: "RelayPeerRole", dependent: :destroy
  has_many :roles, -> { order(:name) }, through: :peer_roles, source: :relay_role

  validates :name, format: { with: NAME }, uniqueness: true
  validates :name, exclusion: { in: %w[ca], message: "is kept for the CA" }
  validates :kind, inclusion: { in: KINDS }
  validates :cert_days, numericality: { only_integer: true, in: 1..Relay::CertAuthority::LEAF_DAYS }
  validate :keys_are_key_expressions
  validate :names_and_addresses
  validate :nodes_are_node_ids

  def self.lines(text)
    text.to_s.lines.map(&:strip).reject(&:empty?)
  end

  def rw_list = self.class.lines(rw_keys)
  def ro_list = self.class.lines(ro_keys)
  def dns_list = self.class.lines(dns_names)
  def node_list = self.class.lines(nodes)
  def ip_list = self.class.lines(ip_addresses)

  def valid_certificates(at = Time.current)
    certificates.select { _1.valid_at?(at) }
  end

  def current_certificate
    valid_certificates.max_by(&:not_after)
  end

  def cert_expires_at
    current_certificate&.not_after
  end

  # In the next configuration's ACL: enabled, with a valid certificate.
  def in_acl?
    enabled? && current_certificate.present?
  end

  # The nodes it speaks for: the list, or its own name.
  def speaks_for
    node_list.presence || [ name ]
  end

  # A room slot's certificate (G2): room-01 .. room-NN, and its seats'
  # (0.3.0): room-01-s01 .. room-01-s16, made by bin/asterism setup
  # (Relay::RoomSlots). Their ACL is fixed (Relay::CloudConfig).
  ROOM_NAME = /\Aroom-([0-9]{2})(?:-s([0-9]{2}))?\z/

  def room_slot_name
    name[ROOM_NAME, 1] if room_slot?
  end

  def room_seat_name
    name[ROOM_NAME, 2] if room_slot?
  end

  def room_seat? = room_seat_name.present?

  # What Relay::CloudConfig takes.
  def to_config
    if room_slot?
      return { "name" => name, "kind" => kind, "in_acl" => in_acl?, "room_slot" => room_slot_name,
               "room_seat" => room_seat_name }.compact
    end
    { "name" => name, "kind" => kind, "rw" => rw_list, "ro" => ro_list,
      "admin_space" => admin_space?, "in_acl" => in_acl?,
      "roles" => roles.map(&:name), "nodes" => node_list }
  end

  # What the bridge needs to mark the graph.
  def to_registry
    { "name" => name, "kind" => kind, "enabled" => enabled?, "in_acl" => in_acl?,
      "expires" => cert_expires_at&.utc&.iso8601, "description" => description }
  end

  # The rooms' seats (0.3.0) are left out: 16 a slot, never a node of
  # their own (the graph shows a seat's page under its node ID in its room).
  def self.registry
    includes(:certificates).order(:name).reject(&:room_seat?).map(&:to_registry)
  end

  private

  def keys_are_key_expressions
    { rw_keys: rw_list, ro_keys: ro_list }.each do |attr, keys|
      bad = keys.reject { KEY.match?(_1) }
      errors.add(attr, "has lines that are not key expressions: #{bad.join(' ')}") if bad.any?
    end
  end

  # Asterism node IDs: one key chunk, no wildcard, not starting with @.
  def nodes_are_node_ids
    bad = node_list.reject { NAME.match?(_1) }
    errors.add(:nodes, "has lines that are not node IDs: #{bad.join(' ')}") if bad.any?
  end

  def names_and_addresses
    bad = dns_list.reject { NAME.match?(_1) }
    errors.add(:dns_names, "has bad names: #{bad.join(' ')}") if bad.any?
    ip_list.each { IPAddr.new(_1) }
  rescue IPAddr::InvalidAddressError => e
    errors.add(:ip_addresses, "has a bad address (#{e.message})")
  end
end
