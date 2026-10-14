require "test_helper"

class ConsoleControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:user))
    GraphState.delete_all
    GraphState.create!(version: 3, bridge_seen_at: Time.current,
                       bridge_info: JSON.generate("router" => "tcp/127.0.0.1:7447", "node" => "console"),
                       snapshot: JSON.generate(Bridge::Graph.build(
                         asterism: %w[asterism/fmruby-aaaaaa asterism/fmruby-aaaaaa/demo/screen]
                       ).to_h))
    Watch.create!(key: "fmrb/test/out")
  end

  test "the page carries the graph, the layers, who is signed in and the watches" do
    get root_path
    assert_response :success
    assert_select "h1", "Asterism Console"
    assert_select ".nav .who", /pat/
    assert_select ".nav .who[title=?]", "user@example.com"
    assert_select ".dock.watches.empty form.watch-form input[name=key]"
    assert_select ".dock [data-console-target=watchCount]"
    assert_select ".graph-body .upper .side .details"
    assert_select ".side .watches", 0, "the watched keys are in the panel below, not the right column"
    assert_select ".splitter-x[role=separator]"
    assert_select ".splitter-y[role=separator]"
    assert_select "input[type=checkbox][data-layer]", 4
    %w[topic_nodes hide_debug show_hz measure_all].each { assert_select "input[type=checkbox][name=#{_1}]" }
    assert_select "[data-controller=console]" do |el|
      state = JSON.parse(el.first["data-console-state-value"])
      assert_equal 3, state["version"]
      assert state["bridge"]["alive"]
      assert_includes state["graph"]["nodes"].map { _1["id"] }, "a_object:fmruby-aaaaaa/demo/screen"
      watches = JSON.parse(el.first["data-console-watches-value"])
      assert_equal [ "fmrb/test/out" ], watches.map { _1["key"] }
    end
  end

  test "the graph as JSON, with the bridge gone quiet" do
    GraphState.current.update!(bridge_seen_at: 1.minute.ago)
    get graph_path, as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal 3, body["version"]
    refute body["bridge"]["alive"]
    assert_equal 3, body["graph"]["nodes"].size
  end

  test "fixture mode: the recorded network and its rates, nothing saved" do
    Rails.application.config.x.console_fixture = Rails.root.join("test/fixtures/files/busy_network.json").to_s
    get root_path
    assert_response :success
    assert_select "[data-controller=console]" do |el|
      state = JSON.parse(el.first["data-console-state-value"])
      assert state["bridge"]["fixture"]
      assert_includes state["graph"]["nodes"].map { _1["id"] }, "a_app:fmruby-bbbbbb/sensors"
      assert_equal 10.0, state["rates"]["r_topic:0/cmd_vel"]["hz"]
    end
    assert_equal 3, GraphState.first.version, "the saved graph is left alone"
  ensure
    Rails.application.config.x.console_fixture = nil
  end

  test "a page with no bridge yet" do
    GraphState.delete_all
    get root_path
    assert_response :success
    assert_equal 1, GraphState.count
  end

  test "the rooms (0.2.1): in the page, the layer and /graph for an admin only; the zone in the layout" do
    room_graph = Bridge::Graph.build(asterism: %w[asterism/console/console],
                                     rooms: %w[room/01/asterism/wasm-a1b2c3/game/table],
                                     room_info: [ { "slot" => "01", "name" => "Game night", "expires_at" => "2026-10-14T13:00:00Z" } ]).to_h
    GraphState.first.update!(snapshot: JSON.generate(room_graph))
    get root_path
    assert_select "meta[name=console-time-zone][data-abbr=UTC][data-offset=0]"
    assert_select "input[data-layer=rooms]", 0
    assert_select "[data-controller=console][data-console-rooms-value=false]"
    refute_includes css_select("[data-controller=console]").first["data-console-state-value"], "Game night"
    get graph_path, as: :json
    refute_includes response.body, "room"

    sign_out if respond_to?(:sign_out)
    sign_in_as(users(:admin))
    get root_path
    assert_select "input[type=checkbox][data-layer=rooms][checked]"
    assert_select "[data-controller=console][data-console-rooms-value=true]"
    state = JSON.parse(css_select("[data-controller=console]").first["data-console-state-value"])
    assert state["graph"]["nodes"].any? { _1["id"] == "room:01" }
    get graph_path, as: :json
    assert_includes response.parsed_body["graph"]["nodes"].map { _1["id"] }, "a_object:room/01/wasm-a1b2c3/game/table"
  end
end
