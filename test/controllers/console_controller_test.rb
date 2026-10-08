require "test_helper"

class ConsoleControllerTest < ActionDispatch::IntegrationTest
  setup do
    GraphState.delete_all
    GraphState.create!(version: 3, bridge_seen_at: Time.current,
                       bridge_info: JSON.generate("router" => "tcp/127.0.0.1:7447", "node" => "console"),
                       snapshot: JSON.generate(Bridge::Graph.build(
                         asterism: %w[asterism/fmruby-aaaaaa asterism/fmruby-aaaaaa/demo/screen]
                       ).to_h))
    Watch.create!(key: "fmrb/test/out")
  end

  test "the page carries the graph, the layers, the warning and the watches" do
    get root_path
    assert_response :success
    assert_select "h1", "Asterism Console"
    assert_select ".warning", /No authentication/
    assert_select "input[type=checkbox][data-layer]", 3
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

  test "a page with no bridge yet" do
    GraphState.delete_all
    get root_path
    assert_response :success
    assert_equal 1, GraphState.count
  end
end
