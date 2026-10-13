# This server's own identities: the cloud router's certificate and the
# bridge's (the console's client), whose keys live on this server anyway.
# The key is made here and written with the certificate and the CA to a
# directory the router and the bridge read (deploy/vps: the certs volume).
# Used by bin/rails relay:issue_local and bin/asterism setup.
require "fileutils"

module Relay
  module LocalIdentity
    module_function

    # Issues name (a registry row made or updated here) into out: <name>.key
    # (0600), <name>.pem, ca.pem. Returns the RelayCertificate.
    def issue(name:, out:, kind: nil, dns: nil, ips: nil, rw: nil, admin_space: nil, days: 365,
              description: "this server's own")
      peer = RelayPeer.find_or_initialize_by(name: name)
      if peer.new_record?
        peer.kind = kind || (name.start_with?("zenohd-") ? "router" : "client")
        peer.description = description
        peer.cert_days = days
      end
      peer.dns_names = Array(dns).join("\n") if dns
      peer.ip_addresses = Array(ips).join("\n") if ips
      peer.rw_keys = Array(rw).join("\n") if rw
      peer.admin_space = admin_space unless admin_space.nil?
      peer.save!
      record, key, cert_pem, ca_pem = Relay::Issuer.new.issue_local(peer)
      FileUtils.mkdir_p(out)
      CertAuthority.write(File.join(out, "#{name}.key"), key.private_to_pem, 0o600)
      CertAuthority.write(File.join(out, "#{name}.pem"), cert_pem, 0o644)
      CertAuthority.write(File.join(out, "ca.pem"), ca_pem, 0o644)
      record
    end

    # Whether out holds a certificate for name that the CA (PEM) verifies,
    # valid for at least min_days more, naming every DNS name given, with
    # its key. Returns nil when it does, else why not (a String).
    def stale?(name:, out:, ca_pem:, dns: [], min_days: 30)
      cert_file = File.join(out, "#{name}.pem")
      key_file = File.join(out, "#{name}.key")
      return "no #{cert_file}" unless File.exist?(cert_file) && File.exist?(key_file)
      cert = OpenSSL::X509::Certificate.new(File.read(cert_file))
      store = OpenSSL::X509::Store.new
      store.add_cert(OpenSSL::X509::Certificate.new(ca_pem))
      return "not signed by the signer's CA" unless store.verify(cert)
      return "its key does not match" unless cert.check_private_key(OpenSSL::PKey.read(File.read(key_file)))
      return "it ends #{cert.not_after.utc.to_date}" if cert.not_after < Time.now + min_days * 86_400
      san = cert.extensions.find { _1.oid == "subjectAltName" }&.value.to_s
      missing = Array(dns).reject { san.include?("DNS:#{_1}") }
      return "it does not name #{missing.join(', ')}" if missing.any?
      nil
    rescue OpenSSL::OpenSSLError, SystemCallError => e
      "unreadable (#{e.message})"
    end
  end
end
