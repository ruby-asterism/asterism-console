# The relay registry from the command line.
#
#   bin/rails relay:import [CERTS=storage/relay/certs]   # certificates made before the signer
#   bin/rails relay:generate                             # write the cloud router's file (no restart)
#   bin/rails relay:show                                 # print what would be written
#   bin/rails relay:issue_local NAME=zenohd-cloud [KIND=router] [DNS=a,b] [IPS=..] [OUT=/certs]
#                               [RW=asterism/**] [ADMIN_SPACE=1] [DAYS=365]
#                                     # this server's own router / bridge: key made here
namespace :relay do
  desc "Issue a certificate for this server's own router or bridge (the key is written to OUT, 0600)"
  task issue_local: :environment do
    name = ENV.fetch("NAME")
    out = File.expand_path(ENV.fetch("OUT", Relay::Settings.certs_dir), Rails.root)
    record = Relay::LocalIdentity.issue(
      name: name, out: out, kind: ENV["KIND"], days: Integer(ENV.fetch("DAYS", 365)),
      description: "this server's own (relay:issue_local)",
      dns: ENV["DNS"]&.split(","), ips: ENV["IPS"]&.split(","), rw: ENV["RW"]&.split(","),
      admin_space: ENV.key?("ADMIN_SPACE") ? ENV["ADMIN_SPACE"] == "1" : nil
    )
    puts "issued #{name} serial #{record.serial} until #{record.not_after.utc.strftime('%Y-%m-%d')} -> #{out}"
  end

  desc "Record certificates made before the signer (script/relay_certs) in the ledger"
  task import: :environment do
    dir = File.expand_path(ENV.fetch("CERTS", "storage/relay/certs"), Rails.root)
    ca_file = File.join(dir, "ca.pem")
    store = OpenSSL::X509::Store.new
    store.add_cert(OpenSSL::X509::Certificate.new(File.read(ca_file))) if File.exist?(ca_file)
    Dir[File.join(dir, "*.pem")].sort.each do |f|
      name = File.basename(f, ".pem")
      next if name == "ca"
      cert = OpenSSL::X509::Certificate.new(File.read(f))
      if File.exist?(ca_file) && !store.verify(cert)
        puts "skipped #{name}: not signed by #{ca_file}"
        next
      end
      peer = RelayPeer.find_or_create_by!(name: name) do |p|
        p.kind = name.start_with?("zenohd-") ? "router" : "client"
        p.description = "imported"
      end
      serial = cert.serial.to_s(16).downcase
      if RelayCertificate.exists?(serial: serial)
        puts "kept    #{name} #{serial}"
      else
        RelayCertificate.record!(peer, cert.to_pem, source: "imported")
        puts "imported #{name} #{serial} until #{cert.not_after.utc.strftime('%Y-%m-%d')}"
      end
    end
  end

  desc "Write the cloud router's configuration from the registry (no restart)"
  task generate: :environment do
    applier = Relay::Applier.new
    config = Relay::Applier.config_for
    applier.write(config.text(by: "bin/rails relay:generate"))
    puts "wrote #{Relay::Settings.config_path} (digest #{config.digest}; ACL: #{config.subject_names.join(' ')})"
  end

  desc "Print the configuration the registry makes"
  task show: :environment do
    puts Relay::Applier.config_for.text
  end
end
