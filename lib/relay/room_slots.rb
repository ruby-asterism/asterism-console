# The room slots (G2, docs/rooms.md): room-01 .. room-NN, made once. Each
# is a registry row (marked room_slot, its ACL fixed by Relay::CloudConfig
# to room/<slot>/**) with a certificate whose key is made here, like this
# server's own router and bridge (Relay::LocalIdentity): the door connects
# to the cloud router's mutual-TLS port with it for every room on that
# slot. The files go to the rooms' directory the door reads
# (Relay::Settings.rooms_dir, certs/):
#
#   certs/room-01.key (0600), certs/room-01.pem, certs/ca.pem
#   certs/room-01.tar   the same as one file, with asterism.json and a
#                       zenoh.json5 that sets namespace "room/01": for a
#                       process that hosts a room from inside the server
#                       (CRuby: Asterism.connect(credentials: "room-01.tar",
#                       config: { "namespace" => "room/01" }, ...))
#
# bin/asterism setup makes the missing ones (and those ending within 30
# days); the cloud router lets them in after the next apply.
require "fileutils"
require "json"
require "rubygems/package"
require "stringio"

module Relay
  module RoomSlots
    DAYS = 365

    module_function

    def certs_dir(env = ENV)
      File.join(Settings.rooms_dir(env), "certs")
    end

    # Where a room's host process inside the server reaches the router.
    def inside_router(env = ENV)
      env["ASTERISM_ROOM_HOST_ROUTER"].presence || "tls/zenohd:7448"
    end

    # Makes or renews every slot's certificate. Yields [slot, what happened]
    # for each. Returns the slots in place.
    def ensure!(ca_pem, env: ENV)
      out = certs_dir(env)
      FileUtils.mkdir_p(out)
      Settings.slot_names(env).each do |slot|
        name = Settings.slot_peer_name(slot)
        peer = RelayPeer.find_by(name: name)
        if peer && !peer.room_slot?
          yield slot, "skipped: #{name} is a registry row of its own (not a room slot); rename it" if block_given?
          next
        end
        why = LocalIdentity.stale?(name: name, out: out, ca_pem: ca_pem)
        if why.nil? && File.exist?(File.join(out, "#{name}.tar"))
          yield slot, "in place" if block_given?
          next
        end
        RelayPeer.find_or_create_by!(name: name) do |p|
          p.kind = "client"
          p.room_slot = true
          p.cert_days = DAYS
          p.description = "room slot #{slot} (G2): the door's certificate for the rooms on room/#{slot}"
        end
        record = LocalIdentity.issue(name: name, out: out, days: DAYS, description: "room slot #{slot}")
        write_tar(out, name, slot, record)
        yield slot, "issued serial #{record.serial} until #{record.not_after.utc.to_date} (#{why || 'no .tar'})" if block_given?
      end
    end

    # certs/<name>.tar from the files issue wrote (the format of the
    # console's "Save all (.tar)", which the asterism gem reads).
    def write_tar(out, name, slot, record)
      info = { "format" => 1, "name" => name, "kind" => "client", "router" => inside_router,
               "namespace" => "room/#{slot}", "serial" => record.serial,
               "not_after" => record.not_after.utc.iso8601, "fingerprint" => record.fingerprint }
      zenoh = <<~JSON5
        // zenoh configuration for #{name}, a room slot's certificate: a process
        // inside the server that hosts a room on room/#{slot}. Its keys get the
        // namespace room/#{slot} (zenoh-c), so it sees the room's keys as
        // asterism/... like the browsers in the room.
        {
          mode: "client",
          connect: { endpoints: ["#{inside_router}"] },
          namespace: "room/#{slot}",
          transport: { link: { tls: {
              root_ca_certificate: "ca.pem",
              connect_certificate: "#{name}.pem",
              connect_private_key: "#{name}.key",
              enable_mtls: true,
              close_link_on_expiration: true,
            } } },
        }
      JSON5
      files = { "#{name}.key" => [ File.read(File.join(out, "#{name}.key")), 0o600 ],
                "#{name}.pem" => [ File.read(File.join(out, "#{name}.pem")), 0o644 ],
                "ca.pem" => [ File.read(File.join(out, "ca.pem")), 0o644 ],
                "zenoh.json5" => [ zenoh, 0o644 ],
                "asterism.json" => [ JSON.pretty_generate(info) + "\n", 0o644 ] }
      io = StringIO.new(+"", "wb")
      Gem::Package::TarWriter.new(io) do |tar|
        files.each { |f, (text, mode)| tar.add_file_simple("#{name}/#{f}", mode, text.bytesize) { _1.write(text) } }
      end
      CertAuthority.write(File.join(out, "#{name}.tar"), io.string, 0o600)
    end
  end
end
