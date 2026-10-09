require "test_helper"
require "tmpdir"
require "rubygems/package"

class Relay::CertificatesControllerTest < ActionDispatch::IntegrationTest
  # Signs with a CA of its own (what bin/signer does, without the process).
  class FakeSigner
    def initialize(dir)
      @ca = Relay::CertAuthority.create(dir)
    end

    def ca_pem = @ca.cert.to_pem

    def sign(name:, csr:, dns: [], ips: [], days: 90)
      c = @ca.sign(name, csr, dns: dns, ips: ips, days: days)
      { "certificate" => c.to_pem, "serial" => c.serial.to_s(16) }
    end
  end

  setup do
    @dir = Dir.mktmpdir
    Relay::Issuer.signer = FakeSigner.new(@dir)
    @peer = RelayPeer.create!(name: "w2bot", kind: "client", rw_keys: "asterism/**", cert_days: 10)
    sign_in_as(users(:admin))
  end

  teardown do
    Relay::Issuer.signer = nil
    FileUtils.rm_rf(@dir)
  end

  test "issuing downloads the key once and records the certificate" do
    post relay_peer_certificates_path(@peer)
    assert_response :success
    assert_equal "application/x-tar", response.media_type
    assert_match(/attachment; filename="w2bot-[0-9a-f]{8}\.tar"/, response.headers["Content-Disposition"])
    assert_includes response.headers["Cache-Control"], "no-store"
    names = []
    Gem::Package::TarReader.new(StringIO.new(response.body)).each { names << _1.full_name }
    assert_includes names, "w2bot/w2bot.key"
    cert = @peer.certificates.sole
    assert_equal [ "signer", users(:admin), "w2bot" ], [ cert.source, cert.issued_by, cert.common_name ]
    assert_in_delta 10.days.from_now, cert.not_after, 120
    assert @peer.reload.in_acl?

    get relay_peer_path(@peer)
    assert_select "td code", cert.serial
    assert_select ".badge", "in the ACL"
  end

  test "revoking takes the peer out of the next ACL" do
    post relay_peer_certificates_path(@peer)
    cert = @peer.certificates.sole
    patch revoke_relay_peer_certificate_path(@peer, cert)
    assert_redirected_to relay_peer_path(@peer)
    assert_equal [ "revoked", users(:admin) ], [ cert.reload.status, cert.revoked_by ]
    refute @peer.reload.in_acl?
    assert_equal [], Relay::Applier.config_for.subject_names
  end

  test "a disabled peer gets no certificate; a signer that does not answer is said so" do
    @peer.update!(enabled: false)
    post relay_peer_certificates_path(@peer)
    assert_redirected_to relay_peer_path(@peer)
    assert_match(/disabled/, flash[:alert])
    @peer.update!(enabled: true)
    Relay::Issuer.signer = Relay::SignerClient.new("http://127.0.0.1:1", "x" * 32)
    post relay_peer_certificates_path(@peer)
    assert_match(/did not answer/, flash[:alert])
    assert_equal 0, @peer.certificates.count
  end
end
