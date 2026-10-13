require "test_helper"

# Bridge::Profiles (V2.5): which nodes to ask, answers and notices, the
# icon store, and the graph's data "profile".
class Bridge::ProfilesTest < ActiveSupport::TestCase
  PNG = File.binread(Rails.root.join("app/assets/images/asterism_console.png"))

  test "each node is asked once, again after it leaves and comes back" do
    pr = Bridge::Profiles.new(icons: Set.new)
    assert_equal %w[a b], pr.due(%w[a b])
    assert_equal [], pr.due(%w[a b]), "being asked"
    refute pr.answered("a", nil), "no answer: nothing to draw"
    assert pr.answered("b", { "kind" => "cruby", "icon" => "x", "icon_hash" => "0a1b2c3d" })
    assert_equal [], pr.due(%w[a b]), "answered, with a profile or without"
    assert_equal({ "b" => { "kind" => "cruby", "icon_hash" => "0a1b2c3d" } }, pr.to_graph)
    assert_equal [], pr.due(%w[a]), "b left"
    assert_equal({}, pr.to_graph)
    assert_equal %w[b], pr.due(%w[a b]), "b is back"
  end

  test "a notice replaces what is known; the same one changes nothing" do
    pr = Bridge::Profiles.new(icons: Set.new)
    pr.due(%w[a])
    pr.answered("a", { "kind" => "family_mruby", "host" => "sim" })
    assert pr.told("a", { "kind" => "family_mruby", "host" => "sim", "name" => "Demo" })
    refute pr.told("a", { "kind" => "family_mruby", "host" => "sim", "name" => "Demo" })
    refute pr.told("a", nil)
    assert_equal "Demo", pr.to_graph["a"]["name"]
  end

  test "icons go to the store once per hash" do
    pr = Bridge::Profiles.new
    refute pr.icon?("0a1b2c3d")
    pr.keep_icon("0a1b2c3d", PNG, 32, 32)
    assert pr.icon?("0a1b2c3d")
    assert_equal Set["0a1b2c3d"], pr.icon_set
    assert Bridge::Profiles.new.icon?("0a1b2c3d"), "read from the store"
  end

  test "the graph puts the profile on the node, Marks the mark and the icon" do
    g = Bridge::Graph.build(asterism: %w[asterism/fmruby-aaaaaa/demo asterism/old/demo asterism/console/console], self_node: "console",
                            profiles: { "fmruby-aaaaaa" => { "kind" => "family_mruby", "host" => "atoms3r", "icon_hash" => "0a1b2c3d" },
                                        "console" => { "kind" => "console", "icon_hash" => "ffffffff" },
                                        "gone" => { "kind" => "cruby" } },
                            icons: Set["0a1b2c3d"]).to_h
    data = g["nodes"].select { _1["kind"] == "a_node" }.to_h { [ _1["label"], _1["data"] ] }
    assert_equal [ "family_mruby", "profile", "/icons/0a1b2c3d", "atoms3r" ],
                 data["fmruby-aaaaaa"].values_at("machine", "machine_by", "icon").push(data["fmruby-aaaaaa"]["profile"]["host"])
    assert_equal [ nil, "none", nil ], data["old"].values_at("machine", "machine_by", "icon")
    assert_equal [ "console", "self", nil ], data["console"].values_at("machine", "machine_by", "icon")
    refute data.key?("gone")
  end
end
