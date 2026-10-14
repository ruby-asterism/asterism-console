require "test_helper"

# The rooms in the graph (0.2.1, docs/rooms.md): a frame per open room
# holding its nodes, linked to the router by their sessions like any
# client; and the graph without them for the users who are not admins.
class Bridge::GraphRoomsTest < ActiveSupport::TestCase
  ROUTER = "c1df5ae4175c56de269da5532ff80c51"
  CONSOLE = "9fd8e2c3751738c83869543407a78303"
  PAGE_A = "4a1b0c0d0e0f00112233445566778899" # a browser in room 01, through the door
  PAGE_B = "5b2c0c0d0e0f00112233445566778899" # another one
  LEFT = "6c3d0c0d0e0f00112233445566778899"   # a browser left on slot 03 (its room ended)

  def session(zid, port, protocol = "tls")
    { "links" => [ { "dst" => "#{protocol}/[::ffff:192.0.2.10]:#{port}", "src" => "#{protocol}/[::ffff:192.0.2.2]:7448" } ],
      "peer" => zid, "region" => "south:0:client", "shm" => false, "weight" => nil, "whatami" => "client" }
  end

  def admin
    { ROUTER => {
      "router" => { "locators" => [ "tls/192.0.2.2:7448" ], "metadata" => { "name" => "zenohd-cloud" }, "plugins" => {},
                    "sessions" => [ session(CONSOLE, 1), session(PAGE_A, 2), session(PAGE_B, 3), session(LEFT, 4) ],
                    "version" => "v1.10.1", "zid" => ROUTER },
      "linkstate" => {},
      "tokens" => {
        "asterism/console/console" => { "routers" => [], "peers" => [], "clients" => [ CONSOLE ] },
        "room/01/asterism/wasm-a1b2c3/game" => { "routers" => [], "peers" => [], "clients" => [ PAGE_A ] },
        "room/01/asterism/wasm-a1b2c3/game/table" => { "routers" => [], "peers" => [], "clients" => [ PAGE_A ] },
        "room/01/asterism/wasm-d4e5f6/game" => { "routers" => [], "peers" => [], "clients" => [ PAGE_B ] },
        "room/03/asterism/wasm-0a0b0c/game" => { "routers" => [], "peers" => [], "clients" => [ LEFT ] }
      } } }
  end

  ROOMS = %w[room/01/asterism/wasm-a1b2c3/game room/01/asterism/wasm-a1b2c3/game/table
             room/01/asterism/wasm-d4e5f6/game room/03/asterism/wasm-0a0b0c/game
             room/01/asterism/x room/01/asterism/a/b/c/d room/01/other/x/y].freeze
  INFO = [ { "slot" => "01", "name" => "Game night", "uid" => "a1b2c3d4e5f60718", "expires_at" => "2026-10-14T13:00:00Z",
             "app" => "game" },
           { "slot" => "02", "name" => "Empty room", "uid" => "0011223344556677", "expires_at" => "2026-10-14T15:00:00Z" } ].freeze
  REGISTRY = [ { "name" => "wasm-a1b2c3", "kind" => "client", "enabled" => true, "in_acl" => true } ].freeze

  def graph
    Bridge::Graph.build(admin: admin, asterism: %w[asterism/console/console asterism/wasm-a1b2c3/game],
                        self_node: "console", self_zids: [ CONSOLE ], registry: REGISTRY,
                        cloud: "zenohd-cloud", rooms: ROOMS, room_info: INFO).to_h
  end

  def node(g, id) = g["nodes"].find { _1["id"] == id } || flunk("no node #{id}: #{g['nodes'].map { _1['id'] }}")
  def edge?(g, kind, s, t) = g["edges"].any? { _1["kind"] == kind && _1["source"] == s && _1["target"] == t }

  test "a frame per open room, holding its nodes, apps and objects" do
    g = graph
    room = node(g, "room:01")
    assert_equal [ "room", "rooms", "Game night" ], room.values_at("kind", "layer", "label")
    assert_equal({ "slot" => "01", "room" => "01", "open" => true, "name" => "Game night", "uid" => "a1b2c3d4e5f60718",
                   "expires_at" => "2026-10-14T13:00:00Z", "app" => "game" }, room["data"])
    a = node(g, "a_node:room/01/wasm-a1b2c3")
    assert_equal [ "a_node", "wasm-a1b2c3", "room:01", "01" ], [ a["kind"], a["label"], a["parent"], a["data"]["room"] ]
    assert_equal "a_node:room/01/wasm-a1b2c3", node(g, "a_app:room/01/wasm-a1b2c3/game")["parent"]
    obj = node(g, "a_object:room/01/wasm-a1b2c3/game/table")
    assert_equal [ "room/01/wasm-a1b2c3/game/table", "01" ], obj["data"].values_at("path", "room")
    assert_equal "room:01", node(g, "a_node:room/01/wasm-d4e5f6")["parent"]
    assert node(g, "room:02")["data"]["open"], "an open room with nobody in it has its frame"
    left = node(g, "room:03")
    assert_equal [ "room 03", false ], [ left["label"], left["data"]["open"] ]
    refute g["nodes"].any? { _1["id"].start_with?("a_node:room/01/x", "a_node:room/01/a") }, "not protocol 1 keys"
  end

  test "the room's nodes are not the registered side's, and link to the router like other clients" do
    g = graph
    outside = node(g, "a_node:wasm-a1b2c3")
    assert_equal "registered", outside["data"]["registry"]
    inside = node(g, "a_node:room/01/wasm-a1b2c3")
    assert_nil inside["data"]["registry"], "a room's wasm-a1b2c3 is not the registry's"
    assert edge?(g, "carries", "session:#{PAGE_A}", "a_node:room/01/wasm-a1b2c3")
    assert edge?(g, "attach", "a_node:room/01/wasm-a1b2c3", "router:#{ROUTER}")
    assert edge?(g, "attach", "a_node:room/01/wasm-d4e5f6", "router:#{ROUTER}")
    assert_equal "router:#{ROUTER}", inside["data"]["connections"].first["router"]
    refute g["nodes"].any? { _1["kind"] == "others" }, "every session carries a node"
  end

  test "without the rooms: no frame, node, edge or session of a room is left" do
    full = graph
    before = JSON.generate(full)
    g = Bridge::Graph.without_rooms(full)
    ids = g["nodes"].map { _1["id"] }
    refute ids.any? { _1.start_with?("room:") || _1.include?(":room/") }, ids.inspect
    [ PAGE_A, PAGE_B, LEFT ].each { refute_includes ids, "session:#{_1}" }
    assert_includes ids, "session:#{CONSOLE}"
    assert_includes ids, "a_node:wasm-a1b2c3"
    refute g["edges"].any? { _1["source"].include?("room") || _1["target"].include?("room") }
    refute JSON.generate(g).include?("Game night")
    assert_equal before, JSON.generate(full), "the input is not changed"
    assert_same g, Bridge::Graph.without_rooms(g), "nothing to take out"
  end

  test "GraphState: the payload has the rooms only when asked" do
    state = GraphState.new(version: 2, snapshot: JSON.generate(graph))
    assert state.as_payload(rooms: true)["graph"]["nodes"].any? { _1["kind"] == "room" }
    refute state.as_payload["graph"]["nodes"].any? { _1["kind"] == "room" }
  end

  test "Room.for_graph: the open rooms by slot" do
    open = Room.create!(uid: "a1b2c3d4e5f60718", name: "Game night", app: "game", slot: "01", max_connections: 4,
                        expires_at: 2.hours.from_now)
    Room.create!(uid: "b1b2c3d4e5f60718", name: "Closed", slot: "02", max_connections: 4, expires_at: 2.hours.from_now,
                 closed_at: Time.current)
    assert_equal [ { "slot" => "01", "name" => "Game night", "uid" => open.uid,
                     "expires_at" => open.expires_at.utc.iso8601, "app" => "game" } ], Room.for_graph
  end

  test "ConsoleAdmin.rooms_visible?: admins, from the admin networks, with the second factor when it is required" do
    admin = users(:admin)
    assert ConsoleAdmin.rooms_visible?(admin, "192.0.2.10", {})
    refute ConsoleAdmin.rooms_visible?(users(:user), "192.0.2.10", {})
    refute ConsoleAdmin.rooms_visible?(nil, "192.0.2.10", {})
    refute ConsoleAdmin.rooms_visible?(admin, "192.0.2.10", { "CONSOLE_ADMIN_NETS" => "198.51.100.0/24" })
    refute ConsoleAdmin.rooms_visible?(admin, "192.0.2.10", { "CONSOLE_ADMIN_TOTP" => "required" })
  end

  test "Relay::Presence: a room's node is not a registered name" do
    seen = Relay::Presence.seen(graph)
    assert_includes seen, "wasm-a1b2c3" # the registered one, outside the rooms
    refute_includes seen, "wasm-d4e5f6"
  end
end
