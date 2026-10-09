require "test_helper"
require "asterism"

# What the bridge subscribes to for the plot and log pages' leases, what it
# tells them, and that it stops when they close (a stand-in for the Zenoh
# session).
class Bridge::RunnerStreamsTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  CMD_VEL = "0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_00"

  # Delivers a sample to the subscriptions whose key expression matches it.
  class MatchingZenoh < Bridge::RunnerRatesTest::FakeZenoh
    def deliver(key, payload)
      @subs.reject(&:closed).select { matches?(_1.expr, key) }.each do |s|
        s.block.call(Asterism::Zenoh::Sample.new(key: key, payload: payload))
      end
    end

    def matches?(expr, key)
      re = expr.split("/").map { |c| c == "**" ? ".*" : c == "*" ? "[^/]+" : Regexp.escape(c) }.join("/").gsub("/.*", "(/.*)?")
      key.match?(/\A#{re}\z/)
    end
  end

  setup do
    @z = MatchingZenoh.new
    @runner = Bridge::Runner.new(objects: Object.new, logger: Logger.new(nil))
    @said = []
    said = @said
    @runner.define_singleton_method(:say) { |text| said << text }
    @runner.instance_variable_set(:@z, @z)
    @runner.instance_variable_get(:@ros_keys)["@ros2_lv/0/abc/0/0/NN/%/%/talker"] = true
    @runner.instance_variable_set(:@topic_types, "r_topic:0/cmd_vel" => "geometry_msgs/msg/Twist",
                                                 "r_topic:0/mesh" => "shape_msgs/msg/Mesh")
    Bridge::Types.setup
    @twist = Bridge::Types.ros("geometry_msgs/msg/Twist")
  end

  def lease(kind, page, wanted)
    StreamLease.renew_page(kind: kind, page: page, wanted: wanted)
  end

  def plots_broadcasts
    broadcasts("console:plots").map { ActiveSupport::JSON.decode(_1) }
  end

  test "nothing is subscribed without a lease" do
    @runner.send(:sync_plots)
    @runner.send(:sync_logs)
    assert_empty @z.subs
  end

  test "a plot lease: the topic is subscribed, its fields reach the page, decimated; release stops it" do
    lease("plot", "page-aaaaaaaa", [ { "target" => "r_topic:0/cmd_vel", "fields" => [ "linear.x" ] } ])
    @runner.send(:sync_plots)
    assert_equal [ "0/cmd_vel/**" ], @z.open_exprs
    meta = plots_broadcasts.find { _1["type"] == "plot_meta" }["meta"]
    assert_equal "geometry_msgs/msg/Twist", meta["type"]
    assert_includes meta["fields"].map { _1["path"] }, "angular.z"
    assert_equal meta, StreamLease.last.meta_value, "the lease row carries it too"
    20.times { |i| @z.deliver(CMD_VEL, @twist.encode(linear: { x: i * 0.1 })) }
    @runner.send(:publish_plots)
    pts = plots_broadcasts.find { _1["type"] == "plot" }["points"]["r_topic:0/cmd_vel"]
    assert_equal 20, pts["received"]
    assert_equal 1, pts["t"].size, "20 messages in the same 1/30 s"
    assert_equal [ 0.0 ], pts["v"]["linear.x"]
    StreamLease.release(kind: "plot", page: "page-aaaaaaaa")
    @runner.send(:sync_plots)
    assert_empty @z.open_exprs
    assert(@said.any? { _1.include?("plots: stop 0/cmd_vel/**") })
  end

  test "two pages on one topic: one subscription, the fields of both" do
    lease("plot", "page-aaaaaaaa", [ { "target" => "r_topic:0/cmd_vel", "fields" => [ "linear.x" ] } ])
    lease("plot", "page-bbbbbbbb", [ { "target" => "r_topic:0/cmd_vel", "fields" => [ "angular.z" ] } ])
    @runner.send(:sync_plots)
    assert_equal [ "0/cmd_vel/**" ], @z.open_exprs
    assert_equal %w[linear.x angular.z], @runner.instance_variable_get(:@plots).fields("r_topic:0/cmd_vel")
  end

  test "a type that is not bundled, or a topic not on the network: told, not subscribed" do
    lease("plot", "page-aaaaaaaa", [ { "target" => "r_topic:0/mesh", "fields" => [] },
                                     { "target" => "r_topic:0/nowhere", "fields" => [] } ])
    @runner.send(:sync_plots)
    assert_empty @z.subs
    metas = plots_broadcasts.select { _1["type"] == "plot_meta" }.to_h { [ _1["meta"]["target"], _1["meta"] ] }
    assert_match(/shape_msgs\/msg\/Mesh is not bundled/, metas["r_topic:0/mesh"]["error"])
    assert_match(/not on the network/, metas["r_topic:0/nowhere"]["error"])
  end

  test "an Asterism key is plotted from MessagePack" do
    lease("plot", "page-aaaaaaaa", [ { "target" => "key:demo/imu", "fields" => [ "accel[2]" ] } ])
    @runner.send(:sync_plots)
    assert_equal [ "demo/imu" ], @z.open_exprs
    @z.deliver("demo/imu", MessagePack.pack("accel" => [ 0, 0, 9.8 ]))
    @runner.send(:publish_plots)
    assert_equal [ 9.8 ], plots_broadcasts.find { _1["type"] == "plot" }["points"]["key:demo/imu"]["v"]["accel[2]"]
  end

  test "a log lease: /rosout of each domain and the Asterism log keys, until it ends" do
    lease("log", "page-aaaaaaaa", [ { "target" => "*" } ])
    @runner.send(:sync_logs)
    assert_equal [ "0/rosout/**", "asterism/*/*/log" ], @z.open_exprs
    log = Bridge::Types.ros("rcl_interfaces/msg/Log")
    @z.deliver("0/rosout/rcl_interfaces::msg::dds_::Log_/RIHS01_00", log.encode(level: 20, name: "talker", msg: "Hello"))
    @z.deliver("asterism/linux/demo/log", MessagePack.pack("level" => "warn", "msg" => "low battery"))
    @runner.send(:publish_logs)
    msg = ActiveSupport::JSON.decode(broadcasts("console:logs").last)
    assert_equal [ %w[INFO talker Hello], [ "WARN", "linux/demo", "low battery" ] ],
                 msg["lines"].map { _1.values_at("level", "name", "msg") }
    StreamLease.where(kind: "log").update_all(expires_at: 1.second.ago)
    @runner.send(:sync_logs)
    assert_empty @z.open_exprs
    assert(@said.any? { _1.include?("logs: stop 0/rosout/**") })
  end
end
