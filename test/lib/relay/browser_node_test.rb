require "test_helper"

class Relay::BrowserNodeTest < ActiveSupport::TestCase
  def user(email, id)
    User.new(id: id, email_address: email)
  end

  test "the name comes from the email address, made one key chunk" do
    assert_equal "alice", Relay::BrowserNode.slug(user("Alice@example.org", 1))
    assert_equal "a-b-c", Relay::BrowserNode.slug(user("..a.b+c..@example.org", 1))
    assert_equal "abcdefghijklmnopqrst", Relay::BrowserNode.slug(user("abcdefghijklmnopqrstuvwxyz@example.org", 1))
    assert_equal "user7", Relay::BrowserNode.slug(user("@example.org", 7))
  end

  test "two users with the same name: the later one gets .<id>" do
    a = user("alice@example.org", 3)
    b = user("alice@example.net", 9)
    assert_equal "wasm-alice", Relay::BrowserNode.base(a, prefix: "wasm-", users: [ a, b ])
    assert_equal "wasm-alice.9", Relay::BrowserNode.base(b, prefix: "wasm-", users: [ a, b ])
    assert_equal "web-alice", Relay::BrowserNode.base(a, prefix: "web-", users: [ a ])
  end

  test "a second page gets the next free slot" do
    a = user("alice@example.org", 3)
    pick = ->(seen) { Relay::BrowserNode.pick(a, seen: seen.to_set, prefix: "wasm-", users: [ a ]) }
    assert_equal "wasm-alice", pick.([])
    assert_equal "wasm-alice_2", pick.(%w[wasm-alice])
    assert_equal "wasm-alice_3", pick.(%w[wasm-alice wasm-alice_2])
    assert_match(/\Awasm-alice_[0-9a-f]{3}\z/, pick.([ "wasm-alice", *(2..9).map { "wasm-alice_#{_1}" } ]))
  end
end
