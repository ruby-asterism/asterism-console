require "test_helper"

class RecordingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    FileUtils.mkdir_p(Recording.dir)
    sign_in_as(users(:user))
  end

  teardown { Recording.find_each(&:destroy) }

  def uploaded(name = "rosbag2_jazzy.mcap")
    post upload_recordings_path, params: { file: fixture_file_upload(name, "application/octet-stream") }
    Recording.order(:id).last
  end

  test "the page lists the ROS 2 topics to pick and the recordings" do
    GraphState.current.update!(snapshot: JSON.generate("nodes" => [
      { "id" => "r_topic:0/cmd_vel", "kind" => "r_topic", "data" => { "name" => "/cmd_vel", "type" => "geometry_msgs/msg/Twist", "domain" => "0" } }
    ], "edges" => []))
    get recordings_path
    assert_response :success
    assert_includes response.body, 'value="r_topic:0/cmd_vel"'
    assert_includes response.body, "Start recording"
  end

  test "start: a pending row for the bridge, with the limits; refused when empty or too much" do
    post recordings_path, params: { recording: { name: "drive", topics: [ "r_topic:0/cmd_vel" ], keys: "demo/imu\nasterism/*/*/log",
                                                 structure: "1", max_mb: "2", max_seconds: "30" } }
    r = Recording.last
    assert_redirected_to recording_path(r)
    assert_equal [ "pending", "drive", 2 * Recording::MB, 30, users(:user) ], [ r.status, r.name, r.max_bytes, r.max_seconds, r.user ]
    assert_equal({ "topics" => [ "r_topic:0/cmd_vel" ], "keys" => [ "demo/imu", "asterism/*/*/log" ], "structure" => true }, r.selection_value)
    assert_no_difference -> { Recording.count } do
      post recordings_path, params: { recording: { name: "nothing" } }, as: :json
      assert_response :unprocessable_content
      assert_match(/is empty/, response.parsed_body["errors"].join)
      post recordings_path, params: { recording: { keys: "@/**" } }, as: :json
      assert_match(/admin space/, response.parsed_body["errors"].join)
      post recordings_path, params: { recording: { structure: "1", max_mb: "100000" } }, as: :json
      assert_response :unprocessable_content
    end
    post recordings_path, params: { recording: { structure: "1" } }
    assert_no_difference -> { Recording.count } do
      post recordings_path, params: { recording: { structure: "1" } }, as: :json
      assert_match(/2 recordings are running/, response.parsed_body["errors"].join)
    end
  end

  test "stop and delete: the one who started it, or an admin" do
    r = Recording.new(user: users(:admin), name: "theirs", status: "recording")
    r.selection_value = { "structure" => true }
    r.save!
    post stop_recording_path(r), as: :json
    assert_response :forbidden
    assert_equal "recording", r.reload.status
    sign_in_as(users(:admin))
    post stop_recording_path(r), as: :json
    assert_equal "stopping", r.reload.status
    delete recording_path(r)
    assert Recording.exists?(r.id), "not while it runs"
    r.update!(status: "done")
    File.binwrite(r.path, "x")
    delete recording_path(r)
    refute Recording.exists?(r.id)
    refute File.exist?(r.path)
  end

  test "a pending recording stopped before the bridge took it ends at once" do
    post recordings_path, params: { recording: { structure: "1" } }
    r = Recording.last
    post stop_recording_path(r)
    assert_equal "failed", r.reload.status
    assert_match(/before the bridge started/, r.stop_reason)
  end

  test "upload a rosbag2 file: listed, its timeline, the JSON of the timeline" do
    r = uploaded
    assert_redirected_to recording_path(r)
    assert_equal [ "uploaded", "uploaded", 114 ], [ r.source, r.status, r.messages ]
    get recording_path(r)
    assert_response :success
    assert_includes response.body, 'data-controller="timeline"'
    cmd = r.info_value["channels"].find { _1["topic"] == "/cmd_vel" }
    get ticks_recording_path(r, buckets: 50), as: :json
    t = response.parsed_body
    assert_equal 50, t["buckets"]
    assert_equal 19, t["channels"][cmd["id"].to_s].sum
    assert_equal r.info_value["start"].to_s, t["start"]
    get message_recording_path(r, channel: cmd["id"], t: 1_000_000_000), as: :json
    m = response.parsed_body
    assert_operator m["log_time"], :<=, 1_000_000_000
    assert_operator m["next"], :>, 1_000_000_000
    assert_kind_of Float, m.dig("value", "linear", "x")
    get message_recording_path(r, channel: cmd["id"], t: m["next"]), as: :json
    assert_equal m["index"] + 1, response.parsed_body["index"], "stepping to the next message lands on it exactly"
    get message_recording_path(r, t: 1_000_000_000), as: :json
    assert_equal 3, response.parsed_body["at"].size
    get fields_recording_path(r, channel: cmd["id"]), as: :json
    assert_includes response.parsed_body["fields"].map { _1["path"] }, "angular.z"
    get series_recording_path(r, channel: cmd["id"], paths: [ "linear.x" ]), as: :json
    assert_equal 19, response.parsed_body["v"]["linear.x"].size
    get series_recording_path(r, channel: cmd["id"], paths: [ "a[b" ]), as: :json
    assert_response :unprocessable_content
    get graph_recording_path(r, t: 0), as: :json
    assert_match(/no network structure/, response.parsed_body["error"])
  end

  test "upload: a compressed file lists, its messages say why not; not an MCAP file is refused" do
    r = uploaded("rosbag2_jazzy_zstd.mcap")
    assert_equal [ "zstd" ], r.info_value["compression"]
    get recording_path(r)
    assert_includes response.body, "cannot be read here"
    ch = r.info_value["channels"].first
    get message_recording_path(r, channel: ch["id"], t: 0), as: :json
    assert_match(/unsupported compression "zstd"/, response.parsed_body["error"])
    assert_no_difference -> { Recording.count } do
      post upload_recordings_path, params: { file: fixture_file_upload("busy_network.json", "application/json") }
    end
    assert_match(/Not a readable MCAP file/, flash[:alert])
    assert_empty Dir.glob(Recording.dir.join("*.mcap")) - Recording.all.map { _1.path.to_s }
  end

  test "download: the file, and the ROS 2 topics only" do
    r = uploaded
    get download_recording_path(r)
    assert_response :success
    assert_equal File.binread(file_fixture("rosbag2_jazzy.mcap")), response.body
    assert_match(/attachment; filename="rosbag2_jazzy\.mcap"/, response.headers["Content-Disposition"])
    get download_recording_path(r, ros2: 1)
    assert_response :success
    reader = MCAP::Reader.new(StringIO.new(response.body))
    assert reader.verify!
    assert_equal 114, reader.info["messages"]
  end

  test "the network structure page" do
    r = Recording.new(user: users(:user), name: "net", status: "done")
    r.selection_value = { "structure" => true }
    r.save!
    File.open(r.path, "wb") do |f|
      w = MCAP::Writer.new(f)
      g = w.add_channel(topic: "/asterism/graph", message_encoding: "json",
                        schema_id: w.add_schema(name: "asterism/graph", encoding: "jsonschema", data: "{}"))
      w.add_message(channel_id: g, log_time: 10, data: JSON.generate("kind" => "snapshot", "version" => 1,
                                                                    "graph" => { "nodes" => [ { "id" => "x", "kind" => "r_node", "label" => "/x" } ], "edges" => [] }))
      w.finish
    end
    get structure_recording_path(r)
    assert_response :success
    assert_includes response.body, 'data-console-replay-value="true"'
    get graph_recording_path(r, t: 5), as: :json
    assert_equal [ "x" ], response.parsed_body["graph"]["nodes"].map { _1["id"] }
  end

  test "a structure recorded before V2.2 gets the marks and the registry box" do
    r = Recording.new(user: users(:user), name: "old registry", status: "done")
    r.selection_value = { "structure" => true }
    r.save!
    old = {
      "nodes" => [
        { "id" => "router:r1", "kind" => "router", "layer" => "infra", "label" => "router zenohd-cloud",
          "data" => { "name" => "zenohd-cloud" } },
        { "id" => "a_node:linux", "kind" => "a_node", "layer" => "asterism", "label" => "linux", "data" => { "node" => "linux" } },
        { "id" => "reg:w2bot", "kind" => "registered", "layer" => "infra", "label" => "w2bot",
          "data" => { "registry" => "absent", "peer" => { "name" => "w2bot", "kind" => "client", "enabled" => true, "in_acl" => true } } }
      ],
      "edges" => []
    }
    File.open(r.path, "wb") do |f|
      w = MCAP::Writer.new(f)
      g = w.add_channel(topic: "/asterism/graph", message_encoding: "json",
                        schema_id: w.add_schema(name: "asterism/graph", encoding: "jsonschema", data: "{}"))
      w.add_message(channel_id: g, log_time: 10, data: JSON.generate("kind" => "snapshot", "version" => 1, "graph" => old))
      w.finish
    end
    get graph_recording_path(r, t: 5), as: :json
    graph = response.parsed_body["graph"]
    assert_equal "board", graph["nodes"].find { _1["id"] == "a_node:linux" }["data"]["machine"]
    assert_equal "reg_box", graph["nodes"].find { _1["id"] == "reg:w2bot" }["parent"]
    assert graph["nodes"].any? { _1["kind"] == "reg_box" }
    assert graph["edges"].any? { _1["kind"] == "expect" && _1["source"] == "reg:w2bot" && _1["target"] == "router:r1" }
  end

  test "a structure recorded before V2.1 is drawn the default way too" do
    r = Recording.new(user: users(:user), name: "old net", status: "done")
    r.selection_value = { "structure" => true }
    r.save!
    old = {
      "nodes" => [
        { "id" => "router:r1", "kind" => "router", "layer" => "infra", "label" => "router r1", "data" => {} },
        { "id" => "session:s1", "kind" => "session", "layer" => "infra", "label" => "peer s1",
          "data" => { "zid" => "s1", "whatami" => "peer", "address" => "tcp/192.0.2.5:1", "protocol" => "tcp" } },
        { "id" => "r_node:s1/0", "kind" => "r_node", "layer" => "ros", "label" => "/x", "data" => { "zid" => "s1" } }
      ],
      "edges" => [
        { "id" => "session:router:r1->session:s1", "kind" => "session", "source" => "router:r1", "target" => "session:s1" },
        { "id" => "carries:session:s1->r_node:s1/0", "kind" => "carries", "source" => "session:s1", "target" => "r_node:s1/0" }
      ]
    }
    File.open(r.path, "wb") do |f|
      w = MCAP::Writer.new(f)
      g = w.add_channel(topic: "/asterism/graph", message_encoding: "json",
                        schema_id: w.add_schema(name: "asterism/graph", encoding: "jsonschema", data: "{}"))
      w.add_message(channel_id: g, log_time: 10, data: JSON.generate("kind" => "snapshot", "version" => 1, "graph" => old))
      w.finish
    end
    get graph_recording_path(r, t: 5), as: :json
    graph = response.parsed_body["graph"]
    attach = graph["edges"].find { _1["kind"] == "attach" }
    assert_equal [ "r_node:s1/0", "router:r1", "peer" ], attach.values_at("source", "target", "label")
    assert_equal [ "s1" ], graph["nodes"].find { _1["id"] == "r_node:s1/0" }["data"]["connections"].map { _1["zid"] }
    assert graph["edges"].any? { _1["kind"] == "carries" }, "the sessions stay, for Sessions as points"
  end

  test "an unfinished recording has no timeline yet" do
    post recordings_path, params: { recording: { structure: "1" } }
    r = Recording.last
    get recording_path(r)
    assert_includes response.body, "Stop recording"
    get ticks_recording_path(r), as: :json
    assert_response :conflict
    get download_recording_path(r)
    assert_redirected_to recording_path(r)
  end
end
