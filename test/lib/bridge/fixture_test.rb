require "test_helper"

# Fixture mode (CONSOLE_FIXTURE): a recorded network instead of the bridge.
class Bridge::FixtureTest < ActiveSupport::TestCase
  FILE = Rails.root.join("test/fixtures/files/busy_network.json").to_s

  test "the busy network builds through the graph code" do
    g = Bridge::Fixture.graph(Bridge::Fixture.load(FILE))
    by = g["nodes"].group_by { _1["kind"] }.transform_values(&:size)
    assert_equal 2, by["router"]
    assert_equal 5, by["a_node"]
    assert_operator by["r_node"], :>=, 10
    assert_operator g["nodes"].count { _1["kind"] == "r_topic" }, :>=, 10
  end

  test "the recorded rates are moved to now" do
    inputs = Bridge::Fixture.load(FILE)
    r = Bridge::Fixture.rates(inputs, inputs["recorded_at"] + 60_000)
    assert_equal inputs["rates"]["r_topic:0/chatter"]["at"] + 60_000, r["r_topic:0/chatter"]["at"]
    assert_equal inputs["rates"]["r_topic:0/chatter"]["hz"], r["r_topic:0/chatter"]["hz"]
  end

  test "GraphState.current is the fixture, not saved, when fixture mode is on" do
    with_fixture(FILE) do
      s = GraphState.current
      refute s.persisted?
      assert s.bridge_alive?
      assert s.info["fixture"]
      assert_operator s.as_payload["rates"].size, :>, 0
    end
    assert GraphState.current.persisted?
  end

  def with_fixture(file)
    x = Rails.application.config.x
    x.console_fixture = file
    yield
  ensure
    x.console_fixture = nil
  end
end
