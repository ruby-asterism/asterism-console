# The ledger: one certificate the signer made for a peer (or one made
# before the signer existed, imported). Only public data: the certificate,
# its serial, dates and fingerprint. The private key is handed over once,
# in the download made when it is issued, and never stored.
#
# Revoking marks it here and takes it out of what counts as valid, so a
# peer whose only certificate is revoked leaves the ACL on the next apply.
# zenohd 1.10.1 has no revocation list: a revoked certificate still passes
# TLS until it expires, and another valid certificate with the same name
# is not told apart from it (the ACL matches the name).
class RelayCertificate < ApplicationRecord
  belongs_to :relay_peer
  belongs_to :issued_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  validates :serial, presence: true, uniqueness: true
  validates :fingerprint, :not_before, :not_after, :certificate_pem, presence: true
  validates :source, inclusion: { in: %w[signer imported] }

  def self.record!(peer, pem, source: "signer", by: nil)
    cert = OpenSSL::X509::Certificate.new(pem)
    create!(relay_peer: peer, serial: cert.serial.to_s(16).downcase,
            fingerprint: Relay::CertAuthority.fingerprint(cert),
            not_before: cert.not_before, not_after: cert.not_after, certificate_pem: cert.to_pem,
            source: source, issued_by: by)
  end

  def common_name
    OpenSSL::X509::Certificate.new(certificate_pem).subject.to_a.find { _1[0] == "CN" }&.dig(1)
  end

  def valid_at?(at = Time.current)
    revoked_at.nil? && not_before <= at && at < not_after
  end

  def status(at = Time.current)
    return "revoked" if revoked_at
    return "expired" if not_after <= at
    return "not yet" if not_before > at
    "valid"
  end

  def revoke!(by)
    update!(revoked_at: Time.current, revoked_by: by) unless revoked_at
  end
end
