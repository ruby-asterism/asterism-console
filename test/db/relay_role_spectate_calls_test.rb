require "test_helper"
require_relative "../test_helpers/acl_evaluator"
require_relative "../test_helpers/game_host_connections"
require Rails.root.join("db/migrate/20261113400000_relay_role_spectate_calls").to_s

# The spectator's calls on update: a role that reads the node places'
# spectate keys (<prefix>/@shared/spectate/**) may call the object
# "spectate" of the applications that put them (games and room<slot>),
# under its own name, and no other object. Lines are added only, roles
# without such a line stay, and again changes nothing.
class RelayRoleSpectateCallsTest < ActiveSupport::TestCase
  def fix(rw, read, ask) = RelayRoleSpectateCalls.with_spectate_calls(rw.join("\n"), read.join("\n"), ask.join("\n"))
  def lines(t) = t.transform_values { _1.split("\n") }

  CALLS = %w[asterism/*/games/spectate/call/${node} asterism/*/room$*/spectate/call/${node}].freeze
  # docs/rooms.md after the shared places' migration.
  SPECTATOR = [ [], %w[asterism/*/@shared/spectate/** asterism/*/games/@profile asterism/*/games/@pubs
                       asterism/*/room$*/@profile asterism/*/room$*/@pubs],
                %w[asterism/*/games/@profile asterism/*/room$*/@profile] ].freeze
  HOST = [ %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile asterism/${node}/*/@profile
              asterism/${node}/*/@status asterism/${node}/*/@pubs asterism/${node}/@shared/**
              asterism/${node}/room$* asterism/${node}/room$*/**],
           %w[asterism/*/game], [] ].freeze
  VIEWER = [ %w[asterism/${node}/** asterism/${node}/@profile],
             %w[asterism/** asterism/*/@profile asterism/*/*/@profile asterism/*/*/@status asterism/*/*/@pubs
                asterism/*/@shared/** asterism/@shared/**],
             %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@profile] ].freeze
  PLAYERS = [ [], %w[asterism/*/games/**], %w[asterism/*/games/*/call/${node} asterism/*/games/*/meta] ].freeze

  test "a spectator may call the senders' spectate object, read and ask" do
    t, notes = fix(*SPECTATOR)
    assert_equal SPECTATOR[1] + CALLS, lines(t)[:read]
    assert_equal SPECTATOR[2] + CALLS, lines(t)[:ask]
    assert_equal [], lines(t)[:rw]
    assert_equal CALLS.flat_map { [ "read + #{_1}", "ask + #{_1}" ] }, notes
  end

  test "a spectator's prefix is kept" do
    t, = fix([], %w[asterism/games/@shared/spectate/**], [])
    assert_equal %w[asterism/games/games/spectate/call/${node} asterism/games/room$*/spectate/call/${node}], lines(t)[:ask]
  end

  test "roles without the spectate keys' read line are left as they are" do
    [ HOST, VIEWER, PLAYERS, [ %w[asterism/${node}/@shared/spectate/**], [], [] ] ].each do |role|
      t, notes = fix(*role)
      assert_empty notes
      assert_equal({ rw: role[0], read: role[1], ask: role[2] }, lines(t))
    end
  end

  test "again: nothing changes" do
    t, = fix(*SPECTATOR)
    again, notes = RelayRoleSpectateCalls.with_spectate_calls(t[:rw], t[:read], t[:ask])
    assert_equal t, again
    assert_empty notes
  end

  test "on the database, through the router's rules: a spectator calls spectate (state) and no table object" do
    RelayRole.delete_all
    roles = { "games-host" => HOST, "spectator" => SPECTATOR, "viewer" => VIEWER, "games" => PLAYERS }
    rows = roles.to_h do |name, (rw, read, ask)|
      [ name, RelayRole.create!(name: name, rw_templates: rw.join("\n"), read_templates: read.join("\n"),
                                ask_templates: ask.join("\n"), watch_templates: "asterism/**") ]
    end
    peers = [ { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
              { "name" => "spectator-a", "kind" => "client", "roles" => %w[spectator], "in_acl" => true },
              { "name" => "admin-viewer", "kind" => "client", "roles" => %w[viewer], "in_acl" => true },
              { "name" => "player-a", "kind" => "client", "roles" => %w[games], "in_acl" => true } ]
    acl = -> { Relay::CloudConfig.new(peers, {}, roles: rows.values.map { _1.reload.to_config }).access_control }
    ok = ->(a, *q) { AclEvaluator.allowed?(a, *q) }
    spectate = %w[asterism/games/games/spectate/call/spectator-a asterism/games/room01/spectate/call/spectator-a]
    before = acl.()
    spectate.each { refute ok.(before, "spectator-a", "query", "ingress", _1), _1 }
    out = StringIO.new
    $stdout = out
    RelayRoleSpectateCalls.new.up
    $stdout = STDOUT
    assert_match(%r{relay role spectator \(spectate calls\): read \+ asterism/\*/games/spectate/call/\$\{node\}}, out.string)
    refute_match(/relay role (games|games-host|viewer) \(/, out.string)
    rows.each_value { assert _1.reload.valid?, _1.name }
    a = acl.()
    # spectate.state: a query on the object's call key under its own name, and its reply.
    spectate.each do |k|
      assert ok.(a, "spectator-a", "query", "ingress", k), k
      assert ok.(a, "spectator-a", "reply", "egress", k), k
      assert ok.(a, "games", "query", "egress", k), "the host's application gets it: #{k}"
      assert ok.(a, "games", "reply", "ingress", k), "and answers: #{k}"
    end
    refute ok.(a, "spectator-a", "query", "ingress", "asterism/games/games/spectate/call/player-a"), "not under another name"
    refute ok.(a, "spectator-a", "query", "ingress", "asterism/games/games/spectate/call/*"), "nor a wildcard caller"
    refute ok.(a, "spectator-a", "query", "ingress", "asterism/linux/demo/spectate/call/spectator-a"), "the senders' only"
    # No table object, no meta, no other room object.
    %w[asterism/games/games/mahjong1/call/spectator-a asterism/games/room01/mahjong1/call/spectator-a
       asterism/games/games/lobby/call/spectator-a asterism/games/games/spectate/meta].each do |k|
      refute ok.(a, "spectator-a", "query", "ingress", k), k
    end
    refute ok.(a, "spectator-a", "declare_queryable", "ingress", spectate[0]), "it answers nothing"
    assert_empty GameHostConnections.refused(a), "the host does all it did"
    out = StringIO.new
    $stdout = out
    RelayRoleSpectateCalls.new.up
    $stdout = STDOUT
    assert_empty out.string, "again: nothing to say"
  ensure
    $stdout = STDOUT
  end
end
