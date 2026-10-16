# The rooms' certificates (G2, docs/rooms.md "Seats"): each room slot
# (ASTERISM_ROOM_SLOTS: 01 .. 08) has ASTERISM_ROOM_SEATS (16) seats, and
# each seat a certificate, room-01-s01 .. room-08-s16, whose key is made on
# this server by bin/asterism setup, like the router's and the bridge's
# (Relay::LocalIdentity). They belong to the rooms, not to the relay
# registry (0.3.1): their store is the rooms' directory, which the door
# reads (Relay::Settings.rooms_dir, certs/):
#
#   certs/room-01-s03.key (0600), certs/room-01-s03.pem, certs/ca.pem
#
# The cloud router's ACL (Relay::CloudConfig, from Relay::Applier) has a
# seat when its slot and seat are in the settings and its certificate here
# is good now; a seat's rules are fixed: its slot's key space to read, its
# node ID (wasm-0103) to write under and to call as. No ledger entry is
# kept for a seat: the files are the record.
#
# setup makes the missing ones (and those ending within 30 days); the cloud
# router lets them in after the next apply (setup --from-update restarts
# it). Before 0.3.1 each slot had a certificate of its own too (room-01,
# with a .tar) for the pages from before the seats and for an admin's
# tests; setup removes those files (prune_slot_files!). An admin's test in
# a room uses a seat's certificate instead (tar: bin/asterism room-seat).
require "fileutils"
require "json"
require "openssl"
require "rubygems/package"
require "stringio"

