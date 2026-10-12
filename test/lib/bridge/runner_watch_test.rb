require "test_helper"
require "asterism"

# The watch panel's limits: at most WATCH_RATE values per key and second,
# and a heavy value (a camera picture) at most WATCH_HEAVY_RATE a second.
class Bridge::RunnerWatchTest < ActiveSupport::TestCase
  setup do
    @runner = Bridge::Runner.new(objects: Object.new, logger: Logger.new(nil))
    @runner.instance_variable_set(:@outbox, @out = [])
  end

  def sample(bytes)
    Asterism::Zenoh::Sample.new(key: "demo/cam", payload: "x" * bytes)
  end

  test "light values: up to 10 a second" do
    30.times { @runner.send(:watched, 1, sample(10)) }
    assert_includes 10..20, @out.size, "10 in one second (20 when the loop crosses a second)"
  end

  test "heavy values: at most 2 a second, the rest counted as dropped" do
    20.times { @runner.send(:watched, 2, sample(Bridge::Runner::WATCH_HEAVY_BYTES + 1)) }
    assert_equal 1, @out.size, "one at once, the next after half a second"
    assert_equal 0, @out.first["dropped"]
    sleep 0.55
    @runner.send(:watched, 2, sample(Bridge::Runner::WATCH_HEAVY_BYTES + 1))
    assert_equal 2, @out.size
    assert_equal 19, @out.last["dropped"]
  end
end
