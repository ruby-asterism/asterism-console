require "test_helper"
require "open3"

# The graph's node labels (app/javascript/lib/node_label.js, 0.3.5), run by
# Node from the same module the page loads: the registry's display name,
# else the profile's name, else the ID; the ID always in the label. Skipped
# without node.
class NodeLabelTest < ActiveSupport::TestCase
  MODULE = Rails.root.join("app/javascript/lib/node_label.js")

  SCRIPT = <<~JS.freeze
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    import("data:text/javascript;base64," + Buffer.from(src).toString("base64")).then((m) => {
      const nodes = JSON.parse(fs.readFileSync(0, "utf8"))
      process.stdout.write(JSON.stringify(nodes.map((n) => m.nodeLabel(n))))
    })
  JS

  def labels(nodes)
    out, err, st = Open3.capture3("node", "-e", SCRIPT, MODULE.to_s, stdin_data: JSON.generate(nodes))
    assert st.success?, err
    JSON.parse(out)
  rescue SystemCallError
    skip "no node to run the browser module"
  end

  def a_node(id, data = {}) = { "id" => "a_node:#{id}", "kind" => "a_node", "label" => id, "data" => data }

  test "the display name, else the profile's name, else the ID" do
    got = labels([
      a_node("fmruby-aaaaaa", "peer" => { "display_name" => "Tab5" }, "profile" => { "name" => "Alice's board" }),
      a_node("fmruby-bbbbbb", "peer" => { "name" => "fmruby-bbbbbb" }, "profile" => { "name" => "Alice's board" }),
      a_node("fmruby-cccccc", "peer" => { "name" => "fmruby-cccccc" }),
      a_node("fmruby-dddddd", "peer" => { "display_name" => "fmruby-dddddd" })
    ])
    assert_equal [ "Tab5 (fmruby-aaaaaa)", "Alice's board (fmruby-bbbbbb)", "fmruby-cccccc", "fmruby-dddddd" ], got
  end

  test "routers and absent rows take the display name; others keep their labels" do
    got = labels([
      { "kind" => "router", "label" => "router zenohd-home", "data" => { "peer" => { "display_name" => "Home" } } },
      { "kind" => "registered", "label" => "w2bot", "data" => { "peer" => { "display_name" => "Bot" } } },
      { "kind" => "router", "label" => "router zenohd-home", "data" => { "profile" => { "name" => "not for routers" } } },
      { "kind" => "r_node", "label" => "talker", "data" => { "peer" => { "display_name" => "x" } } }
    ])
    assert_equal [ "Home (router zenohd-home)", "Bot (w2bot)", "router zenohd-home", "talker" ], got
  end

  test "this console and a room's game host keep their own labels" do
    got = labels([
      a_node("console", "self" => true, "peer" => { "display_name" => "Console" }),
      a_node("games", "room_host" => true, "room" => "05", "profile" => { "name" => "permanent tables" }),
      a_node("wasm-1a2b3c", "room" => "05")
    ])
    assert_equal [ "console (this console)", "games (room 05)", "wasm-1a2b3c" ], got
  end
end
