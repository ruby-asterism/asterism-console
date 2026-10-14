require "test_helper"

# The bridge's rooms (0.2.1): the rooms' tokens and the open rooms go into
# the graph; the admins' stream gets them, the others' does not.
class Bridge::RunnerRoomsTest < ActiveSupport::TestCase
  class FakeZenoh
    def zid = "abc"
    def router_zids = []
    def connection_count = 1
  end

  setup do
    @runner = Bridge::Runner.new(objects: Object.new, logger: Logger.new(nil))
    @runner.define_singleton_method(:say) { |_text| nil }
    @runner.instance_variable_set(:@z, FakeZenoh.new)
    @runner.instance_variable_set(:@self_zids, [ "abc" ])
    GraphState.current.update!(version: 3, snapshot: JSON.generate("nodes" => [], "edges" => []))
    Room.create!(uid: "a1b2c3d4e5f60718", name: "Game night", app: "game", slot: "01", max_connections: 4,
                 expires_at: 2.hours.from_now)
  end

  test "the rooms reach the admins' graph only" do
    assert_equal "room/*/asterism/**", Bridge::Runner::ROOMS_WATCH
    @runner.instance_variable_set(:@rooms, @runner.send(:open_rooms))
    @runner.instance_variable_get(:@room_keys)["room/01/asterism/wasm-a1b2c3/game"] = true
    @runner.instance_variable_get(:@asterism_keys)["asterism/console/console"] = true
    @runner.send(:publish_graph)
    rooms = ActiveSupport::JSON.decode(broadcasts(ConsoleChannel::GRAPH_ROOMS).last)
    others = ActiveSupport::JSON.decode(broadcasts(ConsoleChannel::GRAPH).last)
    assert_equal [ 4, 4 ], [ rooms["version"], others["version"] ]
    ids = rooms["diff"]["add_nodes"].map { _1["id"] }
    assert_includes ids, "room:01"
    assert_includes ids, "a_node:room/01/wasm-a1b2c3"
    assert_equal "Game night", rooms["diff"]["add_nodes"].find { _1["id"] == "room:01" }["label"]
    assert_equal [ "a_node:console", "a_app:console/console" ].sort,
                 others["diff"]["add_nodes"].map { _1["id"] }.grep(/console/).sort
    refute JSON.generate(others).include?("room"), "nothing of a room on the others' stream"
    assert GraphState.current.graph["nodes"].any? { _1["id"] == "room:01" }, "the state keeps the whole graph"
  end
end
