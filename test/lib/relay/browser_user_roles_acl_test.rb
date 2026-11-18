require "test_helper"
require_relative "../../test_helpers/acl_evaluator"

# A user's own roles (0.4.2, RelayUserRole): the roles an admin picks for
# one user go to that user's certificate subjects only (wasm-<handle>, the
# page the door connects with the certificate), never to the other
# browsers or the shared ws/ subject; a browser entry without them makes
# the same rules as before.
class Relay::BrowserUserRolesAclTest < ActiveSupport::TestCase
  MATCH = { "name" => "match", "for_browsers" => true,
            "templates" => { "rw" => %w[asterism/${node} asterism/${node}/game/** asterism/${node}/@profile],
                             "read" => %w[asterism/* asterism/*/game/** asterism/*/@profile],
                             "ask" => %w[asterism/*/@profile asterism/*/game/*/meta asterism/*/game/*/call/${node}],
                             "watch" => %w[asterism/**] } }.freeze
  # The AI helper's devices (asterism-tutor docs/install.md).
  TUTOR = { "name" => "tutor", "for_browsers" => false,
            "templates" => { "rw" => %w[asterism/${node} asterism/${node}/ai_helper/** asterism/${node}/@profile],
                             "read" => %w[asterism/*/tutor/helper asterism/*/tutor/protocol/* asterism/*/tutor/helper/meta
                                          asterism/*/tutor/helper/call/${node}],
                             "ask" => %w[asterism/*/tutor/helper/meta asterism/*/tutor/helper/call/${node}],
                             "watch" => %w[asterism/**] } }.freeze
  HOST = { "name" => "tutor-host", "for_browsers" => false,
           "templates" => { "rw" => %w[asterism/${node} asterism/${node}/tutor/** asterism/${node}/@profile],
                            "watch" => %w[asterism/**] } }.freeze
  CALL = "asterism/tutor/tutor/helper/call".freeze

  def peers
    [ { "name" => "tutor", "kind" => "client", "roles" => [ "tutor-host" ], "in_acl" => true },
      { "name" => "fmruby-aaaaaa", "kind" => "client", "roles" => %w[match tutor], "in_acl" => true },
      { "name" => "fmruby-bbbbbb", "kind" => "client", "roles" => [ "match" ], "in_acl" => true } ]
  end

  def browsers(alice_roles = [ "tutor" ])
    alice = { "name" => "wasm-alice", "receives" => { "file" => [], "checkpoint" => [] }, "receivers_managed" => false }
    alice["roles"] = alice_roles if alice_roles
    [ alice, { "name" => "wasm-bob", "receives" => { "file" => [], "checkpoint" => [] }, "receivers_managed" => false } ]
  end

  def config(list = browsers)
    Relay::CloudConfig.new(peers, { "browsers" => "ws/[::]:7449", "browser_certs" => list }, roles: [ MATCH, TUTOR, HOST ])
  end

  def ok?(subject, message, key, flow: "ingress", a: @acl, link: nil)
    link ? AclEvaluator.allowed?(a, subject, message, flow, key, link: link) : AclEvaluator.allowed?(a, subject, message, flow, key)
  end

  setup { @acl = config.access_control }

  test "the user with the role finds the helper and calls it under its own name" do
    assert ok?("wasm-alice", "liveliness_token", "asterism/tutor/tutor/helper", flow: "egress"), "the helper's token reaches it"
    assert ok?("wasm-alice", "query", "#{CALL}/wasm-alice")
    assert ok?("wasm-alice", "reply", "#{CALL}/wasm-alice", flow: "egress"), "the answer reaches it"
    assert ok?("wasm-alice", "query", "asterism/tutor/tutor/helper/meta")
    assert ok?("wasm-alice", "liveliness_token", "asterism/wasm-alice/ai_helper/protocol/2"), "its own AI Helper app"
    refute ok?("wasm-alice", "query", "#{CALL}/wasm-bob"), "not as another browser"
    refute ok?("wasm-alice", "query", "#{CALL}/fmruby-aaaaaa"), "not as a member"
    refute ok?("wasm-alice", "query", "#{CALL}/wasm-alice", link: "quic"), "the call only through the tls subject"
    assert ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/game/table/call/wasm-alice"), "the browsers' roles still"
  end

  test "another user's browser and the shared ws/ pages do not reach the helper" do
    refute ok?("wasm-bob", "query", "#{CALL}/wasm-bob")
    refute ok?("wasm-bob", "query", "#{CALL}/wasm-alice")
    refute ok?("wasm-bob", "liveliness_token", "asterism/tutor/tutor/helper", flow: "egress")
    %w[wasm-alice wasm-carol wasm-bob].each do |n|
      refute ok?(:ws, "query", "#{CALL}/#{n}"), "ws/ as #{n}"
      refute ok?(:ws, "reply", "#{CALL}/#{n}", flow: "egress")
    end
    refute ok?(:ws, "liveliness_token", "asterism/tutor/tutor/helper", flow: "egress")
    refute ok?(:ws, "put", "asterism/wasm-alice/ai_helper/x"), "the role's own keys are not the ws/ pages'"
    assert ok?(:ws, "query", "asterism/fmruby-aaaaaa/game/table/call/wasm-alice"), "the ws/ pages keep what they had"
  end

  test "the members with the role and the tutor itself are as their rows say" do
    assert ok?("fmruby-aaaaaa", "query", "#{CALL}/fmruby-aaaaaa")
    refute ok?("fmruby-bbbbbb", "query", "#{CALL}/fmruby-bbbbbb")
    assert ok?("tutor", "declare_queryable", "asterism/tutor/tutor/**")
    assert ok?("tutor", "reply", "#{CALL}/wasm-alice")
  end

  test "without picks, or with none, the configuration is the one made before" do
    before = config(browsers(nil)).body
    assert_equal before, config(browsers([])).body
    assert_equal before, config(browsers([ "no-such-role" ])).body, "a role that is gone is left out"
    roles_for_all = Relay::CloudConfig.new(peers, { "browsers" => "ws/[::]:7449", "browser_certs" => browsers(nil) },
                                           roles: [ MATCH, TUTOR.merge("for_browsers" => true), HOST ])
    with_pick = Relay::CloudConfig.new(peers, { "browsers" => "ws/[::]:7449", "browser_certs" => browsers([ "tutor" ]) },
                                       roles: [ MATCH, TUTOR.merge("for_browsers" => true), HOST ])
    assert_equal roles_for_all.body, with_pick.body, "a pick of a role every browser has changes nothing"
  end

  test "a pick changes only that user's subjects" do
    a = config(browsers(nil)).access_control
    b = @acl
    others = ->(acl) { acl["policies"].reject { _1["id"].start_with?("browser__wasm_alice") } }
    assert_equal others.call(a), others.call(b)
    used = ->(acl) { others.call(acl).flat_map { _1["rules"] }.uniq.sort.map { |id| acl["rules"].find { _1["id"] == id } } }
    assert_equal used.call(a), used.call(b), "every rule of the others is the same"
  end
end
