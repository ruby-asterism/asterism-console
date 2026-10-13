require "test_helper"
require "tmpdir"

# This server's own certificates (Relay::LocalIdentity, bin/asterism setup):
# issued into a directory, and when they must be issued again.
class Relay::LocalIdentityTest < ActiveSupport::TestCase
  class FakeSigner
    def initialize(dir) = @ca = Relay::CertAuthority.create(dir)
    def ca_pem = @ca.cert.to_pem

    def sign(name:, csr: nil, spki: nil, dns: [], ips: [], days: 90)
      c = @ca.sign(name, csr || spki, dns: dns, ips: ips, days: days)
      { "certificate" => c.to_pem, "serial" => c.serial.to_s(16) }
    end
  end

  setup do
    @dir = Dir.mktmpdir
    @signer = FakeSigner.new(File.join(@dir, "ca"))
    Relay::Issuer.signer = @signer
    @out = File.join(@dir, "certs")
  end

  teardown do
    Relay::Issuer.signer = nil
    FileUtils.rm_rf(@dir)
  end

  test "issues the router's and the bridge's certificates, and says when they are stale" do
    assert_match(/no /, Relay::LocalIdentity.stale?(name: "zenohd-cloud", out: @out, ca_pem: @signer.ca_pem))
    rec = Relay::LocalIdentity.issue(name: "zenohd-cloud", out: @out, kind: "router", dns: %w[zenohd router.example.org])
    assert_equal "router", rec.relay_peer.kind
    assert_equal "600", format("%o", File.stat(File.join(@out, "zenohd-cloud.key")).mode & 0o777)
    assert_nil Relay::LocalIdentity.stale?(name: "zenohd-cloud", out: @out, ca_pem: @signer.ca_pem,
                                           dns: %w[zenohd router.example.org])
    assert_match(/does not name other.example.org/,
                 Relay::LocalIdentity.stale?(name: "zenohd-cloud", out: @out, ca_pem: @signer.ca_pem, dns: %w[other.example.org]))
    other = Relay::CertAuthority.create(File.join(@dir, "other"))
    assert_match(/not signed/, Relay::LocalIdentity.stale?(name: "zenohd-cloud", out: @out, ca_pem: other.cert.to_pem))
    assert_match(/ends/, Relay::LocalIdentity.stale?(name: "zenohd-cloud", out: @out, ca_pem: @signer.ca_pem, min_days: 400))

    Relay::LocalIdentity.issue(name: "console", out: @out, kind: "client", rw: [ "asterism/**" ], admin_space: true)
    peer = RelayPeer.find_by!(name: "console")
    assert_equal [ "client", "asterism/**", true ], [ peer.kind, peer.rw_keys, peer.admin_space ]
  end

  test "the enrollment is admin; the planned ones are refused for now" do
    assert_equal "admin", AsterismConsole.enrollment({})
    assert_equal "admin", AsterismConsole.enrollment("ASTERISM_ENROLLMENT" => "admin")
    assert_raises(ArgumentError) { AsterismConsole.enrollment("ASTERISM_ENROLLMENT" => "self") }
    assert_raises(ArgumentError) { AsterismConsole.enrollment("ASTERISM_ENROLLMENT" => "anything") }
    assert_match(/\A\d+\.\d+\.\d+\z/, AsterismConsole::VERSION)
  end
end
