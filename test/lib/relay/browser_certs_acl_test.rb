require "test_helper"
require "tmpdir"
require_relative "../../test_helpers/acl_evaluator"

# Browsers the router tells apart (T8, docs/g1_5.md): the ACL
# Relay::CloudConfig makes for a user's browser with a certificate
# (wasm-<handle>), for the shared ws/ subject beside it, and for files
# between them and the members, asked with zenohd's own way of deciding
# (test_helpers/acl_evaluator.rb).
class Relay::BrowserCertsAclTest < ActiveSupport::TestCase
  MATCH = { "name" => "match", "for_browsers" => true,
            "templates" => { "rw" => %w[asterism/${node} asterism/${node}/game/** asterism/${node}/@profile],
                             "read" => %w[asterism/* asterism/*/game/** asterism/*/@profile],
                             "ask" => %w[asterism/*/@profile asterism/*/game/*/meta asterism/*/game/*/call/${node}],
                             "watch" => %w[asterism/**] } }.freeze

  def peers
    [ { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "admin_space" => true, "in_acl" => true },
      { "name" => "fmruby-aaaaaa", "kind" => "client", "roles" => [ "match" ], "in_acl" => true,
        "receives" => { "file" => %w[wasm-alice], "checkpoint" => [] }, "receivers_managed" => true },
      { "name" => "fmruby-bbbbbb", "kind" => "client", "roles" => [ "match" ], "in_acl" => true } ]
  end

  def browsers
    [ { "name" => "wasm-alice", "receives" => { "file" => %w[fmruby-bbbbbb wasm-bob], "checkpoint" => [] },
        "receivers_managed" => true },
      { "name" => "wasm-bob", "receives" => { "file" => [], "checkpoint" => [] }, "receivers_managed" => false } ]
  end

  def config(list = browsers, peer_list = peers)
    Relay::CloudConfig.new(peer_list, { "browsers" => "ws/[::]:7449", "browser_certs" => list }, roles: [ MATCH ])
  end

  def ok?(subject, message, key, flow: "ingress", a: @acl, link: nil)
    link ? AclEvaluator.allowed?(a, subject, message, flow, key, link: link) : AclEvaluator.allowed?(a, subject, message, flow, key)
  end

  setup { @acl = config.access_control }

  test "a browser with a certificate writes under its own name, and its roles work for it as for a browser" do
    assert ok?("wasm-alice", "put", "asterism/wasm-alice/game/othello/state")
    assert ok?("wasm-alice", "liveliness_token", "asterism/wasm-alice/game")
    refute ok?("wasm-alice", "put", "asterism/wasm-bob/game/othello/state"), "another browser's name"
    refute ok?("wasm-alice", "put", "asterism/fmruby-aaaaaa/game/x"), "a member's name"
    assert ok?("wasm-alice", "declare_subscriber", "asterism/*/game/**")
    assert ok?("wasm-alice", "put", "asterism/fmruby-aaaaaa/game/x", flow: "egress"), "it reads the others"
    assert ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/game/table/meta")
    assert ok?("wasm-alice", "declare_liveliness_subscriber", "asterism/**")
  end

  test "it calls under its own name only (the second subject, on tls)" do
    assert ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/game/table/call/wasm-alice")
    refute ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/game/table/call/wasm-bob"), "as another browser"
    refute ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/game/table/call/fmruby-bbbbbb"), "as a member"
    refute ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/game/table/call/*"), "a wildcard caller"
    refute ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/game/table/call/wasm-alice", link: "quic"),
           "only the tls subject lets the call through"
    refute ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/shell/sh/call/wasm-alice"), "no app its roles do not ask"
  end

  test "the shared ws/ subject keeps its roles but no transfer key" do
    assert ok?(:ws, "put", "asterism/wasm-carol/game/x")
    assert ok?(:ws, "query", "asterism/fmruby-aaaaaa/game/table/call/wasm-carol")
    assert ok?(:ws, "query", "asterism/fmruby-aaaaaa/game/table/call/wasm-alice"),
           "a page without a certificate still calls under any browser's name (as before)"
    refute ok?(:ws, "query", "asterism/fmruby-aaaaaa/transfer/inbox/call/wasm-alice"), "no file sent from ws/"
    refute ok?(:ws, "declare_queryable", "asterism/wasm-alice/transfer/inbox/**"), "no inbox on ws/"
    refute ok?(:ws, "liveliness_token", "asterism/wasm-alice/transfer")
    refute ok?(:ws, "put", "asterism/wasm-alice/transfer/x", flow: "egress")
    refute ok?(:ws, "reply", "asterism/fmruby-aaaaaa/transfer/inbox/call/wasm-carol", flow: "egress")
  end

  test "the deny holds against a role that lets browsers do everything" do
    wide = { "name" => "wide", "for_browsers" => true, "templates" => { "rw" => %w[asterism/**], "ask" => %w[asterism/**] } }
    a = Relay::CloudConfig.new(peers, { "browsers" => "ws/[::]:7449", "browser_certs" => browsers }, roles: [ wide ]).access_control
    assert ok?(:ws, "put", "asterism/fmruby-aaaaaa/game/x", a: a)
    refute ok?(:ws, "query", "asterism/fmruby-aaaaaa/transfer/inbox/call/wasm-carol", a: a)
    refute ok?(:ws, "declare_queryable", "asterism/wasm-carol/transfer/inbox/**", a: a)
    refute ok?("wasm-alice", "query", "asterism/fmruby-bbbbbb/game/t/call/wasm-bob", a: a), "no call as another, whatever the role"
    refute ok?("wasm-alice", "query", "asterism/fmruby-bbbbbb/transfer/inbox/call/wasm-alice", a: a), "not chosen by fmruby-bbbbbb"
  end

  test "files: a member receives from a browser, a browser from a member and from another browser" do
    # fmruby-aaaaaa takes files from wasm-alice
    assert ok?("wasm-alice", "query", "asterism/fmruby-aaaaaa/transfer/inbox/call/wasm-alice")
    assert ok?("wasm-alice", "reply", "asterism/fmruby-aaaaaa/transfer/inbox/call/wasm-alice", flow: "egress")
    refute ok?("wasm-bob", "query", "asterism/fmruby-aaaaaa/transfer/inbox/call/wasm-bob"), "not chosen"
    refute ok?("wasm-bob", "query", "asterism/fmruby-aaaaaa/transfer/inbox/call/wasm-alice"), "as the chosen one"
    # wasm-alice takes files from fmruby-bbbbbb and wasm-bob
    assert ok?("wasm-alice", "declare_queryable", "asterism/wasm-alice/transfer/inbox/**")
    assert ok?("wasm-alice", "liveliness_token", "asterism/wasm-alice/transfer")
    assert ok?("fmruby-bbbbbb", "query", "asterism/wasm-alice/transfer/inbox/call/fmruby-bbbbbb")
    assert ok?("wasm-bob", "query", "asterism/wasm-alice/transfer/inbox/call/wasm-bob")
    refute ok?("wasm-bob", "query", "asterism/wasm-alice/transfer/inbox/call/fmruby-bbbbbb"), "a member's name"
    refute ok?("fmruby-aaaaaa", "query", "asterism/wasm-alice/transfer/inbox/call/fmruby-aaaaaa"), "not chosen"
    # wasm-bob's lists were never chosen: no inbox
    refute ok?("wasm-bob", "declare_queryable", "asterism/wasm-bob/transfer/inbox/**")
    # the console sends the list (its asterism/**)
    assert ok?("console", "query", "asterism/wasm-alice/transfer/inbox/call/console")
  end

  test "a pattern matches the browsers too, and a browser is not its own sender" do
    list = [ browsers[0].merge("receives" => { "file" => %w[*], "checkpoint" => [] }), browsers[1] ]
    a = config(list).access_control
    assert ok?("wasm-bob", "query", "asterism/wasm-alice/transfer/inbox/call/wasm-bob", a: a)
    assert ok?("fmruby-aaaaaa", "query", "asterism/wasm-alice/transfer/inbox/call/fmruby-aaaaaa", a: a)
    refute(config(list).to_h["access_control"]["rules"].any? { _1["key_exprs"].include?("asterism/wasm-alice/transfer/inbox/call/wasm-alice") })
  end

  test "before the apply (no certificate in the configuration) a tls session of that name may do nothing" do
    a = config([]).access_control
    refute ok?("wasm-alice", "put", "asterism/wasm-alice/game/x", a: a)
    refute ok?("wasm-alice", "declare_subscriber", "asterism/*/game/**", a: a)
    refute ok?("fmruby-bbbbbb", "query", "asterism/wasm-alice/transfer/inbox/call/fmruby-bbbbbb", a: a)
  end

  test "a registry row with a browser's name is left out; the name is the browser's" do
    rows = peers + [ { "name" => "wasm-alice", "kind" => "client", "rw" => %w[asterism/**], "in_acl" => true } ]
    a = config(browsers, rows).access_control
    refute ok?("wasm-alice", "put", "asterism/fmruby-aaaaaa/x", a: a)
    assert_equal 1, a["subjects"].count { _1["cert_common_names"] == [ "wasm-alice" ] && _1["link_protocols"].nil? }
  end

  test "the door's list: the names the configuration lets in whose files are here" do
    Dir.mktmpdir do |dir|
      env = { "ASTERISM_ROOMS_DIR" => dir }
      d = Relay::BrowserCerts.dir(env)
      ca = Relay::CertAuthority.create(File.join(dir, "ca"))
      FileUtils.mkdir_p(d)
      %w[wasm-alice wasm-bob].each do |n|
        ca.issue(n)
        %w[pem key].each { FileUtils.cp(File.join(dir, "ca", "#{n}.#{_1}"), d) }
      end
      text = config([ browsers[0] ]).text
      assert_equal [ "wasm-alice" ], Relay::BrowserCerts.write_door_file!(text, env: env)
      assert_equal [ "wasm-alice" ], JSON.parse(File.read(Relay::BrowserCerts.door_file(env)))["nodes"]
      assert_equal [], Relay::BrowserCerts.write_door_file!(config([]).text, env: env), "before the apply"
    end
  end
end
