require "test_helper"
require_relative "../test_helpers/room_test_helper"

class RoomTest < ActiveSupport::TestCase
  include RoomTestHelper

  setup { setup_rooms(slots: 2) }
  teardown { teardown_rooms }

  test "the slots made by setup: rows marked room_slot, in the ACL, their files and a .tar with the namespace" do
    peers = RelayPeer.where(room_slot: true).order(:name)
    assert_equal %w[room-01 room-02], peers.map(&:name)
    assert peers.all?(&:in_acl?)
    assert_equal({ "name" => "room-01", "kind" => "client", "in_acl" => true, "room_slot" => "01" }, peers.first.to_config)
    dir = Relay::RoomSlots.certs_dir
    %w[room-01.key room-01.pem ca.pem room-01.tar].each { assert File.exist?(File.join(dir, _1)), _1 }
    assert_equal "600", format("%o", File.stat(File.join(dir, "room-01.key")).mode & 0o777)
    files = {}
    Gem::Package::TarReader.new(File.open(File.join(dir, "room-01.tar"))) { |t| t.each { files[File.basename(_1.full_name)] = _1.read } }
    assert_equal %w[asterism.json ca.pem room-01.key room-01.pem zenoh.json5], files.keys.sort
    assert_equal "room/01", JSON.parse(files["asterism.json"])["namespace"]
    assert_includes files["zenoh.json5"], 'namespace: "room/01"'
    assert_equal %w[01 02], Room.ready_slots
    seen = []
    Relay::RoomSlots.ensure!(@signer.ca_pem) { |slot, what| seen << [ slot, what ] }
    assert_equal [ [ "01", "in place" ], [ "02", "in place" ] ], seen, "a second run changes nothing"
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
    assert_equal({ room.slot => { "room" => room.uid, "until" => room.expires_at.to_i, "max" => 8, "app" => "" } },
                 data["slots"])
    assert_equal [ other.uid ], data["revoked"].map { _1["room"] }
    assert_equal [ @signer.kid ], data["keys"].map { _1["kid"] }
    refute_includes File.read(Relay::RoomFiles.path), token
    assert_raises(ArgumentError) { other.mint_key! }
  end
end
