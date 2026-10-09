require "test_helper"
require "asterism"

# The bridge's side of recordings and playbacks: the rows it follows, what
# it subscribes to, the file it leaves, and the audit rows of a playback.
class Bridge::RunnerRecordingsTest < ActiveSupport::TestCase
  KEY = "0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_9c45bf16fe0983d80e3cfe750d6835843d265a9a6c46bd2e609fcddde6fb8d2a"

  class FakeSession
    Token = Struct.new(:key, :closed) do
      def close = (self.closed = true)
    end

    attr_reader :puts, :tokens

    def initialize
      @puts = []
      @tokens = []
    end

    def zid = "abcdef0123456789"
    def liveliness(key) = (@tokens << Token.new(key, false)).last
    def put(key, payload, attachment: nil) = @puts << [ key, payload, attachment ]
  end

  class FakeZenoh
    Sub = Struct.new(:expr, :block, :closed) do
      def close = (self.closed = true)
    end

    attr_reader :session, :puts, :subs

    def initialize
      @subs = []
      @session = FakeSession.new
      @puts = []
    end

    def subscribe(expr, depth: nil, &block) = (@subs << Sub.new(expr, block, false)).last
    def open_exprs = @subs.reject(&:closed).map(&:expr).sort

    def put(key, bytes) = @puts << [ key, bytes ]
    def zid = "abc"
    def router_zids = []
    def connection_count = 1

    def deliver_sample(sample)
      @subs.reject(&:closed).each { _1.block.call(sample) if Bridge::RunnerRecordingsTest.covers?(_1.expr, sample.key) }
    end
  end

  def self.covers?(expr, key)
    expr.end_with?("/**") ? key.start_with?(expr.delete_suffix("**")) : expr == key
  end

  setup do
    FileUtils.mkdir_p(Recording.dir)
    @z = FakeZenoh.new
    @said = []
    said = @said
    @runner = Bridge::Runner.new(objects: Object.new, logger: Logger.new(nil))
    @runner.define_singleton_method(:say) { |text| said << text }
    @runner.instance_variable_set(:@z, @z)
    @runner.instance_variable_get(:@ros_keys)[
      "@ros2_lv/0/abc/0/5/MP/%/%/teleop/%cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_9c/::,7:,:,:,,"] = true
    @twist = Bridge::Types.ros("geometry_msgs/msg/Twist")
    GraphState.current.update!(version: 3, snapshot: JSON.generate("nodes" => [ { "id" => "r_node:abc/0", "kind" => "r_node", "label" => "/teleop" } ], "edges" => []))
  end

  teardown { Recording.find_each(&:destroy) }

  def recording(**sel)
    r = Recording.new(user: users(:user), name: "test", status: "pending")
    r.selection_value = { "topics" => [ "r_topic:0/cmd_vel" ], "keys" => [ "demo/**" ], "structure" => true }.merge(sel.transform_keys(&:to_s))
    r.save!
    r
  end

  def twist_sample(x, seq)
    Asterism::Zenoh::Sample.new(key: KEY, payload: @twist.encode(linear: { x: x }),
                                attachment: Asterism::ROS::Attachment.new(seq, 1_791_000_000_000_000_000, "g" * 16).encode)
  end

  test "a recording: subscribed while it runs, progress in the row, a finished file when stopped" do
    r = recording
    @runner.send(:sync_recordings)
    assert_equal "recording", r.reload.status
    assert_equal [ "0/cmd_vel/**", "demo/**" ], @z.open_exprs
    5.times { @z.deliver_sample(twist_sample(_1 * 0.1, _1 + 1)) }
    @z.deliver_sample(Asterism::Zenoh::Sample.new(key: "demo/imu", payload: MessagePack.pack("a" => 1)))
    @runner.send(:report_recordings)
    assert_equal 7, r.reload.messages # 5 + 1 + the first snapshot
    assert_equal({ "/asterism/graph" => 1, "/cmd_vel" => 5, "demo/imu" => 1 }, r.channel_counts_value)
    r.stop!
    @runner.send(:sync_recordings)
    r.reload
    assert_equal [ "done", "stopped" ], [ r.status, r.stop_reason ]
    assert_empty @z.open_exprs
    assert_equal 7, r.info_value["messages"]
    reader = MCAP::Reader.new(r.path.to_s)
    assert reader.verify!
    cmd = reader.channels.values.find { _1.topic == "/cmd_vel" }
    assert_match(/depth: 7/, cmd.metadata["offered_qos_profiles"])
    reader.close
  end

  test "a limit ends it; the network structure follows the graph" do
    r = recording(keys: [], structure: true)
    @runner.send(:sync_recordings)
    rec = @runner.instance_variable_get(:@recorders)[r.id][:recorder]
    @runner.instance_variable_set(:@self_zids, [ "abc" ])
    @runner.instance_variable_get(:@ros_keys)["@ros2_lv/0/def/0/0/NN/%/%/listener"] = true
    @runner.send(:publish_graph)
    rec.instance_variable_set(:@max_seconds, 0)
    @runner.send(:sync_recordings)
    r.reload
    assert_equal "done", r.status
    assert_match(/time limit/, r.stop_reason)
    v = Bag::View.new(r.path.to_s)
    changes = v.graph_changes
    assert_equal %w[snapshot diff], changes.map { _1["kind"] }
    assert_includes changes[1]["added"], "r_node /listener"
    v.close
  end

  test "a row left recording by a bridge that stopped: its file gets a summary" do
    r = recording
    @runner.send(:sync_recordings)
    3.times { @z.deliver_sample(twist_sample(1.0, _1)) }
    rec = @runner.instance_variable_get(:@recorders)[r.id][:recorder]
    rec.instance_variable_get(:@writer).flush
    # A new bridge: it has no recorder for the row.
    @runner.instance_variable_set(:@recorders, {})
    @runner.send(:sync_recordings)
    r.reload
    assert_equal "done", r.status
    assert_match(/bridge stopped during the recording/, r.stop_reason)
    assert_equal 4, r.messages
    assert MCAP::Reader.new(r.path.to_s).verify!
  end

  test "the bridge stopping ends the recordings properly" do
    r = recording
    @runner.send(:sync_recordings)
    @runner.send(:stop_recordings, "the bridge stopped")
    assert_equal [ "done", "the bridge stopped" ], r.reload.values_at(:status, :stop_reason)
    assert MCAP::Reader.new(r.path.to_s).summary?
  end

  test "a playback: started by the bridge, followed, and its row says what was sent" do
    r = recording(keys: [ "demo/**" ], structure: false)
    @runner.send(:sync_recordings)
    3.times { @z.deliver_sample(twist_sample(_1.to_f, _1)) }
    r.stop!
    @runner.send(:sync_recordings)
    pb = Playback.create!(user: users(:admin), recording: r.reload, speed: 4.0)
    Bridge::Player.send(:remove_const, :DISCOVERY_WAIT) && Bridge::Player.const_set(:DISCOVERY_WAIT, 0.0)
    @runner.send(:sync_playbacks)
    assert_equal "running", pb.reload.status
    @runner.instance_variable_get(:@players)[pb.id].join(5)
    @runner.send(:sync_playbacks)
    pb.reload
    assert_equal [ "done", 3 ], [ pb.status, pb.messages_sent ]
    assert_equal 3, @z.session.puts.size
    assert(@said.any? { _1.include?("playback #{pb.id}: #{r.filename} at 4.0x (by admin@example.com)") })
  ensure
    Bridge::Player.send(:remove_const, :DISCOVERY_WAIT) && Bridge::Player.const_set(:DISCOVERY_WAIT, 1.0)
  end

  test "a playback the bridge did not pick up in time expires" do
    r = recording
    r.update_columns(status: "done")
    File.binwrite(r.path, "x")
    pb = Playback.new(user: users(:admin), recording: r, speed: 1.0)
    pb.save!(validate: false)
    pb.update_columns(created_at: 1.minute.ago)
    @runner.send(:sync_playbacks)
    assert_equal "failed", pb.reload.status
  end
end
