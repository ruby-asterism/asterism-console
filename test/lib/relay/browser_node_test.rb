require "test_helper"

class Relay::BrowserNodeTest < ActiveSupport::TestCase
  def user(handle, id = 1)
    User.new(id: id, email_address: "someone.else@example.org", handle: handle)
  end

  test "the name is the prefix and the handle, never the email address" do
    assert_equal "wasm-pat", Relay::BrowserNode.base(user("pat"), prefix: "wasm-")
    assert_equal "web-pat", Relay::BrowserNode.base(user("pat"), prefix: "web-")
    assert_nil Relay::BrowserNode.base(user(nil))
    assert_raises(ArgumentError) { Relay::BrowserNode.pick(user(nil), prefix: "wasm-") }
  end

  # T8c: a page opened later takes the name over (the door), so the console
  # never hands out _2 and the like.
  test "every page gets the user's own name" do
    a = user("alice", 3)
    assert_equal "wasm-alice", Relay::BrowserNode.pick(a, prefix: "wasm-")
    assert_equal "wasm-alice", Relay::BrowserNode.pick(a, prefix: "wasm-")
  end
end
