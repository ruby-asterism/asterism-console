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

  validates :name, format: { with: NAME }, uniqueness: true
  validates :name, exclusion: { in: %w[ca], message: "is kept for the CA" }
  validates :kind, inclusion: { in: KINDS }
  validates :cert_days, numericality: { only_integer: true, in: 1..Relay::CertAuthority::LEAF_DAYS }
  validate :keys_are_key_expressions
  validate :names_and_addresses

  def self.lines(text)
    text.to_s.lines.map(&:strip).reject(&:empty?)
  end

  def rw_list = self.class.lines(rw_keys)
  def ro_list = self.class.lines(ro_keys)
  def dns_list = self.class.lines(dns_names)
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

  # What Relay::CloudConfig takes.
  def to_config
    { "name" => name, "kind" => kind, "rw" => rw_list, "ro" => ro_list,
      "admin_space" => admin_space?, "in_acl" => in_acl? }
  end

  # What the bridge needs to mark the graph.
  def to_registry
    { "name" => name, "kind" => kind, "enabled" => enabled?, "in_acl" => in_acl?,
      "expires" => cert_expires_at&.utc&.iso8601, "description" => description }
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

  def names_and_addresses
    bad = dns_list.reject { NAME.match?(_1) }
    errors.add(:dns_names, "has bad names: #{bad.join(' ')}") if bad.any?
    ip_list.each { IPAddr.new(_1) }
  rescue IPAddr::InvalidAddressError => e
    errors.add(:ip_addresses, "has a bad address (#{e.message})")
  end
end
