# One router or client of the relay (the registry). Its name is the common
# name of its certificates, its subject in the cloud router's ACL and, by
# convention, its Asterism node ID (a client) or its router name (a
# router's metadata/name): the graph matches nodes to the registry by it.
#
# Files with the console (T4b, docs/files.md): two marks per row, for the
# nodes it speaks for. files_to_console: they may send files to the console
# (the bridge's inbox takes them; the ACL gets the ask line
# asterism/<console>/transfer/inbox/call/<node>). files_from_console: the
# console may send files to them (the page offers them; the ACL gets the rw
# lines asterism/<node>/transfer and asterism/<node>/transfer/**). A
# disabled row's nodes neither send nor receive.
#
# Who its machines receive files from (0.3.16, T6, docs/files.md): two
# lists, one per kind (receive_files_from: "file", receive_checkpoints_from:
# "checkpoint"), of node IDs and patterns ("fmruby-*", "*"), one per line.
# The bridge sends them to the nodes it speaks for (Bridge::Receivers; their
# transfer app writes them into the managed part of receive.toml), and the
# ACL lets the senders call those nodes' inboxes (Relay::CloudConfig).
# receivers_changed_at is when they last changed (the machines keep it with
# their copy); a row that has one is "managed": its nodes keep their
# transfer keys in the ACL, so an emptied list still reaches them.
# receivers_delivered is the bridge's record of what each node got (JSON).
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
  # The rooms' seats' certificates (room-01-s03, Relay::RoomCerts) and,
  # before 0.3.1, the slots' (room-01): not registry rows.
  ROOM_NAME = /\Aroom-[0-9]{2}(-s[0-9]{2})?\z/
  validates :name, format: { without: ROOM_NAME, message: "is kept for the rooms' certificates" }
  validates :kind, inclusion: { in: KINDS }
  # A display name for the pages and the graph (0.3.5): "Tab5" before the
  # name, "Tab5 (fmruby-aaaaaa)". Optional; the name stays what the ACL uses.
  DISPLAY_NAME_MAX = 40
  normalizes :display_name, with: ->(v) { v.to_s.gsub(/[[:cntrl:]]/, " ").squish.presence }
  validates :display_name, length: { maximum: DISPLAY_NAME_MAX }
  validates :cert_days, numericality: { only_integer: true, in: 1..Relay::CertAuthority::LEAF_DAYS }
  # "No expiry" (0.3.20): its certificates end 9999-12-31 instead of after
  # cert_days (a client's only). Such a certificate is stopped by disabling
  # or removing the row and applying: the ACL then leaves its name out.
  validates :cert_no_expiry, absence: { message: "is for a client only" }, unless: -> { kind == "client" }
  validate :keys_are_key_expressions
  validate :names_and_addresses
  validate :nodes_are_node_ids

  include ReceiverLists

  def self.lines(text)
    text.to_s.lines.map(&:strip).reject(&:empty?)
  end

  # "Tab5 (fmruby-aaaaaa)" with a display name, the name alone without.
  def label
    display_name.present? ? "#{display_name} (#{name})" : name
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

  def receiver_nodes = speaks_for

  # The nodes that may be chosen as senders (Edit): every row's nodes, the
  # browsers with a certificate of their user's (T8, wasm-<handle>,
  # Relay::BrowserCerts) and the console's, as [label, node]; the
  # receiver's own node left out (a client row's, a user's browser; a home
  # router's nodes may send to each other).
  def self.sender_choices(except: nil)
    console = ENV.fetch("ASTERISM_CONSOLE_NODE", "console")
    own = if except.is_a?(User) then except.receiver_nodes
    elsif except && except.node_list.empty? then [ except.name ]
    else []
    end
    rows = order(:name).to_a
    list = rows.flat_map do |r|
      r.speaks_for.map { |n| [ r.display_name.present? && n == r.name ? "#{r.display_name} (#{n})" : n, n ] }
    end
    Relay::BrowserCerts.names.each { list << [ "#{_1} (a browser)", _1 ] }
    list << [ "#{console} (the console)", console ] unless list.any? { _1[1] == console }
    list.reject { own.include?(_1[1]) }.uniq { _1[1] }.sort_by { _1[1] }
  end

  # The enabled rows whose lists were chosen, for the bridge.
  def self.managed
    where(enabled: true).where.not(receivers_changed_at: nil).order(:name)
  end

  # What Relay::CloudConfig takes.
  def to_config
    { "name" => name, "kind" => kind, "rw" => rw_list, "ro" => ro_list,
      "admin_space" => admin_space?, "in_acl" => in_acl?,
      "roles" => roles.map(&:name), "nodes" => node_list,
      "files_to_console" => files_to_console?, "files_from_console" => files_from_console?,
      "receives" => receives_config,
      "receivers_managed" => managed_receivers? }
  end

  # The nodes that may send files to the console (the enabled rows marked
  # files_to_console), sorted.
  def self.file_senders
    where(enabled: true, files_to_console: true).flat_map(&:speaks_for).uniq.sort
  end

  # The nodes the console may send files to (files_from_console), sorted.
  def self.file_receivers
    where(enabled: true, files_from_console: true).flat_map(&:speaks_for).uniq.sort
  end

  def self.receives_files?(node)
    file_receivers.include?(node.to_s)
  end

  # What the bridge needs to mark the graph.
  def to_registry
    { "name" => name, "kind" => kind, "enabled" => enabled?, "in_acl" => in_acl?,
      "expires" => cert_expires_at&.utc&.iso8601, "description" => description,
      "display_name" => display_name }
  end

  def self.registry
    includes(:certificates).order(:name).map(&:to_registry)
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
