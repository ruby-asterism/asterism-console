require "test_helper"
require_relative "../test_helpers/room_test_helper"

class RoomTest < ActiveSupport::TestCase
  include RoomTestHelper

  setup { setup_rooms(slots: 2) }
  teardown { teardown_rooms }

  test "the seats made by setup (0.3.1): files in the rooms' store, no registry row, the ACL from the store" do
    assert_equal 0, RelayPeer.where("name LIKE 'room-%'").count, "not registry rows"
    dir = Relay::RoomCerts.certs_dir
    %w[room-01-s01 room-01-s02 room-02-s01 room-02-s02].each do |name|
      assert File.exist?(File.join(dir, "#{name}.pem")), name
      assert_equal "600", format("%o", File.stat(File.join(dir, "#{name}.key")).mode & 0o777)
      refute File.exist?(File.join(dir, "#{name}.tar")), "only the door uses a seat's certificate"
    end
    assert File.exist?(File.join(dir, "ca.pem"))
    refute File.exist?(File.join(dir, "room-01.pem")), "no certificate of a slot's own"
    assert_equal({ "01" => %w[01 02], "02" => %w[01 02] }, Relay::RoomCerts.seats)
    assert_equal({ "count" => 4, "good" => 4 }, Relay::RoomCerts.summary.slice("count", "good"))
    assert_equal %w[01 02], Room.ready_slots
    seen = []
    Relay::RoomCerts.ensure!(@signer.ca_pem) { |slot, what| seen << [ slot, what ] }
    assert_equal [ [ "room-01 seats", "2 seats: 2 in place" ], [ "room-02 seats", "2 seats: 2 in place" ] ], seen,
                 "a second run changes nothing"
    names = Relay::Applier.config_for.subject_names
    assert_equal %w[room-01-s01 room-01-s02 room-02-s01 room-02-s02], names.grep(/\Aroom-/)
  end

  test "a seat's certificate missing, ended or for another name is left out; setup makes it again" do
    dir = Relay::RoomCerts.certs_dir
    File.delete(File.join(dir, "room-01-s02.pem"))
    FileUtils.cp(File.join(dir, "room-02-s01.pem"), File.join(dir, "room-02-s02.pem"))
    assert_equal({ "01" => %w[01], "02" => %w[01] }, Relay::RoomCerts.seats)
    refute Relay::RoomCerts.seats(at: Time.now + 400 * 86_400).any?, "ended"
    seen = []
    Relay::RoomCerts.ensure!(@signer.ca_pem) { |slot, what| seen << what }
    assert_equal [ "2 seats: 1 in place, 1 issued", "2 seats: 1 in place, 1 issued" ], seen
    assert_equal({ "01" => %w[01 02], "02" => %w[01 02] }, Relay::RoomCerts.seats)
  end

  test "the slots' own files of before 0.3.1 are removed; a seat's .tar for an admin's test" do
    dir = Relay::RoomCerts.certs_dir
    %w[room-01.key room-01.pem room-01.tar room-02.pem].each { File.write(File.join(dir, _1), "old") }
    assert_equal %w[room-01.key room-01.pem room-01.tar room-02.pem], Relay::RoomCerts.prune_slot_files!
    assert_equal [], Relay::RoomCerts.prune_slot_files!
    assert File.exist?(File.join(dir, "room-01-s01.pem")), "the seats stay"
    tar = Relay::RoomCerts.tar("01", "02")
    files = {}
    Gem::Package::TarReader.new(StringIO.new(tar)) { |t| t.each { files[_1.full_name] = [ _1.read, _1.header.mode ] } }
    assert_equal %w[wasm-0102/asterism.json wasm-0102/ca.pem wasm-0102/wasm-0102.key wasm-0102/wasm-0102.pem wasm-0102/zenoh.json5],
                 files.keys.sort
    assert_equal 0o600, files["wasm-0102/wasm-0102.key"][1]
    info = JSON.parse(files["wasm-0102/asterism.json"][0])
    assert_equal [ "wasm-0102", "room-01-s02", "room/01", "tls/zenohd:7448" ], info.values_at("name", "certificate", "namespace", "router")
    assert_includes files["wasm-0102/zenoh.json5"][0], 'namespace: "room/01"'
    cert = OpenSSL::X509::Certificate.new(files["wasm-0102/wasm-0102.pem"][0])
    assert cert.check_private_key(OpenSSL::PKey.read(files["wasm-0102/wasm-0102.key"][0]))
    other = Gem::Package::TarReader.new(StringIO.new(Relay::RoomCerts.tar("02", "01", router: "tls/example:7448")))
    assert_equal "tls/example:7448", JSON.parse(other.find { _1.full_name.end_with?("asterism.json") }.read)["router"]
    assert_raises(ArgumentError) { Relay::RoomCerts.tar("01", "03") }
    assert_raises(ArgumentError) { Relay::RoomCerts.tar("03", "01") }
  end

  test "the registry keeps the rooms' names for them" do
    peer = RelayPeer.new(name: "room-01-s03", kind: "client", cert_days: 90)
    refute peer.valid?
    assert_match(/kept for the rooms/, peer.errors.full_messages.join)
    refute RelayPeer.new(name: "room-07", kind: "client", cert_days: 90).valid?
    assert RelayPeer.new(name: "room-host", kind: "client", cert_days: 90).valid?
  end

  test "rooms take free slots; full when both are open; a closed room frees its slot" do
    a = Room.open!(name: "A", app: "/app/test/othello.app.rb", hours: 3, max_connections: nil, by: users(:admin))
    b = Room.open!(name: "B", app: nil, hours: "", max_connections: 4, by: users(:admin))
    assert_equal %w[01 02], [ a.slot, b.slot ].sort
    assert_equal [ 16, 4 ], [ a.max_connections, b.max_connections ]
    assert_in_delta 3 * 3600, b.expires_at - Time.current, 5, "3 hours unless said"
    assert_raises(Room::Full) { Room.open!(name: "C", app: nil, hours: 1, max_connections: 2, by: nil) }
    a.close!(users(:admin))
    assert_equal "closed", a.status
    c = Room.open!(name: "C", app: nil, hours: 1, max_connections: 2, by: nil)
    assert_equal a.slot, c.slot
    assert_raises(ArgumentError) { Room.open!(name: "D", app: nil, hours: 25, max_connections: 2, by: nil) }
  end

  test "a key from the signer, and the door's file" do
    room = Room.open!(name: "A", app: nil, hours: 2, max_connections: 8, by: nil)
    token = room.mint_key!
    pub = { @signer.kid => OpenSSL::PKey.read(@signer.room_key.public_to_pem) }
    claims = Relay::RoomToken.verify(token, pub)
    assert_equal [ room.uid, room.slot, room.expires_at.to_i, 8 ], claims.values_at("room", "slot", "exp", "max")
    assert_equal 1, room.reload.links_made
    other = Room.open!(name: "B", app: nil, hours: 2, max_connections: 8, by: nil)
    other.close!(nil)
    Relay::RoomFiles.write!
    data = JSON.parse(File.read(Relay::RoomFiles.path))
    assert_equal({ room.slot => { "room" => room.uid, "until" => room.expires_at.to_i, "max" => 8, "app" => "",
                                  "seats" => 2 } },
                 data["slots"])
    assert_equal [ "wasm-", [ "games" ] ], data.values_at("seat_node_prefix", "hosts")
    assert_equal [ other.uid ], data["revoked"].map { _1["room"] }
    assert_equal [ @signer.kid ], data["keys"].map { _1["kid"] }
    refute_includes File.read(Relay::RoomFiles.path), token
    assert_raises(ArgumentError) { other.mint_key! }
  end

  test "the door's file says which seats the router lets in (0.3.0)" do
    room = Room.open!(name: "A", app: nil, hours: 2, max_connections: 8, by: nil)
    Relay::RoomFiles.write!
    assert_equal({ "01" => 2, "02" => 2 }, Relay::RoomFiles.seats_in_config)
    assert_equal 2, JSON.parse(File.read(Relay::RoomFiles.path)).dig("slots", room.slot, "seats")
    sub = Relay::Applier.config_for.access_control["subjects"].select { _1["cert_common_names"] == [ "room-01-s02" ] }
    assert_equal 2, sub.size, "two subjects for the one certificate"
    File.delete(File.join(Relay::RoomCerts.certs_dir, "room-01-s01.pem"))
    write_router_config
    assert_equal({ "02" => 2 }, Relay::RoomFiles.seats_in_config, "seats up to the first one left out")
    assert_equal [ "02" ], Room.ready_slots, "a slot without seats takes no room"
  end

  test "before an apply no slot is ready" do
    File.delete(Relay::Settings.config_path)
    assert_equal({}, Relay::RoomFiles.seats_in_config)
    assert_equal [], Room.ready_slots
    assert_raises(Room::Full) { Room.open!(name: "A", app: nil, hours: 1, max_connections: 2, by: nil) }
  end
end
