require "test_helper"
require "asterism"

# The bridge's liveliness watches and admin-space gets when asterism-zenoh's
# queues drop entries (a stand-in for the Zenoh session).
class Bridge::RunnerFollowTest < ActiveSupport::TestCase
  class FakeZenoh
    Raw = Struct.new(:dropped)
    Watch = Struct.new(:pattern, :depth, :block, :watch, :closed) do
      def close
        self.closed = true
      end
    end
    Reply = Struct.new(:key, :payload) do
      def error? = false
    end

    class Get
      def initialize(replies, dropped)
        @replies = replies
        @dropped = dropped
      end

      attr_reader :dropped

      def done? = true
      def pending = 0

      def each_result
        r = @replies
        @replies = []
        r
      end
    end

    attr_reader :watches, :gets
    attr_accessor :replies, :dropped

    def initialize
      @watches = []
      @gets = []
      @replies = []
      @dropped = 0
    end

    def liveliness_watch(pattern, depth:, &block)
      (@watches << Watch.new(pattern, depth, block, Raw.new(0), false)).last
    end

    def session = self

    def get(key, timeout:)
      @gets << [ key, timeout ]
      Get.new(@replies, @dropped)
    end
  end

  setup do
    @z = FakeZenoh.new
    @runner = Bridge::Runner.new(objects: Object.new, logger: Logger.new(nil))
    @said = []
    said = @said
    @runner.define_singleton_method(:say) { |text| said << text }
    @runner.instance_variable_set(:@z, @z)
    @set = @runner.instance_variable_get(:@ros_keys)
  end

  test "a watch is declared with a deep queue, and again when it dropped changes" do
    @runner.send(:follow, "@ros2_lv/**", @set)
    w = @z.watches.last
    assert_equal Bridge::Runner::LIVELINESS_DEPTH, w.depth
    w.block.call("@ros2_lv/0/a/0/0/NN/%/%/talker", true)
    assert @set.key?("@ros2_lv/0/a/0/0/NN/%/%/talker")

    @runner.send(:check_follows)
    assert_equal 1, @z.watches.size, "nothing dropped: the same watch"

    w.watch.dropped = 3
    @runner.send(:check_follows)
    assert w.closed
    assert_equal 2, @z.watches.size
    assert_empty @set, "the old set is forgotten; the new watch reports the tokens alive now"
    assert_match(/3 changes dropped, following it again/, @said.last)
    @z.watches.last.block.call("@ros2_lv/0/b/0/0/NN/%/%/listener", true)
    assert_equal [ "@ros2_lv/0/b/0/0/NN/%/%/listener" ], @set.keys
  end

  test "an admin-space get says when replies were dropped, once" do
    @z.replies = [ FakeZenoh::Reply.new("@/z1/router", '{"zid":"z1"}') ]
    assert_equal [ [ "@/z1/router", '{"zid":"z1"}' ] ], @runner.send(:get_raw, "@/*/router")
    assert_empty @said
    @z.dropped = 5
    @runner.send(:get_raw, "@/*/router/token/**")
    @runner.send(:get_raw, "@/*/router/token/**")
    assert_equal 1, @said.grep(/5 replies dropped/).size
    @z.dropped = 0
    @runner.send(:get_raw, "@/*/router/token/**")
    @z.dropped = 2
    @runner.send(:get_raw, "@/*/router/token/**")
    assert_equal 1, @said.grep(/2 replies dropped/).size, "said again after a get without drops"
    assert_equal [ "@/*/router", Bridge::Runner::GET_TIMEOUT ], @z.gets.first
  end
end
