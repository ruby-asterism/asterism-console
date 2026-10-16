require "test_helper"
require_relative "../../test_helpers/acl_evaluator"

# The rooms' seats and game hosts (0.3.0, docs/rooms.md "Seats"): the ACL
# Relay::CloudConfig makes for them, asked the questions of the study's
# acceptance list with zenohd's own way of deciding (deny wins inside a
# subject, any subject's allow wins; test_helpers/acl_evaluator.rb).
class Relay::RoomSeatsAclTest < ActiveSupport::TestCase
  # The seats come from the settings and the rooms' store (0.3.1:
  # Relay::RoomCerts.seats, through Relay::Applier), not from registry rows.
  def self.seats(slots, n) = slots.to_h { [ _1, (1..n).map { |i| format("%02d", i) } ] }

  SETTINGS = { "room_seats" => seats(%w[01 02], 3), "room_hosts" => [ "games" ], "seat_node_prefix" => "wasm-" }.freeze

  def peers
    [ { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "admin_space" => true, "in_acl" => true },
      { "name" => "games", "kind" => "client", "roles" => [], "rw" => %w[asterism/games/**], "in_acl" => true } ]
  end

  def acl(settings = SETTINGS, list = peers)
    Relay::CloudConfig.new(list, settings).access_control
  end

  def ok?(subject, message, key, flow: "ingress", a: @acl)
    AclEvaluator.allowed?(a, subject, message, flow, key)
  end

  setup { @acl = acl }

  S1 = "room-01-s01".freeze
  OWN = "room/01/asterism/wasm-0101".freeze
  OTHER = "room/01/asterism/wasm-0102".freeze
  TABLE = "room/01/asterism/games/games/mahjong1".freeze

  test "a seat writes only under its own node ID" do
    %w[put delete].each do |m|
      assert ok?(S1, m, "#{OWN}/game/othello/state"), m
      refute ok?(S1, m, "#{OTHER}/game/othello/state"), "#{m} at another seat"
      refute ok?(S1, m, "#{TABLE}/state"), "#{m} at the table"
      refute ok?(S1, m, "room/01/chat/x"), "#{m} outside asterism/<own>"
      refute ok?(S1, m, "room/02/asterism/wasm-0101/game/x"), "#{m} in another room"
      refute ok?(S1, m, "asterism/wasm-0101/game/x"), "#{m} on the registered side"
    end
    assert ok?(S1, "liveliness_token", "#{OWN}/game")
    assert ok?(S1, "liveliness_token", "#{OWN}/game/othello")
    refute ok?(S1, "liveliness_token", "#{OTHER}/game")
    refute ok?(S1, "liveliness_token", "#{TABLE}")
    assert ok?(S1, "declare_queryable", "#{OWN}/game/**")
    refute ok?(S1, "declare_queryable", "#{OTHER}/game/**"), "a queryable at another seat"
    refute ok?(S1, "declare_queryable", "room/01/asterism/games/games/**"), "a fake table"
    assert ok?(S1, "reply", "#{OWN}/game/othello/call/wasm-0102")
    refute ok?(S1, "reply", "#{OTHER}/game/othello/call/wasm-0101"), "a reply in another's name"
    assert ok?(S1, "put", "#{OWN}/@profile"), "its own profile (0.3.0)"
    refute ok?(S1, "put", "#{OTHER}/@profile")
    assert ok?(S1, "declare_queryable", "#{OWN}/@profile")
    assert ok?(S1, "put", "#{OWN}/game/othello/state/@adv/pub/x/y")
  end

  test "a seat calls under its own node ID only" do
    assert ok?(S1, "query", "#{OTHER}/game/othello/call/wasm-0101"), "its own name"
    assert ok?(S1, "query", "#{TABLE}/call/wasm-0101")
    refute ok?(S1, "query", "#{OTHER}/game/othello/call/wasm-0103"), "another seat's name"
    refute ok?(S1, "query", "#{TABLE}/call/wasm-0102")
    refute ok?(S1, "query", "#{TABLE}/call/games"), "the host's name"
    refute ok?(S1, "query", "#{TABLE}/call/wasm-abc123"), "an old browser's name"
    refute ok?(S1, "query", "#{TABLE}/call/**"), "a wildcard call"
    refute ok?(S1, "query", "#{TABLE}/call/wasm-0101/x")
    refute ok?(S1, "query", "room/02/asterism/games/games/mahjong1/call/wasm-0101"), "another room"
    assert ok?(S1, "query", "#{TABLE}/meta"), "meta needs no caller"
    assert ok?(S1, "query", "room/01/asterism/wasm-0102/@profile"), "nor a profile"
    assert ok?(S1, "liveliness_query", "room/01/asterism/wasm-0101/game/**"), "the duplicate check"
    # Only through the second subject (the tls one): a seat that came some
    # other way (none does) could not call even as itself.
    refute AclEvaluator.allowed?(@acl, S1, "query", "ingress", "#{TABLE}/call/wasm-0101", link: "quic")
  end

  test "a seat reads and receives the whole room, and nothing else" do
    assert ok?(S1, "declare_subscriber", "room/01/asterism/*/game/othello/state")
    assert ok?(S1, "declare_subscriber", "room/01/asterism/*/games/*/state")
    assert ok?(S1, "declare_liveliness_subscriber", "room/01/asterism/**")
    assert ok?(S1, "put", "#{TABLE}/state", flow: "egress"), "the table's state reaches it"
    assert ok?(S1, "query", "#{OWN}/game/othello/call/wasm-0102", flow: "egress"), "a call reaches it"
    assert ok?(S1, "reply", "#{OTHER}/game/othello/call/wasm-0101", flow: "egress")
    refute ok?(S1, "declare_subscriber", "room/02/**")
    refute ok?(S1, "declare_subscriber", "asterism/**")
    refute ok?(S1, "put", "room/02/asterism/x/y", flow: "egress")
  end

  test "no certificate of a slot's own (0.3.1): only the seats are in a room" do
    names = Relay::CloudConfig.new(peers, SETTINGS).subject_names
    assert_equal %w[console games room-01-s01 room-01-s02 room-01-s03 room-02-s01 room-02-s02 room-02-s03], names
    Relay::CloudConfig::ALL.each do |m|
      refute ok?("room-01", m, "room/01/asterism/wasm-abc123/game/x"), "room-01 #{m}"
    end
  end

  test "a registry row with a seat's name is left out: the name is the seat's" do
    list = peers + [ { "name" => "room-01-s01", "kind" => "client", "rw" => %w[asterism/**], "in_acl" => true } ]
    a = acl(SETTINGS, list)
    refute ok?(S1, "put", "asterism/x/y", a: a)
    assert ok?(S1, "put", "#{OWN}/game/x", a: a)
    assert_equal 2, a["subjects"].count { _1["cert_common_names"] == [ S1 ] }
  end

  test "a seat whose certificate is not in the store is not in the ACL" do
    a = acl(SETTINGS.merge("room_seats" => { "01" => %w[01 03] }))
    assert ok?("room-01-s03", "put", "room/01/asterism/wasm-0103/game/x", a: a)
    refute ok?("room-01-s02", "put", "room/01/asterism/wasm-0102/game/x", a: a)
    refute ok?("room-02-s01", "put", "room/02/asterism/wasm-0201/game/x", a: a)
  end

  test "the host serves the tables in every room, as itself and its bots only" do
    %w[01 02].each do |slot|
      t = "room/#{slot}/asterism/games/games/mahjong1"
      assert ok?("games", "put", "#{t}/state")
      assert ok?("games", "liveliness_token", "room/#{slot}/asterism/games/games")
      assert ok?("games", "liveliness_token", t)
      assert ok?("games", "declare_queryable", "room/#{slot}/asterism/games/games/**")
      assert ok?("games", "reply", "#{t}/call/wasm-#{slot}01")
      assert ok?("games", "query", "#{t}/call/wasm-#{slot}01", flow: "egress"), "a seat's call reaches it"
      assert ok?("games", "declare_liveliness_subscriber", "room/#{slot}/asterism/**")
    end
    assert ok?("games", "liveliness_token", "room/01/asterism/games-bot-1/game"), "a bot of the host"
    assert ok?("games", "query", "#{TABLE}/call/games-bot-1"), "a bot calls the table"
    assert ok?("games", "query", "#{TABLE}/meta")
    refute ok?("games", "query", "#{TABLE}/call/wasm-0101"), "not in a seat's name"
    refute ok?("games", "put", "#{OWN}/game/x"), "not at a seat"
    refute ok?("games", "put", "room/01/chat"), "not elsewhere in the room"
    assert ok?("games", "put", "asterism/games/games/mahjong1/state"), "its registered side as before"
  end

  test "without seats there are no rooms: no host's or console's rules for them" do
    plain = acl({ "room_hosts" => [ "games" ] })
    pol = plain["policies"].to_h { [ _1["id"], _1["rules"] ] }
    refute pol["games"].any? { _1.include?("room_host") }
    refute pol["console"].any? { _1.include?("rooms") }
    refute plain["rules"].any? { _1["permission"] == "deny" }
  end

  test "a seat's two subjects, one certificate; the names read back once" do
    subs = @acl["subjects"].select { _1["cert_common_names"] == [ S1 ] }
    assert_equal [ nil, [ "tls" ] ], subs.map { _1["link_protocols"] }
    names = Relay::CloudConfig.new(peers, SETTINGS).subject_names
    assert_equal names.uniq, names
    assert_includes names, S1
  end

  test "8 slots of 16 seats: the size zenohd reads" do
    c = Relay::CloudConfig.new(peers, SETTINGS.merge("room_seats" => self.class.seats((1..8).map { format("%02d", _1) }, 16)))
    a = c.access_control
    assert_equal 8 * 16 * 2 + 2, a["subjects"].size
    assert_operator c.body.bytesize, :<, 400_000
    assert AclEvaluator.allowed?(a, "room-08-s16", "put", "ingress", "room/08/asterism/wasm-0816/game/x")
    refute AclEvaluator.allowed?(a, "room-08-s16", "put", "ingress", "room/08/asterism/wasm-0815/game/x")
  end
end
