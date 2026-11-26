require "test_helper"

# The remote shell's permissions outside the Terminal (docs/terminal.md):
# the members' and browsers' mark sent with the lists (kind rshell), the
# router's ACL (no other subject calls a remote shell; the machines' own
# keys come with the lists'), the call permissions that never cover it, and
# the users' permission chosen by an admin.
class Relay::RShellMarksTest < ActionDispatch::IntegrationTest
  def acl(peers, roles: [], **settings)
    Relay::CloudConfig.new(peers, settings, roles: roles).access_control
  end

  def policy(acl, id) = acl["policies"].find { _1["id"] == id }&.dig("rules")

  test "the mark goes with the lists as rshell: the console, or nobody; it makes the row managed" do
    tab5 = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client")
    refute tab5.managed_receivers?
    assert_equal [], tab5.receivers_payload["rshell"]
    tab5.update!(rshell_from_console: true)
    assert tab5.managed_receivers?, "sent to it from now on (and its transfer keys in the ACL)"
    assert_equal [ "console" ], tab5.receivers_payload["rshell"]
    assert_equal({ "file" => [], "checkpoint" => [] }, tab5.receives_config, "not an inbox sender's list")
    assert_includes tab5.to_config.keys, "receivers_managed"
    assert_equal true, tab5.to_config["receivers_managed"]
    d = tab5.receivers_digest
    tab5.update!(rshell_from_console: false)
    refute_equal d, tab5.receivers_digest, "cleared: the empty list goes to it"
    assert_equal [], tab5.receivers_payload["rshell"]

    users(:user).update!(rshell_from_console: true)
    assert_equal [ "console" ], users(:user).receivers_payload["rshell"]
    assert_includes RelayPeer.rshell_nodes, "wasm-pat"
  end

  test "the Members and Browsers forms take the mark" do
    sign_in_as(users(:admin))
    peer = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client")
    patch relay_peer_path(peer), params: { relay_peer: { rshell_from_console: "1" } }
    assert peer.reload.rshell_from_console?
    get relay_peers_path
    assert_match(/remote shell/, response.body)
    patch relay_browser_path(users(:user)), params: { user: { rshell_from_console: "1" } }
    assert users(:user).reload.rshell_from_console?
  end

  test "the ACL: every subject that could query a remote shell is denied it, the console is not" do
    peers = [ { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "in_acl" => true },
              { "name" => "pc", "kind" => "client", "roles" => %w[caller], "in_acl" => true },
              { "name" => "calc", "kind" => "client", "roles" => %w[calc], "in_acl" => true },
              { "name" => "fmruby-aaaaaa", "kind" => "client", "in_acl" => true, "receivers_managed" => true } ]
    roles = [ { "name" => "caller", "templates" => { "ask" => %w[asterism/*/*/*/call/${node}] } },
              { "name" => "calc", "templates" => { "ask" => %w[asterism/*/calc/*/call/${node}] } } ]
    a = acl(peers, roles: roles)
    refute_includes policy(a, "console"), "no_rshell_calls"
    assert_includes policy(a, "pc"), "no_rshell_calls"
    refute_includes policy(a, "calc"), "no_rshell_calls", "its calls never reach transfer/rshell"
    assert_includes policy(a, "fmruby_aaaaaa"), "no_rshell_calls", "its transfer rw would let it query its own"
    assert_includes policy(a, "fmruby_aaaaaa"), "fmruby_aaaaaa__receives_files_rw", "its queryable's keys"
    rule = a["rules"].select { _1["id"] == "no_rshell_calls" }
    assert_equal 1, rule.size, "one shared rule"
    assert_equal [ "deny", %w[query], %w[ingress], Relay::CloudConfig::RSHELL_KEYS ],
                 rule[0].values_at("permission", "messages", "flows", "key_exprs")

    b = acl([], roles: roles.map { _1.merge("for_browsers" => true) },
            "browser_certs" => [ { "name" => "wasm-pat", "receives" => {}, "receivers_managed" => true } ])
    assert_includes policy(b, "browser__wasm_pat"), "no_rshell_calls"
    assert_includes policy(b, "browser__wasm_pat_calls"), "no_rshell_calls", "both subjects of its certificate"
  end

  test "key expressions meet chunk by chunk" do
    meet = ->(a, b) { Relay::CloudConfig.keys_meet?(a, b) }
    assert meet.("asterism/**", "asterism/*/transfer/rshell/**")
    assert meet.("asterism/*/*/*/call/pc", "asterism/*/transfer/rshell/**")
    assert meet.("asterism/fmruby-a/transfer/**", "asterism/*/transfer/rshell/**")
    assert meet.("asterism/fmruby-a/transfer", "asterism/*/transfer/rshell/**") == false
    assert meet.("asterism/wasm-$*/**", "asterism/*/transfer/rshell/**")
    refute meet.("asterism/*/calc/*/call/pc", "asterism/*/transfer/rshell/**")
    refute meet.("room/01/**", "asterism/*/transfer/rshell/**")
    assert meet.("asterism/*/transfer/rshell", "asterism/*/transfer/rshell")
  end

  test "no call permission covers a remote shell, from the page or the Terminal's call" do
    CallPermission.create!(node: "*", app: "*", object: "*", method_name: "*")
    refute CallPermission.allows?("fmruby-aaaaaa/transfer/rshell", "open")
    refute CallPermission.allows?("fmruby-aaaaaa/transfer/rshell")
    assert_empty CallPermission.for_path("fmruby-aaaaaa/transfer/rshell")
    assert CallPermission.allows?("fmruby-aaaaaa/transfer/inbox", "status")
    line = Terminal::Line.check("call fmruby-aaaaaa/transfer/rshell exec_write 1 \"rm x\"")
    assert_match(/a machine's remote shell: only the Terminal's remote <node>/, line.reason)

    sign_in_as(users(:admin))
    post bridge_requests_path, params: { kind: "call", path: "fmruby-aaaaaa/transfer/rshell", method_name: "open" }, as: :json
    req = BridgeRequest.last
    assert_equal "denied", req.status
    assert_match(/remote shell/, req.error_message)
  end

  test "an admin chooses each user's remote shell, their own included" do
    sign_in_as(users(:admin))
    get admin_users_path
    assert_select "select[name=rshell_access]", 2
    patch rshell_admin_user_path(users(:admin)), params: { rshell_access: "write" }
    assert_equal "write", users(:admin).reload.rshell_access
    patch rshell_admin_user_path(users(:user)), params: { rshell_access: "read" }
    assert_equal "read", users(:user).reload.rshell_access
    patch rshell_admin_user_path(users(:user)), params: { rshell_access: "root" }
    assert_equal "read", users(:user).reload.rshell_access
    sign_in_as(users(:user))
    patch rshell_admin_user_path(users(:user)), params: { rshell_access: "write" }
    assert_equal "read", users(:user).reload.rshell_access, "not by a user"
  end
end
