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
            "mygame/other" => { "f" => [ [ "v", 1 ] ] } }.freeze

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
                                      "types" => TYPES.merge("broken" => { "f" => 1 }), "other" => 1 })
    got = s.to_graph["linux/demo"]
    assert_equal({ "ok" => 1 }, got["status"])
    assert_equal PUBS.merge("x" => {}), got["pubs"], "a declaration with a bad type is kept without it"
    assert_equal TYPES, got["types"]
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
end