module Relay
  module RoomCerts
    DAYS = 365
    SLOT_FILE = /\Aroom-[0-9]{2}\.(key|pem|tar)\z/

    # path => [mtime, common name, not_before, not_after]: a certificate is
    # read once (the relay pages ask for the ACL often).
    CACHE = {}
    CACHE_LOCK = Mutex.new

    module_function

    def certs_dir(env = ENV)
      File.join(Settings.rooms_dir(env), "certs")
    end

    # Where a process inside the server reaches the router (an admin's test).
    def inside_router(env = ENV)
      env["ASTERISM_ROOM_HOST_ROUTER"].presence || "tls/zenohd:7448"
    end

    # {slot => [seat, ...]} of the seats whose certificates are good at at,
    # from the settings' slots and seats; slots with none are left out.
    def seats(env = ENV, at: Time.now)
      dir = certs_dir(env)
      Settings.slot_names(env).to_h do |slot|
        [ slot, Settings.seat_names(env).select { good?(dir, Settings.seat_peer_name(slot, _1), at) } ]
      end.reject { _2.empty? }
    end

    # The seats' certificates in the store: {"count", "good", "until" (the
    # first to end)} for the rooms' page.
    def summary(env = ENV, at: Time.now)
      dir = certs_dir(env)
      infos = Settings.slot_names(env).product(Settings.seat_names(env))
                      .map { info(dir, Settings.seat_peer_name(*_1)) }.compact
      good = infos.select { |_, nb, na| nb <= at && na > at }
      { "count" => infos.size, "good" => good.size, "until" => good.map(&:last).min }
    end

    def good?(dir, name, at)
      cn, not_before, not_after = info(dir, name)
      cn == name && not_before <= at && not_after > at && File.exist?(File.join(dir, "#{name}.key"))
    end

    # [common name, not_before, not_after] of certs/<name>.pem, or nil.
    def info(dir, name)
      path = File.join(dir, "#{name}.pem")
      mtime = File.mtime(path)
      CACHE_LOCK.synchronize do
        hit = CACHE[path]
        return hit.drop(1) if hit && hit[0] == mtime
      end
      cert = OpenSSL::X509::Certificate.new(File.read(path))
      cn = cert.subject.to_a.find { _1[0] == "CN" }&.dig(1)
      row = [ cn, cert.not_before, cert.not_after ]
      CACHE_LOCK.synchronize { CACHE[path] = [ mtime, *row ] }
      row
    rescue SystemCallError, OpenSSL::X509::CertificateError
      nil
    end

    # Makes or renews every seat's certificate. Yields ["room-01 seats",
    # what happened] once for each slot.
    def ensure!(ca_pem, env: ENV, issuer: Issuer.new)
      out = certs_dir(env)
      FileUtils.mkdir_p(out)
      CertAuthority.write(File.join(out, "ca.pem"), ca_pem, 0o644)
      Settings.slot_names(env).each do |slot|
        results = Settings.seat_names(env).map { ensure_one(Settings.seat_peer_name(slot, _1), out, ca_pem, issuer) }
        yield "room-#{slot} seats", seat_summary(results) if block_given?
      end
    end

    # One certificate in place: "in place" or "issued ... (why)".
    def ensure_one(name, out, ca_pem, issuer)
      why = LocalIdentity.stale?(name: name, out: out, ca_pem: ca_pem) or return "in place"
      key, cert, = issuer.issue_unlisted(name, days: DAYS)
      CertAuthority.write(File.join(out, "#{name}.key"), key.private_to_pem, 0o600)
      CertAuthority.write(File.join(out, "#{name}.pem"), cert.to_pem, 0o644)
      "issued serial #{cert.serial.to_s(16).downcase} until #{cert.not_after.utc.to_date} (#{why})"
    end

    def seat_summary(results)
      issued = results.count { _1.start_with?("issued") }
      parts = [ "#{results.size - issued} in place" ]
      parts << "#{issued} issued" if issued.positive?
      "#{results.size} seats: #{parts.join(', ')}"
    end

    # Removes the slots' own certificates of a console before 0.3.1
    # (room-01.key, .pem, .tar). Returns the names removed.
    def prune_slot_files!(env = ENV)
      dir = certs_dir(env)
      return [] unless File.directory?(dir)
      Dir.children(dir).grep(SLOT_FILE).sort.each { File.delete(File.join(dir, _1)) }
    end

    # A seat's certificate as a credentials file (the console's .tar, which
    # the asterism gem reads), for an admin's test in a room from inside the
    # server: the files are named after the seat's node ID (wasm-0116), so
    # Asterism.connect(credentials:) takes it as the node ID; zenoh.json5
    # sets the namespace room/<slot>. Raises ArgumentError for a seat that
    # is not in the store.
    def tar(slot, seat, env: ENV, router: inside_router(env))
      name = Settings.seat_peer_name(slot, seat)
      dir = certs_dir(env)
      raise ArgumentError, "no good certificate for #{name} in #{dir} (bin/asterism setup)" unless
        Settings.slot_names(env).include?(slot) && Settings.seat_names(env).include?(seat) && good?(dir, name, Time.now)
      node = Settings.seat_node(slot, seat, Settings.browser_node_prefix(env))
      cert = OpenSSL::X509::Certificate.new(File.read(File.join(dir, "#{name}.pem")))
      info = { "format" => 1, "name" => node, "certificate" => name, "kind" => "client", "router" => router,
               "namespace" => "room/#{slot}", "serial" => cert.serial.to_s(16).downcase,
               "not_after" => cert.not_after.utc.iso8601,
               "fingerprint" => CertAuthority.fingerprint(cert) }
      zenoh = <<~JSON5
        // zenoh configuration for #{node}, seat #{seat} of room slot #{slot}
        // (certificate #{name}): an admin's test in the room on that slot. Its
        // keys get the namespace room/#{slot}, so it sees the room's keys as
        // asterism/... like the browsers in the room.
        {
          mode: "client",
          connect: { endpoints: ["#{router}"] },
          namespace: "room/#{slot}",
          transport: { link: { tls: {
              root_ca_certificate: "ca.pem",
              connect_certificate: "#{node}.pem",
              connect_private_key: "#{node}.key",
              enable_mtls: true,
              close_link_on_expiration: true,
            } } },
        }
      JSON5
      files = { "#{node}.key" => [ File.read(File.join(dir, "#{name}.key")), 0o600 ],
                "#{node}.pem" => [ cert.to_pem, 0o644 ],
                "ca.pem" => [ File.read(File.join(dir, "ca.pem")), 0o644 ],
                "zenoh.json5" => [ zenoh, 0o644 ],
                "asterism.json" => [ JSON.pretty_generate(info) + "\n", 0o644 ] }
      io = StringIO.new(+"", "wb")
      Gem::Package::TarWriter.new(io) do |t|
        files.each { |f, (text, mode)| t.add_file_simple("#{node}/#{f}", mode, text.bytesize) { _1.write(text) } }
      end
      io.string
    end
  end
end
