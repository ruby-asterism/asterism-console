require "test_helper"
require "asterism"

# Bridge::AppProfiles (protocol 2): which applications to ask, answers and
# the puts on @status and @pubs, the reading of the asterism gem's checks,
# the declarations the recorder takes, and the graph's data on the apps
# (nothing drawn changes).
class Bridge::AppProfilesTest < ActiveSupport::TestCase
  ST = { "mahjong1" => { "st" => "play", "members" => 4, "humans" => 1, "cpus" => 3, "away" => 0 } }.freeze
  PUBS = { "imu" => { "t" => 2, "u" => "m/s2", "d" => "acceleration", "ts" => true },
           "board1/strokes" => { "t" => "mygame/board.strokes" },
           "camera" => { "t" => 4, "e" => 17 } }.freeze
  TYPES = { "mygame/board.strokes" => { "f" => [ [ "pts", "mygame/point[]" ], [ "color", "str" ] ] },
            "mygame/point" => { "f" => [ [ "x", "int" ], [ "y", "int" ] ], "d" => "a point" },
            "mygame/other" => { "f" => [ [ "v", "number" ] ] } }.freeze

  def pl(v) = MessagePack.pack(v)

  test "each application is asked once, again after it leaves and comes back" do
    s = Bridge::AppProfiles.new
    assert_equal %w[games/games linux/demo], s.due(%w[games/games linux/demo])
    assert_equal [], s.due(%w[games/games linux/demo]), "being asked"
    refute s.answered("linux/demo", nil), "no answer: nothing to show"
    assert s.answered("games/games", { "status" => ST })
    assert_equal [], s.due(%w[games/games linux/demo])
    assert_equal({ "games/games" => { "status" => ST } }, s.to_graph)
    assert_equal [], s.due(%w[linux/demo]), "the host left"
    assert_equal({}, s.to_graph)
    assert_equal %w[games/games], s.due(%w[games/games linux/demo]), "back"
  end

  test "the answer's parts are cleaned with the asterism gem's checks" do
    s = Bridge::AppProfiles.new
    s.due(%w[linux/demo])
    assert s.answered("linux/demo", { "status" => { "ok" => 1, 2 => 3 }, "pubs" => PUBS.merge("bad" => 3, "x" => { "t" => 0 }),
                                      "types" => TYPES.merge("broken" => { "f" => 1 }, "numbered" => { "f" => [ [ "v", 1 ] ] }),
                                      "other" => 1 })
    got = s.to_graph["linux/demo"]
    assert_equal({ "ok" => 1 }, got["status"])
    assert_equal PUBS.merge("x" => {}), got["pubs"], "a declaration with a bad type is kept without it"
    assert_equal TYPES, got["types"], "a field type by number is not taken (names only)"
    refute s.answered("linux/demo", { "status" => { "ok" => 1 }, "pubs" => PUBS.merge("bad" => 3, "x" => { "t" => 0 }),
                                      "types" => TYPES }), "the same: no change"
    assert s.answered("linux/demo", {}), "answered without anything"
    assert_equal({}, s.to_graph)
  end

  test "puts on @status and @pubs replace those parts; a type not known asks again" do
    s = Bridge::AppProfiles.new
    s.due(%w[linux/demo])
    s.answered("linux/demo", { "status" => ST })
    other = { "mahjong1" => ST["mahjong1"].merge("humans" => 2) }
    assert s.told_status("linux/demo", other)
    refute s.told_status("linux/demo", other)
    assert_equal [ true, false ], s.told_pubs("linux/demo", { "imu" => PUBS["imu"] })
    assert_equal [ false, false ], s.told_pubs("linux/demo", { "imu" => PUBS["imu"] })
    assert_equal [ true, true ], s.told_pubs("linux/demo", PUBS), "board1/strokes names mygame/board.strokes"
    assert s.ask_again("linux/demo")
    refute s.ask_again("linux/demo"), "already being asked"
    s.answered("linux/demo", { "status" => other, "pubs" => PUBS, "types" => TYPES })
    assert_equal [ false, false ], s.told_pubs("linux/demo", PUBS)
    assert_equal [ true, false ], s.told_pubs("linux/demo", {}), "all withdrawn"
    refute s.to_graph["linux/demo"].key?("pubs")
    assert_equal 2, s.to_graph["linux/demo"]["status"]["mahjong1"]["humans"]
  end

  test "the readings of the puts" do
    assert_equal [ "games/games", ST ], Bridge::AppProfiles.parse_status("asterism/games/games/@status", pl(ST))
    assert_nil Bridge::AppProfiles.parse_status("asterism/a/b/@status", pl([ 1 ]))
    assert_nil Bridge::AppProfiles.parse_status("asterism/a/b/@status", pl({ "big" => "x" * 1100 }))
    assert_nil Bridge::AppProfiles.parse_status("asterism/a/@profile", pl(ST))
    assert_nil Bridge::AppProfiles.parse_status("asterism/a/b/@status", "\xc1")
    assert_equal [ "linux/demo", PUBS ], Bridge::AppProfiles.parse_pubs("asterism/linux/demo/@pubs", pl(PUBS))
    assert_equal [ "linux/demo", {} ], Bridge::AppProfiles.parse_pubs("asterism/linux/demo/@pubs", pl({}))
    assert_nil Bridge::AppProfiles.parse_pubs("asterism/linux/demo/@pubs", pl([ 1 ]))
    assert_nil Bridge::AppProfiles.parse_pubs("asterism/linux/demo/@status", pl(PUBS))
  end

  test "a data key's declaration and the definitions its type needs" do
    s = Bridge::AppProfiles.new
    s.due(%w[linux/demo])
    s.answered("linux/demo", { "pubs" => PUBS, "types" => TYPES })
    decl, types = s.topic("asterism/linux/demo/board1/strokes")
    assert_equal({ "t" => "mygame/board.strokes" }, decl)
    assert_equal %w[mygame/board.strokes mygame/point], types.keys.sort, "not mygame/other"
    assert_equal [ PUBS["imu"], {} ], s.topic("asterism/linux/demo/imu")
    assert_nil s.topic("asterism/linux/demo/nothing")
    assert_nil s.topic("asterism/linux/other/imu")
    assert_nil s.topic("linux/demo/imu")
  end

  test "the graph puts the parts on the app, and only there" do
    g = Bridge::Graph.build(asterism: %w[asterism/games/games asterism/games/games/mahjong1 asterism/linux/demo],
                            app_profiles: { "games/games" => { "status" => ST },
                                            "linux/demo" => { "pubs" => PUBS, "types" => TYPES },
                                            "gone/app" => { "status" => { "x" => 1 } } }).to_h
    by_id = g["nodes"].to_h { [ _1["id"], _1 ] }
    assert_equal ST, by_id["a_app:games/games"]["data"]["status"]
    refute by_id["a_app:games/games"]["data"].key?("pubs")
    demo = by_id["a_app:linux/demo"]["data"]
    refute demo.key?("status")
    assert_equal [ { "name" => "board1/strokes", "type" => "mygame/board.strokes" },
                   { "name" => "camera", "type" => "image", "encoding" => "image/jpeg" },
                   { "name" => "imu", "type" => "vector3", "unit" => "m/s2", "desc" => "acceleration", "ts" => true } ],
                 demo["pubs"]
    assert_equal TYPES, demo["types"]
    refute by_id["a_node:games"]["data"].key?("status"), "the node's details read its apps'"
    refute by_id.key?("a_app:gone/app")
    assert_equal({ "name" => "x", "type" => "type 9", "encoding" => "encoding 99" },
                 Bridge::Graph.topic_row("x", { "t" => 9, "e" => 99 }))
  end

  SHARED = "host/@shared/spectate/t1/state".freeze
  SHARED_PUBS = { "spectate/t1/state" => { "t" => "g/table" } }.freeze

  test "a shared place's key: the sender's declaration and its own definitions; another node's place is dropped" do
    s = Bridge::AppProfiles.new
    s.due(%w[host/games host/room01])
    s.answered("host/games", { "pubs" => { SHARED => { "t" => "g/table" }, "pc/@shared/x" => { "t" => 1 } },
                               "types" => { "g/table" => { "f" => [ [ "st", "int" ] ] } } })
    s.answered("host/room01", { "pubs" => { SHARED => { "t" => "g/table", "ts" => true } },
                                "types" => { "g/table" => { "f" => [ [ "st", "str" ] ] } } })
    key = "asterism/#{SHARED}"
    assert_equal [ { "t" => "g/table" }, { "g/table" => { "f" => [ [ "st", "int" ] ] } } ], s.topic(key, from: "host/games")
    assert_equal [ { "t" => "g/table", "ts" => true }, { "g/table" => { "f" => [ [ "st", "str" ] ] } } ],
                 s.topic(key, from: "host/room01")
    assert_nil s.topic(key), "no sender: no declaration to read"
    assert_nil s.topic(key, from: "host/other")
    refute s.to_graph["host/games"]["pubs"].key?("pc/@shared/x"), "a node writes its own place only"
  end

  test "a sender that leaves takes its declarations with it; its late puts and answers are not kept" do
    s = Bridge::AppProfiles.new
    s.due(%w[host/games host/room01])
    s.answered("host/games", { "pubs" => { SHARED => { "t" => 5 } } })
    assert_equal [ true, false ], s.told_pubs("host/room01", { SHARED => { "t" => 5 } })
    key = "asterism/#{SHARED}"
    refute_nil s.topic(key, from: "host/room01")
    s.due(%w[host/games]) # room01's token went away
    assert_nil s.topic(key, from: "host/room01"), "its last @pubs put does not outlive it"
    assert_equal %w[host/games], s.to_graph.keys
    assert_equal [ false, false ], s.told_pubs("host/room01", { SHARED => { "t" => 5 } }), "a late put: not kept"
    refute s.told_status("host/room01", { "x" => 1 })
    refute s.answered("host/room01", { "pubs" => { SHARED => { "t" => 5 } } }), "a late answer: not kept"
    refute s.ask_again("host/room01")
    assert_equal %w[host/games], s.to_graph.keys
    g = Bridge::Graph.build(asterism: %w[asterism/host/games], app_profiles: s.to_graph).to_h
    shares = g["edges"].select { _1["kind"] == "shares" }
    assert_equal [ "a_app:host/games" ], shares.map { _1["source"] }, "no line from the sender that left"
    assert_equal %w[host/room01], s.due(%w[host/games host/room01]), "back: asked again"
  end

  test "the graph: the shared places as places, with lines from the apps that declare them" do
    g = Bridge::Graph.build(
      asterism: %w[asterism/host/games asterism/host/room01 asterism/pc/chat asterism/viewer/v],
      app_profiles: { "host/games" => { "pubs" => { SHARED => { "t" => "g/table" }, "host/@shared/spectate/t2/state" => { "t" => "g/table" },
                                                    "tables" => { "t" => 5 } } },
                      "host/room01" => { "pubs" => { SHARED => { "t" => "g/table", "ts" => true } } },
                      "pc/chat" => { "pubs" => { "@shared/lobby" => { "t" => 7, "d" => "hello" } } },
                      "gone/app" => { "pubs" => { "@shared/lobby" => { "t" => 7 } } } }
    ).to_h
    by_id = g["nodes"].to_h { [ _1["id"], _1 ] }
    place = by_id["a_shared:host"]
    assert_equal [ "a_shared", "asterism", "@shared", "a_node:host" ], place.values_at("kind", "layer", "label", "parent")
    assert_equal "node", place["data"]["place"]
    assert_equal [ SHARED, "host/@shared/spectate/t2/state" ].sort, place["data"]["keys"].map { _1["key"] }
    t1 = place["data"]["keys"].find { _1["key"] == SHARED }
    assert_equal [ { "name" => "spectate/t1/state", "type" => "g/table", "app" => "host/games" },
                   { "name" => "spectate/t1/state", "type" => "g/table", "ts" => true, "app" => "host/room01" } ], t1["senders"]
    global = by_id["a_shared:@shared"]
    assert_equal [ "a_shared", "@shared (network)", nil ], global.values_at("kind", "label", "parent")
    assert_equal [ { "key" => "@shared/lobby", "senders" => [ { "name" => "lobby", "type" => "text", "desc" => "hello", "app" => "pc/chat" } ] } ],
                 global["data"]["keys"]
    shares = g["edges"].select { _1["kind"] == "shares" }.to_h { [ _1["source"], _1 ] }
    assert_equal %w[a_app:host/games a_app:host/room01 a_app:pc/chat], shares.keys.sort
    assert_equal [ "a_shared:host", "spectate/t1/state\nspectate/t2/state" ], shares["a_app:host/games"].values_at("target", "label")
    assert_equal "a_shared:@shared", shares["a_app:pc/chat"]["target"]
    refute by_id.key?("a_app:host/@shared"), "a place is not an app"
    refute by_id.key?("a_shared:viewer"), "no declaration, no place"
    assert_equal 1, g["nodes"].count { _1["kind"] == "a_shared" && _1["data"]["place"] == "global" }
  end
end
