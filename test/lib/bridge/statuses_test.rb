require "test_helper"

# Bridge::Statuses (0.3.4): which applications to ask, answers and puts,
# the reading of asterism's docs/protocol.md 8.4, and the graph's data
# "status" on the apps (nothing drawn changes).
class Bridge::StatusesTest < ActiveSupport::TestCase
  ST = { "mahjong1" => { "st" => "play", "members" => 4, "humans" => 1, "cpus" => 3, "away" => 0 } }.freeze

  test "each application is asked once, again after it leaves and comes back" do
    s = Bridge::Statuses.new
    assert_equal %w[games/games linux/demo], s.due(%w[games/games linux/demo])
    assert_equal [], s.due(%w[games/games linux/demo]), "being asked"
    refute s.answered("linux/demo", nil), "no status: nothing to show"
    assert s.answered("games/games", ST)
    assert_equal [], s.due(%w[games/games linux/demo])
    assert_equal({ "games/games" => ST }, s.to_graph)
    assert_equal [], s.due(%w[linux/demo]), "the host left"
    assert_equal({}, s.to_graph)
    assert_equal %w[games/games], s.due(%w[games/games linux/demo]), "back"
  end

  test "a put replaces what is known; the same one changes nothing" do
    s = Bridge::Statuses.new
    s.due(%w[games/games])
    s.answered("games/games", ST)
    other = { "mahjong1" => ST["mahjong1"].merge("humans" => 2) }
    assert s.told("games/games", other)
    refute s.told("games/games", other)
    assert_equal 2, s.to_graph["games/games"]["mahjong1"]["humans"]
  end

  test "the reading: a map with str keys, 1024 bytes at most" do
    pl = ->(v) { MessagePack.pack(v) }
    assert_equal [ "games/games", ST ], Bridge::Statuses.parse("asterism/games/games/@status", pl.(ST))
    assert_equal [ "a/b", { "ok" => 1 } ], Bridge::Statuses.parse("asterism/a/b/@status", pl.({ "ok" => 1, 2 => 3, "" => 4 }))
    assert_nil Bridge::Statuses.parse("asterism/a/b/@status", pl.([ 1 ]))
    assert_nil Bridge::Statuses.parse("asterism/a/b/@status", pl.({ "big" => "x" * 1100 }))
    assert_nil Bridge::Statuses.parse("asterism/a/@profile", pl.(ST))
    assert_nil Bridge::Statuses.parse("asterism/a/b/@status", "\xc1")
  end

  test "the graph puts the status on the app, and only there" do
    g = Bridge::Graph.build(asterism: %w[asterism/games/games asterism/games/games/mahjong1 asterism/linux/demo],
                            statuses: { "games/games" => ST, "gone/app" => { "x" => 1 } }).to_h
    by_id = g["nodes"].to_h { [ _1["id"], _1 ] }
    assert_equal ST, by_id["a_app:games/games"]["data"]["status"]
    refute by_id["a_app:linux/demo"]["data"].key?("status")
    refute by_id["a_node:games"]["data"].key?("status"), "the node's details read its apps'"
    refute by_id.key?("a_app:gone/app")
  end
end
