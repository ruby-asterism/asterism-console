# Issues a certificate for a registered peer: makes the key and a request
# here, has the signer sign it (the CA's key is the signer's only), records
# the certificate in the ledger and returns a tar of the key, the
# certificate, the CA and an example configuration. The key is in that tar
# only: it is not stored, so the download is the one chance to take it.
require "rubygems/package"
require "stringio"

module Relay
  class Issuer
    class Error < StandardError; end

    # Tests put a stand-in here.
    class << self
      attr_accessor :signer
    end

    def initialize(signer: self.class.signer || SignerClient.from_env(root: Rails.root.to_s),
                   endpoint: ENV["ASTERISM_RELAY_PUBLIC_ENDPOINT"].presence || "tls/localhost:7448")
      @signer = signer
      @endpoint = endpoint
    end

    # Returns [RelayCertificate, tar (String), file name].
    def issue(peer, by: nil)
      raise Error, "#{peer.name} is disabled" unless peer.enabled?
      key, csr = CertAuthority.request(peer.name)
      ans = @signer.sign(name: peer.name, csr: csr, dns: peer.dns_list, ips: peer.ip_list, days: peer.cert_days)
      cert = OpenSSL::X509::Certificate.new(ans.fetch("certificate"))
      cn = cert.subject.to_a.find { _1[0] == "CN" }&.dig(1)
      raise Error, "the signer gave a certificate for #{cn.inspect}" unless cn == peer.name
      raise Error, "the certificate is not for the key made here" unless cert.check_private_key(key)
      ca = OpenSSL::X509::Certificate.new(@signer.ca_pem)
      store = OpenSSL::X509::Store.new
      store.add_cert(ca)
      raise Error, "the certificate does not verify against the signer's CA" unless store.verify(cert)
      record = RelayCertificate.record!(peer, cert.to_pem, by: by)
      [ record, bundle(peer, key, cert, ca), "#{peer.name}-#{record.serial[0, 8]}.tar" ]
    rescue SignerClient::Error, KeyError, OpenSSL::X509::CertificateError => e
      raise Error, e.message
    end

    def bundle(peer, key, cert, ca)
      n = peer.name
      files = {
        "#{n}/#{n}.key" => [ key.private_to_pem, 0o600 ],
        "#{n}/#{n}.pem" => [ cert.to_pem, 0o644 ],
        "#{n}/ca.pem" => [ ca.to_pem, 0o644 ],
        "#{n}/zenoh.json5" => [ zenoh_config(peer), 0o644 ],
        "#{n}/README.txt" => [ readme(peer, cert), 0o644 ]
      }
      io = StringIO.new(+"", "wb")
      Gem::Package::TarWriter.new(io) do |tar|
        tar.mkdir(n, 0o700)
        files.each { |path, (text, mode)| tar.add_file_simple(path, mode, text.bytesize) { _1.write(text) } }
      end
      io.string
    end

    def zenoh_config(peer)
      <<~JSON5
        // zenoh configuration for #{peer.name} (#{peer.kind}): mutual TLS to the cloud router.
        // Paths are relative to where the process runs; adjust them.
        {
          mode: "#{peer.kind == 'router' ? 'router' : 'client'}",
          connect: { endpoints: ["#{@endpoint}"] },
          transport: { link: { tls: {
            root_ca_certificate: "ca.pem",
            connect_certificate: "#{peer.name}.pem",
            connect_private_key: "#{peer.name}.key",
            enable_mtls: true,
            close_link_on_expiration: true,
          } } },
        }
      JSON5
    end

    def readme(peer, cert)
      <<~TEXT
        #{peer.name}: a certificate for the relay's cloud router (#{@endpoint}).

        #{peer.name}.key   the private key. It exists only in this download: keep it, 0600.
        #{peer.name}.pem   the certificate (CN=#{peer.name}, serial #{cert.serial.to_s(16).downcase},
                      until #{cert.not_after.utc.strftime('%Y-%m-%d %H:%M UTC')})
        ca.pem        the relay CA (to check the router's certificate)
        zenoh.json5   an example configuration

        A CRuby Asterism node (asterism's examples/node.rb) with this name:

          ruby examples/node.rb --router #{@endpoint} --node #{peer.name} \\
            --ca ca.pem --cert #{peer.name}.pem --key #{peer.name}.key

        The cloud router lets it in once the registry is applied (Relay > Apply).
      TEXT
    end
  end
end
