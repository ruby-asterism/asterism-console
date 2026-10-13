require "test_helper"

class Relay::BrowserNodeTest < ActiveSupport::TestCase
  def user(handle, id = 1)
    User.new(id: id, email_address: "someone.else@example.org", handle: handle)
  end

  test "the name is the prefix and the handle, never the email address" do
    assert_equal "wasm-pat", Relay::BrowserNode.base(user("pat"), prefix: "wasm-")
    assert_equal "web-pat", Relay::BrowserNode.base(user("pat"), prefix: "web-")
    assert_nil Relay::BrowserNode.base(user(nil))
    assert_raises(ArgumentError) { Relay::BrowserNode.pick(user(nil), seen: Set.new, prefix: "wasm-") }
  end

  test "a second page gets the next free slot" do
    a = user("alice", 3)
    pick = ->(seen) { Relay::BrowserNode.pick(a, seen: seen.to_set, prefix: "wasm-") }
    assert_equal "wasm-alice", pick.([])
    assert_equal "wasm-alice_2", pick.(%w[wasm-alice])
    assert_equal "wasm-alice_3", pick.(%w[wasm-alice wasm-alice_2])
    assert_match(/\Awasm-alice_[0-9a-f]{3}\z/, pick.([ "wasm-alice", *(2..9).map { "wasm-alice_#{_1}" } ]))
  end
end
