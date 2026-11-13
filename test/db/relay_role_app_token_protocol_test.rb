require "test_helper"
require_relative "../test_helpers/acl_evaluator"
require Rails.root.join("db/migrate/20261113500000_relay_role_app_token_protocol").to_s

# An application's token says its protocol (asterism/<node>/<app>/protocol/2,
# Asterism wire protocol 2): a role line that names an application's key
# exactly gets the token's line next to it on update, so that it still sees
# the application come and go. Lines with ** are left as they are, nothing
# is removed, and running it again changes nothing.
class RelayRoleAppTokenProtocolTest < ActiveSupport::TestCase
  def fix(rw, read) = RelayRoleAppTokenProtocol.with_token_lines(rw.join("\n"), read.join("\n"))
  def lines(t) = t.transform_values { _1.split("\n") }

  # docs/rooms.md, the game host's role.
  HOST_RW = %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile asterism/${node}/*/@profile
               asterism/${node}/@shared/** asterism/${node}/room$* asterism/${node}/room$*/**].freeze

  test "games-host: its read line of the players' application gets the token's line" do
    t, notes = fix(HOST_RW, %w[asterism/*/game])
    assert_equal %w[asterism/*/game asterism/*/game/protocol/*], lines(t)[:read]
    assert_equal HOST_RW, lines(t)[:rw], "room$* has room$*/** next to it"
    assert_equal [ "read + asterism/*/game/protocol/*" ], notes
  end

  test "an exact application line in read and write, with ${node} and $*" do
    t, = fix(%w[asterism/${node}/demo asterism/${node}/bot$*], %w[asterism/*/*])
    assert_equal %w[asterism/${node}/demo asterism/${node}/demo/protocol/* asterism/${node}/bot$*
                    asterism/${node}/bot$*/protocol/*], lines(t)[:rw]
    assert_equal %w[asterism/*/* asterism/*/*/protocol/*], lines(t)[:read]
  end

  test "lines that are not an application's key are left as they are" do
    role = [ %w[asterism/${node} asterism/${node}/game/** asterism/${node}/@profile asterism/** room/01/asterism/x],
             %w[asterism/* asterism/*/@profile asterism/@shared/lobby asterism/*/game/*/meta asterism/*/@shared/**] ]
    t, notes = fix(*role)
    assert_empty notes
    assert_equal({ rw: role[0], read: role[1] }, lines(t))
  end

  test "again: nothing changes" do
    t, = fix(HOST_RW, %w[asterism/*/game])
    again, notes = RelayRoleAppTokenProtocol.with_token_lines(t[:rw], t[:read])
    assert_equal t, again
    assert_empty notes
  end

  test "on the database: the game host sees a player's application token again" do
    RelayRole.delete_all
    host = RelayRole.create!(name: "games-host", rw_templates: HOST_RW.join("\n"), read_templates: "asterism/*/game",
                             watch_templates: "asterism/**")
    match = RelayRole.create!(name: "match", rw_templates: "asterism/${node}\nasterism/${node}/game/**",
                              read_templates: "asterism/*\nasterism/*/game/**", watch_templates: "asterism/**")
    peers = [ { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
              { "name" => "fmruby-aaaaaa", "kind" => "client", "roles" => %w[match], "in_acl" => true } ]
    acl = -> { Relay::CloudConfig.new(peers, {}, roles: [ host.reload.to_config, match.reload.to_config ]).access_control }
    sees = ->(a, key) { AclEvaluator.allowed?(a, "games", "liveliness_token", "egress", key) }
    declares = ->(a, key) { AclEvaluator.allowed?(a, "fmruby-aaaaaa", "liveliness_token", "ingress", key) }
    a = acl.()
    assert sees.(a, "asterism/fmruby-aaaaaa/game"), "protocol 1's token"
    refute sees.(a, "asterism/fmruby-aaaaaa/game/protocol/2"), "before: not the new token"
    assert declares.(a, "asterism/fmruby-aaaaaa/game/protocol/2"), "the player declares it through game/**"
    out = StringIO.new
    $stdout = out
    RelayRoleAppTokenProtocol.new.up
    $stdout = STDOUT
    assert_match(%r{relay role games-host \(application tokens with the protocol\): read \+ asterism/\*/game/protocol/\*},
                 out.string)
    refute_match(/match/, out.string)
    assert host.reload.valid?
    a = acl.()
    assert sees.(a, "asterism/fmruby-aaaaaa/game/protocol/2")
    refute sees.(a, "asterism/fmruby-aaaaaa/other/protocol/2"), "only the application the line names"
    out = StringIO.new
    $stdout = out
    RelayRoleAppTokenProtocol.new.up
    $stdout = STDOUT
    assert_empty out.string, "again: nothing to say"
  ensure
    $stdout = STDOUT
  end
end
