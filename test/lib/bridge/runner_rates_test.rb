require "test_helper"
require "asterism"

# How the bridge measures topic rates: what it subscribes to for the
# leases, what it broadcasts, and the stop when too much comes in (a
# stand-in for the Zenoh session).
class Bridge::RunnerRatesTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  KEY = "0/chatter/std_msgs::msg::dds_::String_/RIHS01_00"

  class FakeZenoh
    Sub = Struct.new(:expr, :block, :closed) do
      def close
        self.closed = true
      end
    end

    attr_reader :subs

    def initialize
      @subs = []
    end

    def subscribe(expr, &block)
      (@subs << Sub.new(expr, block, false)).last
    end

    def open_exprs
      @subs.reject(&:closed).map(&:expr).sort
    end

    def deliver(key, payload)
      @subs.reject(&:closed).each { _1.block.call(Asterism::Zenoh::Sample.new(key: key, payload: payload)) }
    end
  end

  setup do
    @z = FakeZenoh.new
    @runner = Bridge::Runner.new(objects: Object.new, logger: Logger.new(nil))
    @runner.define_singleton_method(:say) { |_text| nil }
    @runner.instance_variable_set(:@z, @z)
    @runner.instance_variable_get(:@ros_keys)["@ros2_lv/0/abc/0/0/NN/%/%/talker"] = true
    @runner.instance_variable_get(:@ros_keys)["@ros2_lv/7/def/0/0/NN/%/%/robot"] = true
  end

  def sync
    @runner.send(:sync_rates)
  end

  def cdr(text)
    "\x00\x01\x00\x00".b + [ text.bytesize + 1 ].pack("V") + text.b + "\x00".b
  end

  test "nothing is measured without a lease" do
    sync
    assert_empty @z.subs
    assert_no_broadcasts(ConsoleChannel::STREAM) { @runner.send(:publish_rates) }
  end

  test "all topics: one wildcard per ROS 2 domain; a single topic under it adds nothing" do
    RateLease.renew("*")
    RateLease.renew("r_topic:0/chatter")
    sync
    assert_equal [ "0/**", "7/**" ], @z.open_exprs
  end

  test "one topic while its details are open, then nothing" do
    RateLease.renew("r_topic:0/chatter")
    sync
    assert_equal [ "0/chatter/**" ], @z.open_exprs
    RateLease.update_all(expires_at: 1.second.ago)
    sync
    assert_empty @z.open_exprs
  end

  test "what arrives is counted and broadcast, what changed only" do
    RateLease.renew("r_topic:0/chatter")
    sync
    3.times { @z.deliver(KEY, cdr("hello")) }
    rates = nil
    assert_broadcasts(ConsoleChannel::STREAM, 1) { @runner.send(:publish_rates) }
    rates = broadcasts(ConsoleChannel::STREAM).last
    msg = ActiveSupport::JSON.decode(rates)
    assert_equal "rates", msg["type"]
    assert_equal 3, msg["rates"]["r_topic:0/chatter"]["count"]
    assert_equal '"hello"', msg["rates"]["r_topic:0/chatter"]["text"]
    assert_equal [ "0/chatter/**" ], msg["status"]["measuring"]
    assert_no_broadcasts(ConsoleChannel::STREAM) { @runner.send(:publish_rates) }
  end

  test "dropping the wildcard forgets the topics it measured" do
    RateLease.renew("*")
    sync
    @z.deliver(KEY, cdr("x"))
    @z.deliver("7/scan/sensor_msgs::msg::dds_::LaserScan_/RIHS01_00", "\x00\x01\x00\x00".b)
    RateLease.renew("r_topic:0/chatter")
    RateLease.where(key: "*").update_all(expires_at: 1.second.ago)
    sync
    assert_equal [ "0/chatter/**" ], @z.open_exprs
    assert_equal 1, @runner.instance_variable_get(:@rates).size
  end

  test "too much coming in pauses all topics; single topics go on" do
    RateLease.renew("*")
    RateLease.renew("r_topic:0/chatter")
    sync
    @runner.instance_variable_get(:@rates).define_singleton_method(:total_bps) { 100_000_000 }
    @runner.send(:publish_rates)
    msg = ActiveSupport::JSON.decode(broadcasts(ConsoleChannel::STREAM).last)
    assert_operator msg["status"]["paused_s"], :>, 50
    assert_empty @z.open_exprs
    sync
    assert_equal [ "0/chatter/**" ], @z.open_exprs, "paused: the wildcard is not taken again"
  end
end
