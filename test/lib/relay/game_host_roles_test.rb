require "test_helper"
require_relative "../../test_helpers/acl_evaluator"

# A game host's permanent tables on the registered side (docs/rooms.md, "A
# game host's permanent tables", 0.2.3): the two roles the docs give, asked
# the questions that matter. The host (row "games", role games-host) puts
# its tables' states and answers their calls; the boards (rows with match
# and games) and the browsers see the tables and call them in their own
# names only; nothing else opens, and the rooms stay as they were.
class Relay::GameHostRolesTest < ActiveSupport::TestCase
  # As db/seeds.rb makes it (with the @adv lines).
  MATCH = { "name" => "match", "for_browsers" => true,
            "templates" => { "rw" => %w[asterism/${node} asterism/${node}/game/** asterism/${node}/game/**/@adv/**
                                        asterism/${node}/@profile],
                             "read" => %w[asterism/* asterism/*/game/** asterism/*/game/**/@adv/** asterism/*/@profile],
                             "ask" => %w[asterism/*/@profile asterism/*/game/*/meta asterism/*/game/*/call/${node}
                                         asterism/*/game/**/@adv/**],
                             "watch" => %w[asterism/**] } }.freeze
  # The two roles of docs/rooms.md.
  GAMES_HOST = { "name" => "games-host", "for_browsers" => false,
                 "templates" => { "rw" => %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile],
                                  "watch" => %w[asterism/**] } }.freeze
  GAMES = { "name" => "games", "for_browsers" => true,
            "templates" => { "read" => %w[asterism/*/games/**],
                             "ask" => %w[asterism/*/games/*/call/${node} asterism/*/games/*/meta] } }.freeze

  PEERS = [
    { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "admin_space" => true, "in_acl" => true },
    { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
    { "name" => "fmruby-aaaaaa", "kind" => "client", "roles" => %w[match games], "in_acl" => true },
    { "name" => "fmruby-bbbbbb", "kind" => "client", "roles" => %w[match games], "in_acl" => true },
    { "name" => "fmruby-cccccc", "kind" => "client", "roles" => %w[match], "in_acl" => true }
  ].freeze
  # A seat in each of two room slots (the rooms' store, not the registry).
  SETTINGS = { "browsers" => "ws/[::]:7449", "room_seats" => { "01" => %w[01], "02" => %w[01] } }.freeze

  def acl(peers = PEERS, roles = [ MATCH, GAMES_HOST, GAMES ])
    Relay::CloudConfig.new(peers, SETTINGS, roles: roles).to_h["access_control"]
  end

  def allowed?(subject, message, flow, key, a = acl)
    AclEvaluator.allowed?(a, subject, message, flow, key)
  end

  T = "asterism/games/games/mahjong1".freeze

  test "the host puts its tables' states and answers their calls, under its own name only" do
    %W[asterism/games asterism/games/games #{T}].each { assert allowed?("games", "liveliness_token", "ingress", _1) }
    assert allowed?("games", "declare_queryable", "ingress", "asterism/games/games/**")
    assert allowed?("games", "put", "ingress", "#{T}/state")
    assert allowed?("games", "put", "ingress", "asterism/games/@profile")
    assert allowed?("games", "declare_queryable", "ingress", "asterism/games/@profile")
    assert allowed?("games", "query", "egress", "#{T}/call/fmruby-aaaaaa"), "a board's call reaches it"
    assert allowed?("games", "reply", "ingress", "#{T}/call/fmruby-aaaaaa")
    assert allowed?("games", "declare_liveliness_subscriber", "ingress", "asterism/**")
    refute allowed?("games", "put", "ingress", "asterism/fmruby-aaaaaa/game/x"), "not at a board's place"
    refute allowed?("games", "put", "ingress", "asterism/other/games/mahjong1/state"), "not as another host"
    refute allowed?("games", "query", "ingress", "asterism/fmruby-aaaaaa/game/x/call/games"), "it calls nobody"
    refute allowed?("games", "declare_subscriber", "ingress", "asterism/*/game/**"), "it reads nobody's app"
    refute allowed?("games", "liveliness_token", "egress", "asterism/fmruby-aaaaaa/game"), "it sees nobody (but itself)"
    refute allowed?("games", "put", "ingress", "room/01/asterism/games/games/mahjong1/state")
    refute allowed?("games", "liveliness_query", "ingress", "room/01/**")
  end

  test "a board sees the tables and calls them in its own name; it cannot be a table or another board" do
    a = acl
    assert allowed?("fmruby-aaaaaa", "declare_subscriber", "ingress", "asterism/*/games/*/state", a)
    assert allowed?("fmruby-aaaaaa", "put", "egress", "#{T}/state", a), "the table's state reaches it"
    assert allowed?("fmruby-aaaaaa", "liveliness_query", "ingress", "asterism/*/games/*", a)
    assert allowed?("fmruby-aaaaaa", "liveliness_token", "egress", T, a), "it finds the table"
    assert allowed?("fmruby-aaaaaa", "liveliness_token", "egress", "asterism/games", a)
    assert allowed?("fmruby-aaaaaa", "query", "ingress", "#{T}/call/fmruby-aaaaaa", a)
    assert allowed?("fmruby-aaaaaa", "reply", "egress", "#{T}/call/fmruby-aaaaaa", a), "the answer reaches it"
    assert allowed?("fmruby-aaaaaa", "query", "ingress", "#{T}/meta", a)
    refute allowed?("fmruby-aaaaaa", "query", "ingress", "#{T}/call/fmruby-bbbbbb", a), "not in another board's name"
    refute allowed?("fmruby-aaaaaa", "query", "ingress", "#{T}/call/wasm-alice", a), "nor a browser's"
    refute allowed?("fmruby-aaaaaa", "declare_queryable", "ingress", "asterism/games/games/**", a), "it cannot answer as the table"
    refute allowed?("fmruby-aaaaaa", "declare_queryable", "ingress", "#{T}/call/fmruby-bbbbbb", a), "nor take another board's calls"
    refute allowed?("fmruby-aaaaaa", "put", "ingress", "#{T}/state", a), "it cannot write the table's state"
    refute allowed?("fmruby-aaaaaa", "liveliness_token", "ingress", T, a)
    refute allowed?("fmruby-aaaaaa", "liveliness_token", "ingress", "asterism/fmruby-aaaaaa/games/mahjong9", a),
           "nor make a table of its own"
    refute allowed?("fmruby-aaaaaa", "put", "ingress", "asterism/fmruby-aaaaaa/games/mahjong9/state", a)
    refute allowed?("fmruby-aaaaaa", "declare_subscriber", "ingress", "room/01/**", a), "the rooms stay closed"
    refute allowed?("fmruby-aaaaaa", "query", "ingress", "room/01/asterism/games/games/mahjong1/call/fmruby-aaaaaa", a)
    refute allowed?("fmruby-cccccc", "declare_subscriber", "ingress", "asterism/*/games/*/state", a), "a row without the role"
    refute allowed?("fmruby-cccccc", "query", "ingress", "#{T}/call/fmruby-cccccc", a)
  end

  test "the browsers see the tables and call under the browsers' names, never a board's" do
    a = acl
    assert allowed?(:ws, "declare_subscriber", "ingress", "asterism/*/games/*/state", a)
    assert allowed?(:ws, "query", "ingress", "#{T}/call/wasm-alice", a)
    assert allowed?(:ws, "reply", "egress", "#{T}/call/wasm-alice", a)
    refute allowed?(:ws, "query", "ingress", "#{T}/call/fmruby-aaaaaa", a), "not in a board's name"
    refute allowed?(:ws, "declare_queryable", "ingress", "asterism/games/games/**", a)
    refute allowed?(:ws, "put", "ingress", "#{T}/state", a)
    # Known since G1.5 (docs/g1_5.md, "Browsers"): the router cannot tell
    # one browser from another, so a browser can call under another
    # browser's node ID, and a table gives a node its token back.
    assert allowed?(:ws, "query", "ingress", "#{T}/call/wasm-bob", a)
  end

  test "what the roles add is the tables' keys and nothing else" do
    without = acl(PEERS.reject { _1["name"] == "games" }.map { _1.merge("roles" => Array(_1["roles"]) - %w[games]) }, [ MATCH ])
    with = acl
    rules = ->(a, id) { a["policies"].find { _1["id"] == id }.then { |p| p ? a["rules"].select { |r| p["rules"].include?(r["id"]) } : [] } }
    %w[fmruby_aaaaaa browsers].each do |id|
      added = rules.(with, id) - rules.(without, id)
      keys = added.flat_map { _1["key_exprs"] }.uniq.sort
      assert_equal [ "asterism/*/games/*/call/#{id == 'browsers' ? 'wasm-$*' : 'fmruby-aaaaaa'}", "asterism/*/games/*/meta",
                     "asterism/*/games/**" ].sort, keys, id
    end
    %w[console fmruby_cccccc room_01_s01 room_02_s01].each { assert_equal rules.(without, _1), rules.(with, _1), _1 }
    assert_equal %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile].map { _1.sub("${node}", "games") },
                 rules.(with, "games").flat_map { _1["key_exprs"] } - [ "asterism/**" ]
  end

  test "the rooms stay closed both ways" do
    a = acl
    %w[room-01-s01 room-02-s01].each do |slot|
      n = slot[5, 2]
      ids = a["policies"].select { _1["id"].start_with?(slot.tr("-", "_")) }.flat_map { _1["rules"] }
      assert_operator ids.size, :>, 2
      a["rules"].select { ids.include?(_1["id"]) }.each do |r|
        r["key_exprs"].each { assert _1.start_with?("room/#{n}/"), "#{slot}: #{_1}" }
      end
      refute allowed?(slot, "declare_subscriber", "ingress", "asterism/*/games/*/state", a)
      refute allowed?(slot, "query", "ingress", "#{T}/call/wasm-alice", a)
    end
    %w[games fmruby-aaaaaa].each do |s|
      refute allowed?(s, "put", "egress", "room/01/asterism/games/games/mahjong1/state", a), "#{s} gets nothing of a room"
      refute allowed?(s, "liveliness_token", "egress", "room/01/asterism/games/games/mahjong1", a)
    end
    refute allowed?(:ws, "put", "egress", "room/01/asterism/games/games/mahjong1/state", a)
  end
end
