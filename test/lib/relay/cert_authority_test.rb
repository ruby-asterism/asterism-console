require "test_helper"
require "tmpdir"

# The relay's certificate authority (script/relay_certs): what zenohd's TLS
# (rustls) and its ACL need from the certificates.
class Relay::CertAuthorityTest < ActiveSupport::TestCase
  test "a CA, certificates it signs, and the same CA when loaded again" do
    Dir.mktmpdir do |dir|
      ca = Relay::CertAuthority.load_or_create(dir)
      assert ca.cert.extensions.find { _1.oid == "basicConstraints" }.value.start_with?("CA:TRUE")
      assert_equal "600", format("%o", File.stat(File.join(dir, "ca.key")).mode & 0o777)

      cert = ca.issue("zenohd-cloud", dns: %w[localhost], ips: %w[127.0.0.1])
      assert ca.verify(cert)
      assert_equal [ [ "CN", "zenohd-cloud" ] ], cert.subject.to_a.map { _1[0, 2] }
      assert_equal 2, cert.version # v3
      san = cert.extensions.find { _1.oid == "subjectAltName" }.value
      assert_equal "DNS:zenohd-cloud, DNS:localhost, IP Address:127.0.0.1", san
      eku = cert.extensions.find { _1.oid == "extendedKeyUsage" }.value
      assert_includes eku, "TLS Web Server Authentication"
      assert_includes eku, "TLS Web Client Authentication"
      key = OpenSSL::PKey.read(File.read(ca.path("zenohd-cloud", "key")))
      assert cert.check_private_key(key)
      assert_includes File.read(ca.path("zenohd-cloud", "key")), "BEGIN PRIVATE KEY" # PKCS#8

      again = Relay::CertAuthority.load_or_create(dir)
      assert_equal ca.cert.to_der, again.cert.to_der
      assert again.verify(again.issue("console"))
      assert_equal %w[console zenohd-cloud], again.issued.keys

      other = Relay::CertAuthority.create(File.join(dir, "other"))
      refute ca.verify(other.issue("zenohd-home"))
      assert_raises(ArgumentError) { ca.issue("../x") }
      assert_raises(ArgumentError) { ca.issue("ca") }
    end
  end
end
