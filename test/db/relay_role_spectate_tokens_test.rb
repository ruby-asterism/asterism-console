require "test_helper"
require_relative "../test_helpers/acl_evaluator"
require Rails.root.join("db/migrate/20261113600000_relay_role_spectate_tokens").to_s

# The spectator's view of the senders on update: a role that reads the
# node places' spectate keys (<prefix>/@shared/spectate/**) reads the
# liveliness tokens of the applications that put them (games and
# room<slot>), so the command line finds them and asks their profiles by
# name (`asterism topic list` shows the spectate keys). No other
# application's token. Lines are added only, roles without such a line
# stay, and again changes nothing.
class RelayRoleSpectateTokensTest < ActiveSupport::TestCase
  def fix(read) = RelayRoleSpectateTokens.with_spectate_tokens(read.join("\n"))

  TOKENS = %w[asterism/*/games/protocol/* asterism/*/room$*/protocol/*].freeze
  CALLS = %w[asterism/*/games/spectate/call/${node} asterism/*/room$*/spectate/call/${node}].freeze
  # docs/rooms.md after the spectate calls' migration.
  SPECTATOR = [ [], %w[asterism/*/@shared/spectate/** asterism/*/games/@profile asterism/*/games/@pubs
                       asterism/*/room$*/@profile asterism/*/room$*/@pubs] + CALLS,
                %w[asterism/*/games/@profile asterism/*/room$*/@profile] + CALLS ].freeze
  HOST = [ %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile asterism/${node}/*/@profile
              asterism/${node}/*/@status asterism/${node}/*/@pubs asterism/${node}/@shared/**
              asterism/${node}/room$* asterism/${node}/room$*/**],
           %w[asterism/*/game asterism/*/game/protocol/*], [] ].freeze
  VIEWER = [ %w[asterism/${node}/** asterism/${node}/@profile],
             %w[asterism/** asterism/*/@profile asterism/*/*/@profile asterism/*/*/@status asterism/*/*/@pubs
                asterism/*/@shared/** asterism/@shared/**],
             %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@profile] ].freeze
  PLAYERS = [ [], %w[asterism/*/games/**], %w[asterism/*/games/*/call/${node} asterism/*/games/*/meta] ].freeze

  test "a spectator reads the senders' tokens" do
    t, notes = fix(SPECTATOR[1])
    assert_equal SPECTATOR[1] + TOKENS, t[:read].split("\n")
    assert_equal TOKENS.map { "read + #{_1}" }, notes
  end

  test "a spectator's prefix is kept" do
    t, = fix(%w[asterism/games/@shared/spectate/**])
    assert_equal %w[asterism/games/@shared/spectate/** asterism/games/games/protocol/* asterism/games/room$*/protocol/*],
                 t[:read].split("\n")
  end

  test "roles without the spectate keys' read line are left as they are" do
    [ HOST, VIEWER, PLAYERS, [ [], %w[asterism/${node}/@shared/spectate/x], [] ] ].each do |role|
      t, notes = fix(role[1])
      assert_empty notes
      assert_equal role[1], t[:read].split("\n")
    end
  end

  test "again: nothing changes" do
    t, = fix(SPECTATOR[1])
    again, notes = RelayRoleSpectateTokens.with_spectate_tokens(t[:read])
    assert_equal t, again
    assert_empty notes
  end

  test "on the database, through the router's rules: the senders' tokens reach a spectator, no other token" do
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
    tokens = %w[asterism/games/games/protocol/2 asterism/games/room01/protocol/2]
    before = acl.()
    tokens.each { refute ok.(before, "spectator-a", "liveliness_token", "egress", _1), _1 }
    out = StringIO.new
    $stdout = out
    RelayRoleSpectateTokens.new.up
    $stdout = STDOUT
    assert_match(%r{relay role spectator \(spectate tokens\): read \+ asterism/\*/games/protocol/\*}, out.string)
    refute_match(/relay role (games|games-host|viewer) \(/, out.string)
    rows.each_value { assert _1.reload.valid?, _1.name }
    a = acl.()
    assert ok.(a, "spectator-a", "declare_liveliness_subscriber", "ingress", "asterism/**"), "its watch"
    tokens.each { assert ok.(a, "spectator-a", "liveliness_token", "egress", _1), _1 }
    # what topic list asks next: each sender's profile by name, its answer
    %w[asterism/games/games/@profile asterism/games/room01/@profile].each do |k|
      assert ok.(a, "spectator-a", "query", "ingress", k), k
      assert ok.(a, "spectator-a", "reply", "egress", k), k
    end
    refute ok.(a, "spectator-a", "liveliness_token", "egress", "asterism/fmruby-aaaaaa/game/protocol/2"), "a player's app"
    refute ok.(a, "spectator-a", "liveliness_token", "egress", "asterism/games/games/mahjong1"), "a table object"
    refute ok.(a, "spectator-a", "liveliness_token", "ingress", "asterism/spectator-a/games/protocol/2"), "it puts no token"
    refute ok.(a, "spectator-a", "put", "egress", "asterism/games/games/mahjong1/state"), "still not the players' keys"
    refute ok.(a, "spectator-a", "query", "ingress", "asterism/games/games/mahjong1/call/spectator-a"), "nor their calls"
    out = StringIO.new
    $stdout = out
    RelayRoleSpectateTokens.new.up
    $stdout = STDOUT
    assert_empty out.string, "again: nothing to say"
  ensure
    $stdout = STDOUT
  end
end
