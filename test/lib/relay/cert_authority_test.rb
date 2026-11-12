require "test_helper"
require "tmpdir"
require_relative "../../test_helpers/dated_ca"

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

  # [notBefore, notAfter] as encoded (tbsCertificate's fifth field, validity).
  def time_fields(cert)
    OpenSSL::ASN1.decode(cert.to_der).value[0].value[4].value
  end

  test "no expiry: notAfter 99991231235959Z as GeneralizedTime, on a new CA and on what it signs" do
    Dir.mktmpdir do |dir|
      ca = Relay::CertAuthority.create(dir)
      assert Relay::CertAuthority.no_expiry?(ca.cert.not_after), "a new CA has no end"
      cert = ca.issue("fmruby-aaaaaa", no_expiry: true)
      assert_equal Relay::CertAuthority::NO_EXPIRY, cert.not_after
      validity = time_fields(cert)
      assert_kind_of OpenSSL::ASN1::UTCTime, validity[0]
      assert_kind_of OpenSSL::ASN1::GeneralizedTime, validity[1]
      assert_equal "99991231235959Z", OpenSSL::ASN1.decode(validity[1].to_der).value.strftime("%Y%m%d%H%M%SZ")
      assert ca.verify(cert)
      dated = ca.issue("dated", days: 30)
      refute Relay::CertAuthority.no_expiry?(dated.not_after)
      assert_raises(ArgumentError) { ca.issue("x", days: nil) }
      assert Relay::CertAuthority.no_expiry?(Time.utc(9999, 12, 31, 23, 59, 59).in_time_zone("Asia/Tokyo"))
      refute Relay::CertAuthority.no_expiry?(nil)
    end
  end

  test "a CA certificate with an end is made again without one: the same key, subject and SKI; what it signed validates" do
    Dir.mktmpdir do |dir|
      Relay::CertAuthority.create(dir)
      old = DatedCa.make!(dir)
      ca = Relay::CertAuthority.load(dir)
      before = [ ca.issue("fmruby-aaaaaa", no_expiry: true), ca.issue("dated", days: 30) ]
      made, was, kept = Relay::CertAuthority.no_expiry_ca!(dir)
      assert_equal old.to_der, was.to_der
      assert_equal "ca.pem.until-#{old.not_after.utc.strftime('%Y%m%d')}", File.basename(kept)
      assert_equal old.to_pem, File.read(kept)
      fresh = OpenSSL::X509::Certificate.new(File.read(File.join(dir, "ca.pem")))
      assert_equal made.cert.to_der, fresh.to_der
      assert Relay::CertAuthority.no_expiry?(fresh.not_after)
      assert_equal [ old.subject.to_der, old.public_key.to_der, old.not_before ], [ fresh.subject.to_der, fresh.public_key.to_der, fresh.not_before ]
      ext = ->(c) { c.extensions.map { [ _1.oid, _1.value, _1.critical? ] } }
      assert_equal ext.(old), ext.(fresh), "the extensions, the subject key identifier with them"
      refute_equal old.serial, fresh.serial
      before.each { assert made.verify(_1), "#{_1.subject} validates under the new CA certificate" }
      assert made.verify(made.issue("later", no_expiry: true))
      old_store = OpenSSL::X509::Store.new
      old_store.add_cert(old)
      assert old_store.verify(made.issue("later2", days: 3)), "and the one before verifies what the new one signs"
      assert_nil Relay::CertAuthority.no_expiry_ca!(dir), "once"
      assert_equal fresh.to_der, Relay::CertAuthority.load(dir).cert.to_der
      refute_includes Relay::CertAuthority.load(dir).issued.keys, "ca", "the kept file is not an issued certificate"
    end
  end
end
