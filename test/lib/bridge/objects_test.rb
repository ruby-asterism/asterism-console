require "test_helper"
require "asterism"

# Bridge::Objects against the real object layer: a peer session of its own
# (no router), calling this process's own exposed object, which Asterism
# answers without the network but with the same encoding and checks.
class Bridge::ObjectsTest < ActiveSupport::TestCase
  class Screen
    def say(text, tag: nil) = "#{text}/#{tag}"
    def to_s = "the remote to_s"
  end

  setup do
    Asterism.connect(nil, node: "objtest", app: "t", mode: :peer, listen: "tcp/127.0.0.1:0", check_timeout: 0.2)
    Asterism.expose("screen", Screen.new, methods: %i[say to_s])
    @objects = Bridge::Objects.new
  end

  teardown { Asterism.close }

  test "meta, with the arities the page shows" do
    assert_equal %w[say to_s], @objects.meta("objtest/t/screen", timeout: 1.0)["methods"].map(&:first)
  end

  test "a call with arguments and keywords, time limit in seconds" do
    assert_equal "hi/x", @objects.call("objtest/t/screen", "say", [ "hi" ], { tag: "x" }, timeout: 1.0)
  end

  test "a remote method named like one of the proxy's own is the remote one" do
    assert_equal "the remote to_s", @objects.call("objtest/t/screen", "to_s", [], {}, timeout: 1.0)
    e = assert_raises(Asterism::RemoteError) { @objects.call("objtest/t/screen", "instance_eval", [ "1" ], {}, timeout: 1.0) }
    assert_equal "NoMethodError", e.remote_class
    assert_raises(ArgumentError) { @objects.call("objtest/t/screen", "to_ary", [], {}, timeout: 1.0) }
  end

  test "an object nobody exposes" do
    e = assert_raises(Asterism::RemoteError) { @objects.call("objtest/t/nobody", "x", [], {}, timeout: 0.3) }
    assert_equal "NameError", e.remote_class
  end
end
