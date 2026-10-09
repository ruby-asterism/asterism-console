# A small certificate authority for the routers and clients of a Zenoh
# relay (mTLS between zenohd routers, TLS clients with a certificate).
# Plain Ruby with the standard OpenSSL library; no Rails: script/relay_certs
# and the signer (bin/signer, the one process that holds the CA's key) use
# it. The console never loads a CA key; it asks the signer (Relay::SignerClient).
#
#   ca = Relay::CertAuthority.load_or_create("storage/relay/certs")
#   ca.issue("zenohd-cloud", dns: %w[zenohd-cloud localhost], ips: %w[127.0.0.1])
#   ca.issue("zenohd-home")
#
# Files in the directory:
#   ca.pem, ca.key           the CA (the key never leaves this directory)
#   <name>.pem, <name>.key   one certificate and key per router or client
#
# The certificate's common name is the name zenohd's ACL matches
# (access_control subjects, cert_common_names). Keys are ECDSA P-256 in
# PKCS#8 PEM (mode 0600). Certificates carry the extensions rustls (zenohd,
# zenoh-c) wants: v3, subjectAltName, keyUsage and extendedKeyUsage.
require "openssl"
require "fileutils"
require "securerandom"
require "ipaddr"

module Relay
  class CertAuthority
    CA_DAYS = 3650
    LEAF_DAYS = 825
    NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z/

    attr_reader :dir, :cert, :key

    # Loads the CA in dir, or makes a new one there when it has none.
    def self.load_or_create(dir, common_name: "Asterism Relay CA")
      ca_pem = File.join(dir, "ca.pem")
      ca_key = File.join(dir, "ca.key")
      if File.exist?(ca_pem) && File.exist?(ca_key)
        new(dir, OpenSSL::X509::Certificate.new(File.read(ca_pem)), OpenSSL::PKey.read(File.read(ca_key)))
      else
        create(dir, common_name: common_name)
      end
    end

    # Loads the CA in dir; fails when there is none.
    def self.load(dir)
      new(dir, OpenSSL::X509::Certificate.new(File.read(File.join(dir, "ca.pem"))),
          OpenSSL::PKey.read(File.read(File.join(dir, "ca.key"))))
    end

    def self.create(dir, common_name: "Asterism Relay CA")
      FileUtils.mkdir_p(dir, mode: 0o700)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = serial
      cert.subject = cert.issuer = OpenSSL::X509::Name.new([ [ "CN", common_name ] ])
      cert.public_key = key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + CA_DAYS * 86_400
      ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE,pathlen:0", true))
      cert.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
      cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      write(File.join(dir, "ca.key"), key.private_to_pem, 0o600)
      write(File.join(dir, "ca.pem"), cert.to_pem, 0o644)
      new(dir, cert, key)
    end

    def self.serial
      OpenSSL::BN.new(SecureRandom.hex(16), 16)
    end

    def self.write(path, text, mode)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, mode) { |f| f.write(text) }
      File.chmod(mode, path)
    end

    def initialize(dir, cert, key)
      @dir = dir
      @cert = cert
      @key = key
    end

    def path(name, ext)
      File.join(@dir, "#{name}.#{ext}")
    end

    def issued?(name)
      File.exist?(path(name, "pem")) && File.exist?(path(name, "key"))
    end

    # Issues <name>.pem / <name>.key, signed by this CA. The common name is
    # name. dns / ips: the names a client checks when it connects to this
    # one (routers that listen); name itself is always a DNS name too.
    # Good for both server and client authentication (a router listens and
    # connects with the same certificate). Returns the certificate.
    def issue(name, dns: [], ips: [], days: LEAF_DAYS)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      cert = sign(name, key, dns: dns, ips: ips, days: days)
      self.class.write(path(name, "key"), key.private_to_pem, 0o600)
      self.class.write(path(name, "pem"), cert.to_pem, 0o644)
      cert
    end

    # Signs a certificate for name over public_key (a key, or a CSR whose
    # signature is checked; only its public key is taken, the subject comes
    # from name). Nothing is written. Used by issue and by bin/signer.
    def sign(name, public_key, dns: [], ips: [], days: LEAF_DAYS)
      raise ArgumentError, "bad name: #{name.inspect}" unless NAME_RE.match?(name.to_s) && name != "ca"
      raise ArgumentError, "bad days: #{days.inspect}" unless days.is_a?(Integer) && days.between?(1, LEAF_DAYS)
      dns = Array(dns).map(&:to_s)
      ips = Array(ips).map(&:to_s)
      bad = dns.reject { NAME_RE.match?(_1) }
      raise ArgumentError, "bad DNS names: #{bad.join(' ')}" unless bad.empty?
      ips.each { IPAddr.new(_1) }
      if public_key.is_a?(OpenSSL::X509::Request)
        raise ArgumentError, "the request's signature does not match its key" unless public_key.verify(public_key.public_key)
        public_key = public_key.public_key
      end
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = self.class.serial
      cert.subject = OpenSSL::X509::Name.new([ [ "CN", name ] ])
      cert.issuer = @cert.subject
      cert.public_key = public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + days * 86_400
      ef = OpenSSL::X509::ExtensionFactory.new(@cert, cert)
      san = ([ name ] + dns).uniq.map { "DNS:#{_1}" } + ips.map { "IP:#{_1}" }
      cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
      cert.add_extension(ef.create_extension("keyUsage", "digitalSignature,keyAgreement", true))
      cert.add_extension(ef.create_extension("extendedKeyUsage", "serverAuth,clientAuth", false))
      cert.add_extension(ef.create_extension("subjectAltName", san.join(","), false))
      cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
      cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always", false))
      cert.sign(@key, OpenSSL::Digest.new("SHA256"))
      cert
    rescue IPAddr::InvalidAddressError => e
      raise ArgumentError, "bad IP address: #{e.message}"
    end

    # A key and a certificate request for name (the side that asks a signer:
    # the key stays with the caller).
    def self.request(name)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      csr = OpenSSL::X509::Request.new
      csr.version = 0
      csr.subject = OpenSSL::X509::Name.new([ [ "CN", name.to_s ] ])
      csr.public_key = key
      csr.sign(key, OpenSSL::Digest.new("SHA256"))
      [ key, csr ]
    end

    def self.fingerprint(cert)
      OpenSSL::Digest::SHA256.hexdigest(cert.to_der).scan(/../).join(":")
    end

    # The certificates issued in this directory (name => certificate).
    def issued
      Dir[File.join(@dir, "*.pem")].sort.filter_map do |f|
        n = File.basename(f, ".pem")
        next if n == "ca"
        [ n, OpenSSL::X509::Certificate.new(File.read(f)) ]
      end.to_h
    end

    def verify(cert)
      store = OpenSSL::X509::Store.new
      store.add_cert(@cert)
      store.verify(cert)
    end
  end
end
