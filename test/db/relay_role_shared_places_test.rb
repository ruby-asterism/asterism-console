require "test_helper"
require_relative "../test_helpers/acl_evaluator"
require_relative "../test_helpers/game_host_connections"
require Rails.root.join("db/migrate/20261113300000_relay_role_shared_places").to_s

# The roles of a console made before the shared places (protocol 2,
# asterism docs/protocol.md 17) on update: the example role reads the
# network's place, a viewer both places, the game host writes its node's
# place and its rooms' applications, a spectator's spectate lines become
# the node places' spectate keys and the senders' declarations. Nothing
# else is removed, roles that match no rule stay, and again changes nothing.
class RelayRoleSharedPlacesTest < ActiveSupport::TestCase
  def fix(name, rw, read, ask) = RelayRoleSharedPlaces.with_shared_places(name, rw.join("\n"), read.join("\n"), ask.join("\n"))
  def lines(t) = t.transform_values { _1.split("\n") }

  MATCH = [ %w[asterism/${node} asterism/${node}/game/** asterism/${node}/*/@pubs], %w[asterism/* asterism/*/game/**],
            %w[asterism/*/@profile] ].freeze
  # docs/rooms.md after the protocol 2 migrations, before the shared places.
  HOST = [ %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile asterism/${node}/*/@profile
              asterism/${node}/*/@status asterism/${node}/*/@pubs asterism/${node}/spectate asterism/${node}/spectate/**],
           %w[asterism/*/game], [] ].freeze
  SPECTATOR = [ [], %w[asterism/*/spectate asterism/*/spectate/** asterism/*/spectate/@profile asterism/*/spectate/@pubs],
                %w[asterism/*/spectate/@profile] ].freeze
  VIEWER = [ %w[asterism/${node}/** asterism/${node}/@profile],
             %w[asterism/** asterism/*/@profile asterism/*/*/@profile asterism/*/*/@status asterism/*/*/@pubs],
             %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@profile] ].freeze
  PLAYERS = [ [], %w[asterism/*/games/**], %w[asterism/*/games/*/call/${node} asterism/*/games/*/meta] ].freeze

  test "the example role reads the network's place, and writes no shared place" do
    t, notes = fix("match", *MATCH)
    assert_equal MATCH[1] + %w[asterism/@shared/**], lines(t)[:read]
    assert_equal [ MATCH[0], MATCH[2] ], lines(t).values_at(:rw, :ask)
    assert_equal [ "read + asterism/@shared/**" ], notes
  end

  test "a viewer (read asterism/**) reads both places" do
    t, = fix("viewer", *VIEWER)
    assert_equal VIEWER[1] + %w[asterism/*/@shared/** asterism/@shared/**], lines(t)[:read]
    assert_equal [ VIEWER[0], VIEWER[2] ], lines(t).values_at(:rw, :ask)
  end

  test "games-host: its node's place and its rooms' applications; its lines stay" do
    t, = fix("games-host", *HOST)
    assert_equal HOST[0] + %w[asterism/${node}/@shared/** asterism/${node}/room$* asterism/${node}/room$*/**], lines(t)[:rw]
    assert_equal HOST[1], lines(t)[:read]
    refute_includes lines(t)[:read], "asterism/@shared/**", "not a member's role: nothing of the network's place"
  end

  test "spectator: the spectate lines replaced by the node places' spectate keys and the senders' declarations" do
    t, notes = fix("spectator", *SPECTATOR)
    assert_equal %w[asterism/*/@shared/spectate/** asterism/*/games/@profile asterism/*/games/@pubs
                    asterism/*/room$*/@profile asterism/*/room$*/@pubs], lines(t)[:read]
    assert_equal %w[asterism/*/games/@profile asterism/*/room$*/@profile], lines(t)[:ask]
    assert_equal [], lines(t)[:rw]
    assert_includes notes, "read - asterism/*/spectate/**"
    assert_includes notes, "ask - asterism/*/spectate/@profile"
    refute lines(t)[:read].any? { _1.include?("asterism/@shared") }, "outward: nothing of the network's place"
  end

  test "a spectator's prefix and its other lines are kept" do
    t, = fix("spectator", [], %w[asterism/games/spectate/** asterism/games/x], %w[asterism/*/x/*/meta])
    assert_equal %w[asterism/games/x asterism/games/@shared/spectate/** asterism/games/games/@profile asterism/games/games/@pubs
                    asterism/games/room$*/@profile asterism/games/room$*/@pubs], lines(t)[:read]
    assert_equal %w[asterism/*/x/*/meta asterism/games/games/@profile asterism/games/room$*/@profile], lines(t)[:ask]
  end

  test "roles that match no rule are left as they are" do
    [ [ "games", *PLAYERS ], [ "custom", %w[asterism/${node}/**], %w[asterism/*/x/**], [] ] ].each do |name, *role|
      t, notes = fix(name, *role)
      assert_empty notes, name
      assert_equal({ rw: role[0], read: role[1], ask: role[2] }, lines(t))
    end
  end

  test "again: nothing changes" do
    [ [ "match", *MATCH ], [ "games-host", *HOST ], [ "spectator", *SPECTATOR ], [ "viewer", *VIEWER ] ].each do |name, *role|
      t, = fix(name, *role)
      again, notes = RelayRoleSharedPlaces.with_shared_places(name, t[:rw], t[:read], t[:ask])
      assert_equal t, again, name
      assert_empty notes, name
    end
  end

  test "on the database, through the router's rules: the host puts, the spectator reads and resolves the types, members read the network's place" do
    RelayRole.delete_all
    roles = { "match" => MATCH, "games-host" => HOST, "spectator" => SPECTATOR, "viewer" => VIEWER, "games" => PLAYERS }
    rows = roles.to_h do |name, (rw, read, ask)|
      [ name, RelayRole.create!(name: name, rw_templates: rw.join("\n"), read_templates: read.join("\n"),
                                ask_templates: ask.join("\n"), watch_templates: "asterism/**") ]
    end
    peers = [ { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
              { "name" => "spectator-a", "kind" => "client", "roles" => %w[spectator], "in_acl" => true },
              { "name" => "admin-viewer", "kind" => "client", "roles" => %w[viewer], "in_acl" => true },
              { "name" => "fmruby-aaaaaa", "kind" => "client", "roles" => %w[match games], "in_acl" => true } ]
    acl = -> { Relay::CloudConfig.new(peers, {}, roles: rows.values.map { _1.reload.to_config }).access_control }
    ok = ->(a, *q) { AclEvaluator.allowed?(a, *q) }
    t1 = "asterism/games/@shared/spectate/mahjong1/state"
    lobby = "asterism/@shared/lobby"
    before = acl.()
    refute_empty GameHostConnections.refused(before)
    refute ok.(before, "spectator-a", "put", "egress", t1)
    refute ok.(before, "fmruby-aaaaaa", "put", "egress", lobby)
    out = StringIO.new
    $stdout = out
    RelayRoleSharedPlaces.new.up
    $stdout = STDOUT
    assert_match(/relay role spectator \(shared places\): read - asterism\/\*\/spectate/, out.string)
    refute_match(/relay role games \(/, out.string)
    rows.each_value { assert _1.reload.valid?, _1.name }
    a = acl.()
    assert_empty GameHostConnections.refused(a), "the host's games and room01 do all they do"
    refute ok.(a, "games", "put", "ingress", "asterism/other/@shared/spectate/x/state"), "its own node's place only"
    refute ok.(a, "games", "put", "ingress", lobby), "not the network's place"
    # The spectator: the values, and the senders' types (type_of: a get of
    # the sender's @profile; topic info: its @pubs).
    %w[declare_subscriber].each { assert ok.(a, "spectator-a", _1, "ingress", "asterism/*/@shared/spectate/**") }
    assert ok.(a, "spectator-a", "put", "egress", t1)
    assert ok.(a, "spectator-a", "put", "egress", "asterism/games/@shared/spectate/room01-mahjong1/state")
    %w[asterism/games/games/@profile asterism/games/room01/@profile].each do |k|
      assert ok.(a, "spectator-a", "query", "ingress", k), k
      assert ok.(a, "spectator-a", "reply", "egress", k), k
    end
    assert ok.(a, "spectator-a", "put", "egress", "asterism/games/room01/@pubs")
    refute ok.(a, "spectator-a", "put", "egress", lobby), "outward: nothing of the network's place"
    refute ok.(a, "spectator-a", "put", "egress", "asterism/games/@shared/other"), "the spectate keys only"
    refute ok.(a, "spectator-a", "put", "egress", "asterism/games/games/mahjong1/state"), "not the players' keys"
    refute ok.(a, "spectator-a", "query", "ingress", "asterism/games/games/mahjong1/call/spectator-a"), "no call"
    refute ok.(a, "spectator-a", "put", "ingress", t1), "writes nothing"
    refute ok.(a, "spectator-a", "put", "egress", "asterism/games/spectate/mahjong1/state"), "the old lines are gone"
    # Members read the network's place, and write no shared place.
    assert ok.(a, "fmruby-aaaaaa", "declare_subscriber", "ingress", "asterism/@shared/**")
    assert ok.(a, "fmruby-aaaaaa", "put", "egress", lobby)
    refute ok.(a, "fmruby-aaaaaa", "put", "ingress", lobby)
    refute ok.(a, "fmruby-aaaaaa", "put", "ingress", "asterism/fmruby-aaaaaa/@shared/x")
    refute ok.(a, "fmruby-aaaaaa", "put", "egress", t1), "a player does not read the spectate keys"
    # The viewer reads both.
    [ t1, lobby ].each { assert ok.(a, "admin-viewer", "put", "egress", _1), _1 }
    out = StringIO.new
    $stdout = out
    RelayRoleSharedPlaces.new.up
    $stdout = STDOUT
    assert_empty out.string, "again: nothing to say"
  ensure
    $stdout = STDOUT
  end
end
