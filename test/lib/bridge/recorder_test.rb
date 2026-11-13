require "test_helper"
require "asterism"

# The recorder on its own: what it writes for ROS 2 samples, Asterism keys
# and the network structure, and its limits.
class Bridge::RecorderTest < ActiveSupport::TestCase
  KEY = "0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_9c45bf16fe0983d80e3cfe750d6835843d265a9a6c46bd2e609fcddde6fb8d2a"
  Stamp = Struct.new(:time) do
    def to_time = time
  end

  setup do
    @dir = Rails.root.join("tmp", "recorder-test-#{Process.pid}")
    FileUtils.mkdir_p(@dir)
    @now = 0.0
    @wall = 1_791_500_000_000_000_000
    @twist = Bridge::Types.ros("geometry_msgs/msg/Twist")
  end

  teardown { FileUtils.rm_rf(@dir) }

  def recorder(**opts)
    Bridge::Recorder.new(id: 1, path: @dir.join("r.mcap"), max_bytes: 1024 * 1024, max_seconds: 60,
                         clock: -> { @now }, wall_ns: -> { @wall += 1_000_000 }, **opts) { |_tid| [ Bag::Qos.parse("::,7:,:,:,,") ] }
  end

  def ros_sample(x, seq)
    att = Asterism::ROS::Attachment.new(seq, 1_791_400_000_000_000_000 + seq, "g" * 16).encode
    Asterism::Zenoh::Sample.new(key: KEY, payload: @twist.encode(linear: { x: x }), attachment: att)
  end

  test "ROS 2 samples as rosbag2 writes them; Asterism keys; the structure" do
    rec = recorder(structure: true).open
    graph = { "nodes" => [ { "id" => "a", "kind" => "r_node", "label" => "/a" } ], "edges" => [] }
    rec.graph(5, graph)
    3.times { |i| assert rec.ros(ros_sample(0.1 * i, i + 1)) }
    stamp = Stamp.new(Time.at(1_791_450_000, 250, :usec))
    assert rec.key("demo/**", Asterism::Zenoh::Sample.new(key: "demo/imu", payload: MessagePack.pack("t" => 1), timestamp: stamp))
    rec.graph(6, graph, { "add_nodes" => [], "remove_nodes" => [ "a" ] })
    refute rec.ros(Asterism::Zenoh::Sample.new(key: "not/a/ros/key", payload: "x"))
    p = rec.finish("stopped")
    assert_equal 6, p["messages"]
    assert_equal({ "/asterism/graph" => 2, "/cmd_vel" => 3, "demo/imu" => 1 }, p["channel_counts"])
    r = MCAP::Reader.new(@dir.join("r.mcap").to_s)
    assert r.verify!
    by = r.info["channels"].to_h { [ _1["topic"], _1 ] }
    cmd = by["/cmd_vel"]
    assert_equal [ "cdr", "geometry_msgs/msg/Twist", "ros2msg" ], cmd.values_at("message_encoding", "schema", "schema_encoding")
    assert_equal KEY.split("/").last, cmd["metadata"]["topic_type_hash"]
    assert_equal "0", cmd["metadata"]["ros_domain"]
    assert_match(/\A- history: keep_last\n  depth: 7\n/, cmd["metadata"]["offered_qos_profiles"])
    assert_equal [ "msgpack", "asterism/msgpack", "" ], by["demo/imu"].values_at("message_encoding", "schema", "schema_encoding")
    assert_equal "demo/**", by["demo/imu"]["metadata"]["asterism_key_expr"]
    assert_equal [ "json", "asterism/graph", "jsonschema" ], by["/asterism/graph"].values_at("message_encoding", "schema", "schema_encoding")
    msgs = r.each_message.map { |m, ch, _| [ ch.topic, m ] }
    first_ros = msgs.find { _1[0] == "/cmd_vel" }[1]
    assert_equal [ 1, 1_791_400_000_000_000_001 ], [ first_ros.sequence, first_ros.publish_time ]
    assert_operator first_ros.log_time, :>, first_ros.publish_time
    key_msg = msgs.find { _1[0] == "demo/imu" }[1]
    assert_equal 1_791_450_000_000_250_000, key_msg.publish_time
    kinds = msgs.select { _1[0] == "/asterism/graph" }.map { JSON.parse(_1[1].data)["kind"] }
    assert_equal %w[snapshot diff], kinds
    assert_equal({ x: 0.2, y: 0.0, z: 0.0 }, @twist.decode(msgs.select { _1[0] == "/cmd_vel" }.last[1].data).to_h[:linear])
  ensure
    r&.close
  end

  test "Asterism keys of protocol 2: encoding, sequence, sender's time, the declared type as the schema" do
    decls = {
      "asterism/linux/demo/imu" => [ { "t" => 2, "u" => "m/s2", "ts" => true }, {} ],
      "asterism/linux/demo/board1/strokes" => [ { "t" => "mygame/board.strokes" },
                                                 { "mygame/board.strokes" => { "f" => [ [ "pts", "mygame/point[]" ] ] },
                                                   "mygame/point" => { "f" => [ [ "x", "int" ], [ "y", "int" ] ], "d" => "a point" } } ],
      "asterism/linux/demo/camera" => [ { "t" => 4, "e" => 17 }, {} ]
    }
    rec = recorder(declarations: ->(key, _from) { decls[key] }).open
    stamp = Stamp.new(Time.at(1_791_450_000, 250, :usec))
    sample = ->(key, payload, att, enc: "zenoh/bytes", ts: stamp) do
      Asterism::Zenoh::Sample.new(key: key, payload: payload, attachment: att && MessagePack.pack(att), encoding: enc, timestamp: ts)
    end
    assert rec.key("asterism/linux/demo/**", sample.("asterism/linux/demo/imu", MessagePack.pack([ 0.1, 0, 9.8 ]), [ 7, 1_791_440_000_123 ]))
    assert rec.key("asterism/linux/demo/**", sample.("asterism/linux/demo/imu", MessagePack.pack([ 0.2, 0, 9.8 ]), [ 8, 1_791_440_000_223 ]))
    assert rec.key("asterism/linux/demo/**", sample.("asterism/linux/demo/board1/strokes", MessagePack.pack([ [ 1, 2 ] ]), [ 3 ]))
    jpeg = "\xFF\xD8\xFF\xE0jpeg".b
    assert rec.key("asterism/linux/demo/**", sample.("asterism/linux/demo/camera", jpeg, [ 0 ], enc: "image/jpeg"))
    assert rec.key("asterism/linux/demo/**", sample.("asterism/linux/demo/plain", MessagePack.pack(1), nil, ts: nil))
    assert rec.key("asterism/linux/demo/**", sample.("asterism/linux/demo/text", "hello", [ 1 ], enc: "text/plain"))
    rec.finish
    r = MCAP::Reader.new(@dir.join("r.mcap").to_s)
    assert r.verify!
    by = r.info["channels"].to_h { [ _1["topic"], _1 ] }
    imu = by["asterism/linux/demo/imu"]
    assert_equal [ "msgpack", "asterism/vector3", "" ], imu.values_at("message_encoding", "schema", "schema_encoding")
    assert_equal({ "t" => 2, "u" => "m/s2", "ts" => true }, JSON.parse(imu["metadata"]["asterism_declaration"]))
    assert_equal "2", imu["metadata"]["asterism_protocol"]
    strokes = by["asterism/linux/demo/board1/strokes"]
    assert_equal [ "msgpack", "mygame/board.strokes", "asterism/types" ], strokes.values_at("message_encoding", "schema", "schema_encoding")
    schema = r.schemas.values.find { _1.name == "mygame/board.strokes" }
    assert_equal %w[mygame/board.strokes mygame/point], JSON.parse(schema.data).keys.sort, "the type and the one its field names"
    assert_equal [ "image/jpeg", "asterism/image" ], by["asterism/linux/demo/camera"].values_at("message_encoding", "schema")
    assert_equal [ "msgpack", "asterism/msgpack" ], by["asterism/linux/demo/plain"].values_at("message_encoding", "schema")
    refute by["asterism/linux/demo/plain"]["metadata"].key?("asterism_declaration")
    assert_equal [ "text/plain", "asterism/untyped" ], by["asterism/linux/demo/text"].values_at("message_encoding", "schema")
    msgs = r.each_message.map { |m, ch, _| [ ch.topic, m ] }
    imu_msgs = msgs.select { _1[0] == "asterism/linux/demo/imu" }.map(&:last)
    assert_equal [ 7, 8 ], imu_msgs.map(&:sequence)
    assert_equal [ 1_791_440_000_123_000_000, 1_791_440_000_223_000_000 ], imu_msgs.map(&:publish_time), "the sender's time"
    stroke = msgs.find { _1[0] == "asterism/linux/demo/board1/strokes" }[1]
    assert_equal [ 3, 1_791_450_000_000_250_000 ], [ stroke.sequence, stroke.publish_time ], "no sender's time: the router's"
    cam = msgs.find { _1[0] == "asterism/linux/demo/camera" }[1]
    assert_equal jpeg, cam.data, "the bytes as they came"
    plain = msgs.find { _1[0] == "asterism/linux/demo/plain" }[1]
    assert_equal [ 0, plain.log_time ], [ plain.sequence, plain.publish_time ], "no attachment, no timestamp: the log time"
  ensure
    r&.close
  end

  test "a shared place's key: a channel per sender, its numbers, the sender's own declaration and type" do
    key = "asterism/host/@shared/spectate/t1/state"
    table = ->(d) { { "g/table" => { "f" => [ [ "st", d ] ] } } }
    decls = {
      [ key, "host/games" ] => [ { "t" => "g/table" }, table.("int") ],
      [ key, "host/room01" ] => [ { "t" => "g/table", "ts" => true }, table.("str") ],
      [ "asterism/@shared/lobby", "pc/chat" ] => [ { "t" => 7 }, {} ]
    }
    asked = []
    rec = recorder(declarations: ->(k, from) { asked << [ k, from ] && decls[[ k, from ]] }).open
    sample = ->(k, att) { Asterism::Zenoh::Sample.new(key: k, payload: MessagePack.pack(1), attachment: att && MessagePack.pack(att)) }
    rec.key("asterism/**", sample.(key, [ 4, nil, "host/games" ]))
    rec.key("asterism/**", sample.(key, [ 0, 1_791_440_000_500, "host/room01" ]))
    rec.key("asterism/**", sample.(key, [ 5, nil, "host/games" ]))
    rec.key("asterism/**", sample.(key, [ 1, nil ])) # no sender: the key alone
    rec.key("asterism/@shared/**", sample.("asterism/@shared/lobby", [ 9, nil, "pc/chat" ]))
    rec.key("asterism/**", sample.("asterism/host/games/x", [ 2, nil, "host/room01" ])) # an app's key: no third element read
    assert_equal 4, rec.progress["channel_counts"][key], "the senders' channels summed by topic"
    rec.finish
    assert_includes asked, [ key, "host/room01" ]
    assert_includes asked, [ "asterism/host/games/x", nil ]
    r = MCAP::Reader.new(@dir.join("r.mcap").to_s)
    assert r.verify!
    chans = r.info["channels"].select { _1["topic"] == key }
    assert_equal [ nil, "host/games", "host/room01" ], chans.map { _1["metadata"]["asterism_from"] }.sort_by(&:to_s)
    games = chans.find { _1["metadata"]["asterism_from"] == "host/games" }
    room = chans.find { _1["metadata"]["asterism_from"] == "host/room01" }
    assert_equal({ "t" => "g/table", "ts" => true }, JSON.parse(room["metadata"]["asterism_declaration"]))
    assert_equal [ "g/table", "asterism/types" ], room.values_at("schema", "schema_encoding")
    schemas = r.schemas.values.select { _1.name == "g/table" }.map { JSON.parse(_1.data) }
    assert_equal [ "int", "str" ], schemas.map { _1.dig("g/table", "f", 0, 1) }.sort, "each sender's own definition"
    lobby = r.info["channels"].find { _1["topic"] == "asterism/@shared/lobby" }
    assert_equal [ "pc/chat", "asterism/text", "asterism/@shared/**" ],
                 [ lobby["metadata"]["asterism_from"], lobby["schema"], lobby["metadata"]["asterism_key_expr"] ]
    refute r.info["channels"].find { _1["topic"] == "asterism/host/games/x" }["metadata"].key?("asterism_from")
    seqs = r.each_message.map { |m, ch, _| [ ch.metadata["asterism_from"], m.sequence ] if ch.topic == key }.compact
    assert_equal [ 4, 5 ], seqs.select { _1[0] == "host/games" }.map(&:last), "the numbers stay per sender"
    assert_equal [ 0 ], seqs.select { _1[0] == "host/room01" }.map(&:last)
    m = r.each_message.find { |_, ch, _| ch.metadata["asterism_from"] == "host/room01" }[0]
    assert_equal 1_791_440_000_500_000_000, m.publish_time
    v = Bag::View.new(@dir.join("r.mcap").to_s)
    assert_equal [ nil, "host/games", "host/room01" ], v.channels.select { _1["topic"] == key }.map { _1["from"] }.sort_by(&:to_s)
  ensure
    r&.close
    v&.close
  end

  test "the size limit: the message that would pass it is not written, and the reason is told" do
    rec = Bridge::Recorder.new(id: 2, path: @dir.join("s.mcap"), max_bytes: 4000, max_seconds: 60).open
    n = 0
    n += 1 while rec.key("k", Asterism::Zenoh::Sample.new(key: "k", payload: "x" * 100)) && n < 1000
    assert_match(/size limit/, rec.limit_reached)
    rec.finish
    assert_operator File.size(@dir.join("s.mcap")), :<=, 4000 + 1200 # the limit and the summary
    assert_equal n, MCAP::Reader.new(@dir.join("s.mcap").to_s).info["messages"]
  end

  test "the time limit" do
    rec = recorder.open
    assert_nil rec.limit_reached
    @now = 61.0
    assert_match(/time limit \(60 s\)/, rec.limit_reached)
    refute rec.ros(ros_sample(1.0, 1))
  end

  test "chunks are written about once a second, so a crash keeps what came before" do
    rec = recorder.open
    rec.ros(ros_sample(1.0, 1))
    @now = 1.5
    rec.tick
    r = MCAP::Reader.new(@dir.join("r.mcap").to_s)
    refute r.summary?
    assert_equal 1, r.info["messages"]
  end
end
