require "test_helper"
require "tmpdir"
require "socket"
require "rubygems/package"

# bin/signer as a real process (with a CA in a temporary directory) and the
# console's side of it: Relay::SignerClient and Relay::Issuer.
class Relay::SignerTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  TOKEN = "t" * 32

  def self.free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1]
  ensure
    s&.close
  end

  setup do
    @dir = Dir.mktmpdir
    @ca_dir = File.join(@dir, "ca")
    system(Rails.root.join("bin/signer").to_s, "init", "--ca-dir", @ca_dir, out: File::NULL, exception: true)
    @port = self.class.free_port
    @pid = Process.spawn({ "SIGNER_TOKEN" => TOKEN }, Rails.root.join("bin/signer").to_s, "serve",
                         "--ca-dir", @ca_dir, "--listen", "127.0.0.1:#{@port}", out: File::NULL)
    @client = Relay::SignerClient.new("http://127.0.0.1:#{@port}", TOKEN)
    50.times do
      TCPSocket.new("127.0.0.1", @port).close
      break
    rescue SystemCallError
      sleep 0.1
    end
  end

  teardown do
    Process.kill("TERM", @pid) rescue nil
    Process.wait(@pid) rescue nil
    FileUtils.rm_rf(@dir)
  end

  test "the signer signs a request; its CA verifies the certificate" do
    ca = OpenSSL::X509::Certificate.new(@client.ca_pem)
    key, csr = Relay::CertAuthority.request("ignored-cn")
    ans = @client.sign(name: "w2bot", csr: csr, dns: %w[w2bot.local], ips: %w[127.0.0.1], days: 7)
    cert = OpenSSL::X509::Certificate.new(ans["certificate"])
    assert_equal "/CN=w2bot", cert.subject.to_s, "the name given, not the request's subject"
    assert cert.check_private_key(key)
    store = OpenSSL::X509::Store.new
    store.add_cert(ca)
    assert store.verify(cert)
    assert_in_delta 7 * 86_400, cert.not_after - cert.not_before, 120
    assert_equal cert.serial.to_s(16).downcase, ans["serial"]
    log = File.readlines(File.join(@ca_dir, "issued.log")).map { JSON.parse(_1) }
    assert_equal [ [ "w2bot", ans["serial"] ] ], log.map { _1.values_at("name", "serial") }
    assert_equal "600", format("%o", File.stat(File.join(@ca_dir, "ca.key")).mode & 0o777)
    assert_equal "700", format("%o", File.stat(@ca_dir).mode & 0o777)
  end

  test "the signer refuses a bad token, a bad name, too many days, a forged request" do
    bad = Relay::SignerClient.new("http://127.0.0.1:#{@port}", "x" * 32)
    assert_raises(Relay::SignerClient::Error) { bad.ca_pem }
    _key, csr = Relay::CertAuthority.request("x")
    e = assert_raises(Relay::SignerClient::Error) { @client.sign(name: "../ca", csr: csr) }
    assert_match(/400/, e.message)
    assert_raises(Relay::SignerClient::Error) { @client.sign(name: "ok", csr: csr, days: 5000) }
    other = OpenSSL::PKey::EC.generate("prime256v1")
    forged = OpenSSL::X509::Request.new(csr.to_pem)
    forged.public_key = other # the signature no longer matches
    e = assert_raises(Relay::SignerClient::Error) { @client.sign(name: "ok", csr: forged) }
    assert_match(/signature/, e.message)
    assert_raises(Relay::SignerClient::Error) { Relay::SignerClient.new("http://127.0.0.1:1", TOKEN).ca_pem }
  end

  test "the signer signs a bare public key (SPKI) and refuses a private key or another curve" do
    key = OpenSSL::PKey::EC.generate("prime256v1")
    pub = OpenSSL::PKey.read(key.public_to_der)
    ans = @client.sign(name: "w4bot", spki: pub, dns: %w[w4bot.local], days: 3)
    cert = OpenSSL::X509::Certificate.new(ans["certificate"])
    assert_equal "/CN=w4bot", cert.subject.to_s
    assert cert.check_private_key(key), "a certificate for the key the public half came from"
    ext = cert.extensions.to_h { [ _1.oid, _1.value ] }
    assert_equal "TLS Web Server Authentication, TLS Web Client Authentication", ext["extendedKeyUsage"]
    assert_equal "DNS:w4bot, DNS:w4bot.local", ext["subjectAltName"]
    req = ->(body) do
      r = Net::HTTP::Post.new("/sign", "Content-Type" => "application/json", "Authorization" => "Bearer #{TOKEN}")
      r.body = JSON.generate(body)
      Net::HTTP.start("127.0.0.1", @port) { _1.request(r) }
    end
    priv = req.({ "name" => "x", "spki" => [ key.private_to_der ].pack("m0") })
    assert_equal "400", priv.code
    rsa = OpenSSL::PKey::RSA.new(2048)
    assert_equal "400", req.({ "name" => "x", "spki" => [ rsa.public_to_der ].pack("m0") }).code
    p384 = OpenSSL::PKey::EC.generate("secp384r1")
    assert_equal "400", req.({ "name" => "x", "spki" => [ p384.public_to_der ].pack("m0") }).code
  end

  test "issuing for a peer from a browser's public key: the ledger has the certificate, no private key anywhere" do
    peer = RelayPeer.create!(name: "w2bot", kind: "client", rw_keys: "asterism/**", cert_days: 30)
    key = OpenSSL::PKey::EC.generate("prime256v1")
    record, cert_pem, ca_pem = Relay::Issuer.new(signer: @client).issue(peer, [ key.public_to_der ].pack("m0"),
                                                                        by: users(:admin))
    cert = OpenSSL::X509::Certificate.new(cert_pem)
    assert cert.check_private_key(key)
    store = OpenSSL::X509::Store.new
    store.add_cert(OpenSSL::X509::Certificate.new(ca_pem))
    assert store.verify(cert)
    assert_equal [ record.serial, "signer", users(:admin) ], [ cert.serial.to_s(16).downcase, record.source, record.issued_by ]
    assert peer.reload.in_acl?
    stored = RelayCertificate.all.map(&:attributes).to_s + RelayPeer.all.map(&:attributes).to_s
    refute_includes stored, "PRIVATE KEY"
    assert_raises(Relay::Issuer::Error) { Relay::Issuer.new(signer: @client).issue(peer, [ key.private_to_der ].pack("m0")) }
    assert_raises(Relay::Issuer::Error) { Relay::Issuer.new(signer: @client).issue(peer, "garbage") }
    peer.update!(enabled: false)
    assert_raises(Relay::Issuer::Error) { Relay::Issuer.new(signer: @client).issue(peer, [ key.public_to_der ].pack("m0")) }
  end

  test "issue_local: this server's own key, made here" do
    peer = RelayPeer.create!(name: "zenohd-vps", kind: "router", dns_names: "router.example.org", cert_days: 30)
    record, key, cert_pem, = Relay::Issuer.new(signer: @client).issue_local(peer)
    cert = OpenSSL::X509::Certificate.new(cert_pem)
    assert cert.check_private_key(key)
    assert_includes cert.extensions.find { _1.oid == "subjectAltName" }.value, "DNS:router.example.org"
    assert_equal record.serial, cert.serial.to_s(16).downcase
  end
end
