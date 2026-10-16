# Issues a certificate for a registered peer over a public key made in the
# admin's browser (Web Crypto, ECDSA P-256): the page sends only the public
# key (SubjectPublicKeyInfo, DER), the signer signs a certificate for it
# (the CA's key is the signer's only), the ledger records the certificate,
# and the page shows the browser's private key with the certificate once.
# The private key never reaches the console: there is no parameter for it,
# and a key that is not a bare P-256 public key is refused.
#
# The console's own identities on a server (the router's and the bridge's
# certificates, whose keys live on that server anyway) are made with
# issue_local: the key is made here and written to a directory the router
# and the bridge read (bin/rails relay:issue_local).
module Relay
  class Issuer
    class Error < StandardError; end

    MAX_SPKI = 512

    # Tests put a stand-in here.
    class << self
      attr_accessor :signer
    end

    def initialize(signer: self.class.signer || SignerClient.from_env(root: Rails.root.to_s),
                   endpoint: ENV["ASTERISM_RELAY_PUBLIC_ENDPOINT"].presence || "tls/localhost:7448")
      @signer = signer
      @endpoint = endpoint
    end

    attr_reader :endpoint

    # spki: the DER (or its base64) of the browser's public key. Returns
    # [RelayCertificate, certificate PEM, CA PEM].
    def issue(peer, spki, by: nil)
      raise Error, "#{peer.name} is disabled" unless peer.enabled?
      pub = self.class.public_key(spki)
      cert, ca = sign_and_check(peer, pub) { |c| c.public_key.to_der == pub.to_der }
      record = RelayCertificate.record!(peer, cert.to_pem, by: by)
      [ record, cert.to_pem, ca.to_pem ]
    end

    # A key made here (for this server's own router and bridge). Returns
    # [RelayCertificate, OpenSSL::PKey, certificate PEM, CA PEM].
    def issue_local(peer, by: nil)
      raise Error, "#{peer.name} is disabled" unless peer.enabled?
      key, csr = CertAuthority.request(peer.name)
      cert, ca = sign_and_check(peer, csr) { |c| c.check_private_key(key) }
      record = RelayCertificate.record!(peer, cert.to_pem, by: by)
      [ record, key, cert.to_pem, ca.to_pem ]
    end

    # A key made here for a name that is not a registry row (the rooms'
    # seats, Relay::RoomCerts): no ledger entry, no DNS names. Returns
    # [OpenSSL::PKey, OpenSSL::X509::Certificate, CA PEM].
    def issue_unlisted(name, days:)
      key, csr = CertAuthority.request(name)
      cert, ca = sign_and_check(Unlisted.new(name, [], [], days), csr) { |c| c.check_private_key(key) }
      [ key, cert, ca.to_pem ]
    end

    Unlisted = Struct.new(:name, :dns_list, :ip_list, :cert_days)

    # A bare ECDSA P-256 public key from SubjectPublicKeyInfo (DER, or
    # base64 of it). Anything else (another curve, RSA, a private key) is
    # refused.
    def self.public_key(spki)
      der = spki.to_s.b
      der = der.unpack1("m") unless der.start_with?("\x30".b)
      raise Error, "the public key is too large" if der.bytesize > MAX_SPKI
      key = OpenSSL::PKey.read(der)
      raise Error, "not an ECDSA P-256 public key" unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == "prime256v1"
      raise Error, "a private key was sent; send the public key only" if key.private?
      key
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      raise Error, "not a public key (SubjectPublicKeyInfo, DER)"
    end

    # The example configuration handed out with a certificate (zenoh.json5
    # in the .tar). For a router: a home router, listening for the boards
    # on the LAN (plain TCP 7447) and connecting out to the cloud router
    # with this certificate, so `zenohd -c zenoh.json5` runs as it is in
    # the directory the .tar makes. For a client: the same connection for
    # any zenoh client (CRuby takes the .tar itself, credentials:). Paths
    # are relative to where the process runs.
    def zenoh_config(peer)
      tls = <<~JSON5.chomp
        transport: { link: { tls: {
            root_ca_certificate: "ca.pem",
            connect_certificate: "#{peer.name}.pem",
            connect_private_key: "#{peer.name}.key",
            enable_mtls: true,
            close_link_on_expiration: true,
          } } },
      JSON5
      if peer.kind == "router"
        <<~JSON5
          // zenoh configuration for #{peer.name}, a home router: the boards on its
          // network connect to it (tcp/7447, no TLS: keep that port inside the LAN),
          // and it connects to the cloud router #{@endpoint} with mutual TLS.
          // Run it where the files are: zenohd -c zenoh.json5
          {
            mode: "router",
            metadata: { name: "#{peer.name}" },
            listen: { endpoints: ["tcp/[::]:7447"] },
            connect: { endpoints: ["#{@endpoint}"] },
            scouting: { multicast: { enabled: false } },
            #{tls}
          }
        JSON5
      else
        <<~JSON5
          // zenoh configuration for #{peer.name} (a client): mutual TLS to the cloud
          // router. Paths are relative to where the process runs. CRuby (the
          // asterism gem) needs none of this: Asterism.connect(credentials: "#{peer.name}.tar", app: ...)
          {
            mode: "client",
            connect: { endpoints: ["#{@endpoint}"] },
            #{tls}
          }
        JSON5
      end
    end

    # asterism.json in the .tar: what the files are for (no secret in it).
    def credentials_info(peer, record, console: nil)
      { "format" => 1, "name" => peer.name, "kind" => peer.kind, "router" => @endpoint,
        "serial" => record.serial, "not_after" => record.not_after.utc.iso8601,
        "fingerprint" => record.fingerprint, "console" => console,
        "issued_at" => Time.now.utc.iso8601 }.compact
    end

    def command(peer)
      if peer.kind == "router"
        "tar xf #{peer.name}.tar && cd #{peer.name} && zenohd -c zenoh.json5"
      else
        "ruby -rasterism -e 'Asterism.connect(credentials: \"#{peer.name}.tar\", app: \"demo\") { |net| p net.nodes }'"
      end
    end

    private

    def sign_and_check(peer, pub_or_csr)
      ans = if pub_or_csr.is_a?(OpenSSL::X509::Request)
        @signer.sign(name: peer.name, csr: pub_or_csr, dns: peer.dns_list, ips: peer.ip_list, days: peer.cert_days)
      else
        @signer.sign(name: peer.name, spki: pub_or_csr, dns: peer.dns_list, ips: peer.ip_list, days: peer.cert_days)
      end
      cert = OpenSSL::X509::Certificate.new(ans.fetch("certificate"))
      cn = cert.subject.to_a.find { _1[0] == "CN" }&.dig(1)
      raise Error, "the signer gave a certificate for #{cn.inspect}" unless cn == peer.name
      raise Error, "the certificate is not for the key given" unless yield(cert)
      ca = OpenSSL::X509::Certificate.new(@signer.ca_pem)
      store = OpenSSL::X509::Store.new
      store.add_cert(ca)
      raise Error, "the certificate does not verify against the signer's CA" unless store.verify(cert)
      [ cert, ca ]
    rescue SignerClient::Error, KeyError, OpenSSL::X509::CertificateError => e
      raise Error, e.message
    end
  end
end
