require "test_helper"

# Bridge::Marks: what each Asterism node runs on, and the relay registry's
# names that are not here in one box with a line to the router the
# registry expects them at (V2.2).
class Bridge::MarksTest < ActiveSupport::TestCase
  CLOUD = "zenohd-cloud"

  def router(id, name = nil)
    { "id" => "router:#{id}", "kind" => "router", "layer" => "infra", "label" => "router #{name || id}",
      "data" => { "zid" => id, "name" => name }.compact }
  end

  def a_node(name, self_node = false)
    { "id" => "a_node:#{name}", "kind" => "a_node", "layer" => "asterism", "label" => name,
      "data" => { "node" => name, "self" => self_node } }
  end

  def absent(name, kind: "client", in_acl: true)
    { "id" => "reg:#{name}", "kind" => "registered", "layer" => "infra", "label" => name,
      "data" => { "registry" => "absent", "peer" => { "name" => name, "kind" => kind, "enabled" => in_acl, "in_acl" => in_acl } } }
  end

  def find(g, id)
    g["nodes"].find { _1["id"] == id } or flunk("no node #{id}")
  end

  def expects(g)
    g["edges"].select { _1["kind"] == "expect" }.map { [ _1["source"], _1["target"] ] }.sort
  end

  test "what an Asterism node runs on, by its name" do
    g = Bridge::Marks.apply({ "nodes" => [ a_node("console", true), a_node("fmruby-aaaaaa"), a_node("linux"),
                                           a_node("cruby"), a_node("fmruby-board"), a_node("mujoco") ],
                              "edges" => [] })
    assert_equal({ "console" => "console", "fmruby-aaaaaa" => "board", "linux" => "board", "cruby" => "ruby",
                   "fmruby-board" => "ruby", "mujoco" => "ruby" },
                 g["nodes"].to_h { [ _1["label"], _1["data"]["machine"] ] })
  end

  test "registered names not here go in one box, with a line to the cloud router when it is here" do
    graph = { "nodes" => [ router("c1", CLOUD), router("h1", "zenohd-home"), a_node("console", true),
                           absent("w2bot"), absent("relay2", kind: "router"), absent("off", in_acl: false),
                           absent(CLOUD, kind: "router") ],
              "edges" => [] }
    g = Bridge::Marks.apply(graph, cloud: CLOUD)
    box = find(g, "reg_box")
    assert_equal [ "reg_box", "infra", "Not connected (registry)", { "cloud" => CLOUD } ],
                 box.values_at("kind", "layer", "label", "data")
    %w[w2bot relay2 off].each { assert_equal "reg_box", find(g, "reg:#{_1}")["parent"] }
    assert_equal [ [ "reg:relay2", "router:c1" ], [ "reg:w2bot", "router:c1" ] ], expects(g)
    assert_equal CLOUD, find(g, "reg:w2bot")["data"]["expect"]
    # Left out of the ACL, or the cloud router's own entry: the registry does
    # not tell where they would connect.
    assert_nil find(g, "reg:off")["data"]["expect"]
    assert_nil find(g, "reg:#{CLOUD}")["data"]["expect"]
    # Only the registered names go in the box.
    assert_nil find(g, "a_node:console")["parent"]
    # Idempotent: applying again gives the same graph.
    assert_equal g, Bridge::Marks.apply(g, cloud: CLOUD)
  end

  test "the line goes to the cloud router's entry in the box when the cloud router is not here" do
    g = Bridge::Marks.apply({ "nodes" => [ router("h1"), absent("w2bot"), absent(CLOUD, kind: "router") ], "edges" => [] },
                            cloud: CLOUD)
    assert_equal [ [ "reg:w2bot", "reg:#{CLOUD}" ] ], expects(g)
  end

  test "no line when neither the cloud router nor its entry is there, or without the cloud's name" do
    g = Bridge::Marks.apply({ "nodes" => [ router("h1"), absent("w2bot") ], "edges" => [] }, cloud: CLOUD)
    assert_empty expects(g)
    assert_equal CLOUD, find(g, "reg:w2bot")["data"]["expect"]
    g = Bridge::Marks.apply({ "nodes" => [ router("c1", CLOUD), absent("w2bot") ], "edges" => [] })
    assert_empty expects(g)
    assert_nil find(g, "reg:w2bot")["data"]["expect"]
  end

  test "no registered names, no box; the box goes when the last one is here" do
    g = Bridge::Marks.apply({ "nodes" => [ router("c1", CLOUD), a_node("w2bot") ], "edges" => [] }, cloud: CLOUD)
    refute g["nodes"].any? { _1["kind"] == "reg_box" }
    with = Bridge::Marks.apply({ "nodes" => [ router("c1", CLOUD), absent("w2bot") ], "edges" => [] }, cloud: CLOUD)
    later = with.merge("nodes" => with["nodes"].reject { _1["id"] == "reg:w2bot" } + [ a_node("w2bot") ])
    g = Bridge::Marks.apply(later, cloud: CLOUD)
    refute g["nodes"].any? { _1["kind"] == "reg_box" }
    assert_empty expects(g)
  end

  test "the graph keeps its other parts" do
    g = Bridge::Marks.apply({ "nodes" => [], "edges" => [], "extra" => 1 })
    assert_equal({ "nodes" => [], "edges" => [], "extra" => 1 }, g)
  end
end
