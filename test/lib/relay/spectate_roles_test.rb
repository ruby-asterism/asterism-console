require "test_helper"
require_relative "../../test_helpers/acl_evaluator"
require_relative "../../test_helpers/game_host_connections"

# The game host's spectate keys (docs/rooms.md, "Watching the tables from
# outside"): on its node's shared place (protocol 2),
# asterism/<host>/@shared/spectate/<table>/state, a room's table as
# room<slot>-<table>, put on the registered side by the host's application
# games and by a room's application room<slot>. The host (games-host with
# its node's place and the rooms' applications) writes them; a spectator's
# row and a viewer read them, the spectator with the senders' declarations
# for the types; the players' rows, the browsers and the rooms' seats
# neither receive nor subscribe to them, and the rules the console makes
# for the rooms do not reach them.
class Relay::SpectateRolesTest < ActiveSupport::TestCase
  GAMES_HOST = { "name" => "games-host", "for_browsers" => false,
                 "templates" => { "rw" => %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile
                                             asterism/${node}/*/@profile asterism/${node}/*/@status
                                             asterism/${node}/*/@pubs asterism/${node}/@shared/**
                                             asterism/${node}/room$* asterism/${node}/room$*/**],
                                  "read" => %w[asterism/*/game], "watch" => %w[asterism/**] } }.freeze
  GAMES = { "name" => "games", "for_browsers" => true,
            "templates" => { "read" => %w[asterism/*/games/**],
                             "ask" => %w[asterism/*/games/*/call/${node} asterism/*/games/*/meta] } }.freeze
  MATCH = { "name" => "match", "for_browsers" => true,
            "templates" => { "rw" => %w[asterism/${node} asterism/${node}/game/** asterism/${node}/game/**/@adv/**
                                        asterism/${node}/@profile],
                             "read" => %w[asterism/* asterism/*/game/** asterism/*/game/**/@adv/** asterism/*/@profile
                                         asterism/@shared/**],
                             "ask" => %w[asterism/*/@profile asterism/*/game/*/meta asterism/*/game/*/call/${node}
                                         asterism/*/game/**/@adv/**],
                             "watch" => %w[asterism/**] } }.freeze
  SPECTATOR = { "name" => "spectator", "for_browsers" => false,
                "templates" => { "read" => %w[asterism/*/@shared/spectate/** asterism/*/games/@profile
                                              asterism/*/games/@pubs asterism/*/room$*/@profile asterism/*/room$*/@pubs],
                                 "ask" => %w[asterism/*/games/@profile asterism/*/room$*/@profile],
                                 "watch" => %w[asterism/**] } }.freeze
  # docs/g1_5.md, "Looking only".
  VIEWER = { "name" => "viewer", "for_browsers" => false,
             "templates" => { "rw" => %w[asterism/${node}/** asterism/${node}/@profile],
                              "read" => %w[asterism/** asterism/*/@profile asterism/*/*/@profile asterism/*/*/@status
                                          asterism/*/*/@pubs asterism/*/@shared/** asterism/@shared/**],
                              "ask" => %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@profile],
                              "watch" => %w[asterism/**] } }.freeze

  PEERS = [
    { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "admin_space" => true, "in_acl" => true },
    { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
    { "name" => "fmruby-aaaaaa", "kind" => "client", "roles" => %w[match games], "in_acl" => true },
    { "name" => "player-a", "kind" => "client", "roles" => %w[games], "in_acl" => true },
    { "name" => "spectator-a", "kind" => "client", "roles" => %w[spectator], "in_acl" => true },
    { "name" => "admin-viewer", "kind" => "client", "roles" => %w[viewer], "in_acl" => true }
  ].freeze
  SETTINGS = { "browsers" => "ws/[::]:7449", "room_seats" => { "01" => %w[01 02], "02" => %w[01] },
               "room_hosts" => %w[games] }.freeze

  KEYS = %w[asterism/games/@shared/spectate/mahjong1/state asterism/games/@shared/spectate/room01-mahjong1/state].freeze
  SEATS = %w[room-01-s01 room-01-s02 room-02-s01].freeze

  def acl
    @acl ||= Relay::CloudConfig.new(PEERS, SETTINGS, roles: [ GAMES_HOST, GAMES, MATCH, SPECTATOR, VIEWER ])
                               .to_h["access_control"]
  end

  def allowed?(subject, message, flow, key, link: subject == :ws ? "ws" : "tls")
    AclEvaluator.allowed?(acl, subject, message, flow, key, link: link)
  end

  # Receives the puts, may subscribe.
  def reads?(subject, key)
    allowed?(subject, "put", "egress", key) || allowed?(subject, "declare_subscriber", "ingress", key)
  end

  test "the host puts the spectate keys, and nobody else writes them" do
    KEYS.each do |k|
      assert allowed?("games", "put", "ingress", k), k
      (%w[fmruby-aaaaaa player-a spectator-a admin-viewer] + SEATS + [ :ws ]).each do |s|
        refute allowed?(s, "put", "ingress", k), "#{s} writes #{k}"
      end
    end
    refute allowed?("games", "put", "ingress", "asterism/other-host/@shared/spectate/mahjong1/state"), "its own node only"
    refute allowed?("games", "put", "ingress", "asterism/@shared/spectate/mahjong1/state"), "not the network's place"
  end

  test "the host's applications answer their own profiles and put their status and topics (protocol 2)" do
    %w[games room01].each do |app|
      assert allowed?("games", "declare_queryable", "ingress", "asterism/games/#{app}/@profile"), app
      assert allowed?("games", "reply", "ingress", "asterism/games/#{app}/@profile"), app
      assert allowed?("games", "put", "ingress", "asterism/games/#{app}/@status"), app
      assert allowed?("games", "put", "ingress", "asterism/games/#{app}/@pubs"), app
      %w[console admin-viewer].each do |s|
        assert allowed?(s, "query", "ingress", "asterism/games/#{app}/@profile"), s
        assert allowed?(s, "reply", "egress", "asterism/games/#{app}/@profile"), s
        assert reads?(s, "asterism/games/#{app}/@pubs"), s
      end
    end
    refute allowed?("games", "put", "ingress", "asterism/other-host/games/@pubs"), "its own node only"
    refute allowed?("player-a", "query", "ingress", "asterism/games/games/@profile")
  end

  test "the host's connections, games and a room's room01, do all they do" do
    assert_empty GameHostConnections.refused(acl)
    refute allowed?("games", "liveliness_token", "ingress", "asterism/other-host/room01"), "its own node only"
  end

  test "a spectator reads the senders' declarations and types (topic info, type_of), and no other application's" do
    %w[games room01].each do |app|
      assert allowed?("spectator-a", "query", "ingress", "asterism/games/#{app}/@profile"), app
      assert allowed?("spectator-a", "reply", "egress", "asterism/games/#{app}/@profile"), app
      assert reads?("spectator-a", "asterism/games/#{app}/@pubs"), app
      refute allowed?("spectator-a", "put", "ingress", "asterism/games/#{app}/@pubs"), "writes nothing"
      refute allowed?("spectator-a", "declare_queryable", "ingress", "asterism/games/#{app}/@profile")
    end
    refute allowed?("spectator-a", "query", "ingress", "asterism/linux/demo/@profile"), "not every application"
    refute reads?("spectator-a", "asterism/games/games/@status")
  end

  test "a spectator and a viewer read them" do
    KEYS.each do |k|
      %w[spectator-a admin-viewer console].each do |s|
        assert allowed?(s, "declare_subscriber", "ingress", k), "#{s} subscribes to #{k}"
        assert allowed?(s, "put", "egress", k), "#{s} receives #{k}"
      end
    end
    assert allowed?("spectator-a", "declare_subscriber", "ingress", "asterism/*/@shared/spectate/**"),
           "the subscription of the commentary and the browser build"
  end

  test "the network's place: members and the viewer read it, the spectator does not, nobody of these writes it" do
    key = "asterism/@shared/lobby"
    %w[fmruby-aaaaaa admin-viewer].each { assert reads?(_1, key), _1 }
    assert reads?(:ws, key), "the browsers have match"
    %w[spectator-a player-a].each { refute reads?(_1, key), _1 }
    (%w[games fmruby-aaaaaa player-a spectator-a admin-viewer] + [ :ws ]).each do |s|
      refute allowed?(s, "put", "ingress", key), "#{s} writes the network's place"
    end
  end

  test "the players, the browsers and the rooms' seats do not" do
    KEYS.each do |k|
      (%w[fmruby-aaaaaa player-a] + SEATS).each { |s| refute reads?(s, k), "#{s} reads #{k}" }
      refute reads?(:ws, k), "the browsers read #{k}"
      # A seat's certificate with its calls subject (tls) as well.
      SEATS.each { |s| refute allowed?(s, "put", "egress", k, link: "tls"), s }
    end
    assert reads?("player-a", "asterism/games/games/mahjong1/state"), "the players' state as before"
    assert reads?("room-01-s01", "room/01/asterism/games/games/mahjong1/state"), "a room's state as before"
  end

  test "no rule the console makes for the rooms reaches them" do
    room = acl["rules"].select { |r| r["id"].start_with?("room_") || r["id"].include?("__room_host_") }
    refute_empty room
    room.each do |r|
      r["key_exprs"].each do |e|
        KEYS.each { |k| refute AclEvaluator.includes?(e, k), "#{r['id']}: #{e} reaches #{k}" }
        assert e.start_with?("room/"), "#{r['id']}: #{e} is a room's"
      end
    end
  end

  test "a spectator reads nothing else" do
    refute reads?("spectator-a", "asterism/games/@shared/other/x"), "the spectate keys only"
    refute reads?("spectator-a", "asterism/games/games/mahjong1/state"), "not the players' keys"
    refute allowed?("spectator-a", "query", "ingress", "asterism/games/games/mahjong1/call/spectator-a"), "no call"
    refute allowed?("spectator-a", "query", "ingress", "asterism/games/games/mahjong1/meta")
    refute reads?("spectator-a", "room/01/asterism/games/games/mahjong1/state"), "not a room"
    refute allowed?("spectator-a", "declare_subscriber", "ingress", "asterism/**"), "not everything (the MCP bridge)"
    refute allowed?("spectator-a", "liveliness_token", "ingress", "asterism/spectator-a/cli-0a1b"), "unseen"
    refute reads?("spectator-a", "asterism/games/spectate/mahjong1/state"), "the old spectate keys: nothing there"
  end
end
