require "test_helper"
require_relative "../../test_helpers/acl_evaluator"

# The rooms' seats and game hosts (0.3.0, docs/rooms.md "Seats"): the ACL
# Relay::CloudConfig makes for them, asked the questions of the study's
# acceptance list with zenohd's own way of deciding (deny wins inside a
# subject, any subject's allow wins; test_helpers/acl_evaluator.rb).
class Relay::RoomSeatsAclTest < ActiveSupport::TestCase
  SETTINGS = { "room_seats" => 3, "room_hosts" => [ "games" ], "seat_node_prefix" => "wasm-" }.freeze

  def peers(seats: 3)
    list = [
      { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "admin_space" => true, "in_acl" => true },
      { "name" => "games", "kind" => "client", "roles" => [], "rw" => %w[asterism/games/**], "in_acl" => true },
      { "name" => "room-01", "kind" => "client", "in_acl" => true, "room_slot" => "01" },
      { "name" => "room-02", "kind" => "client", "in_acl" => true, "room_slot" => "02" }
    ]
    %w[01 02].each do |slot|
      (1..seats).each do |i|
        list << { "name" => format("room-%s-s%02d", slot, i), "kind" => "client", "in_acl" => true,
                  "room_slot" => slot, "room_seat" => format("%02d", i) }
      end
    end
    list
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

  test "the slot's certificate keeps its room but not the seats' or the host's names" do
    assert ok?("room-01", "put", "room/01/asterism/wasm-abc123/game/x"), "an old page's own keys"
    assert ok?("room-01", "query", "#{TABLE}/call/wasm-abc123")
    refute ok?("room-01", "put", "#{OWN}/game/x"), "a seat's keys"
    refute ok?("room-01", "liveliness_token", "#{OWN}/game")
    refute ok?("room-01", "query", "#{TABLE}/call/wasm-0101"), "a seat's name"
    %w[put delete declare_queryable liveliness_token reply].each do |m|
      refute ok?("room-01", m, "#{TABLE}/state"), "#{m} at the table"
      refute ok?("room-01", m, "room/01/asterism/games-bot-1/game"), "#{m} at a host's bot"
    end
    refute ok?("room-01", "declare_queryable", "room/01/asterism/games/games/**")
    refute ok?("room-01", "query", "#{TABLE}/call/games")
    refute ok?("room-01", "query", "#{TABLE}/call/games-bot-1"), "as the host's bot"
    refute ok?("room-01", "put", "room/02/x")
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

  test "without seats or hosts the slot's rules are as before 0.3.0" do
    plain = acl({}, peers(seats: 0))
    pol = plain["policies"].to_h { [ _1["id"], _1["rules"] ] }
    assert_equal [ "room_01_room" ], pol["room_01"]
    refute plain["rules"].any? { _1["permission"] == "deny" }
    refute pol["games"].any? { _1.include?("room_host") }
  end

  test "a seat's two subjects, one certificate; the names read back once" do
    subs = @acl["subjects"].select { _1["cert_common_names"] == [ S1 ] }
    assert_equal [ nil, [ "tls" ] ], subs.map { _1["link_protocols"] }
    names = Relay::CloudConfig.new(peers, SETTINGS).subject_names
    assert_equal names.uniq, names
    assert_includes names, S1
  end

  test "8 slots of 16 seats: the size zenohd reads" do
    list = (1..8).flat_map do |n|
      slot = format("%02d", n)
      [ { "name" => "room-#{slot}", "kind" => "client", "in_acl" => true, "room_slot" => slot } ] +
        (1..16).map { |i| { "name" => format("room-%s-s%02d", slot, i), "kind" => "client", "in_acl" => true,
                            "room_slot" => slot, "room_seat" => format("%02d", i) } }
    end
    c = Relay::CloudConfig.new(list + peers(seats: 0).first(2), SETTINGS.merge("room_seats" => 16))
    a = c.access_control
    assert_equal 8 * 16 * 2 + 8 + 2, a["subjects"].size
    assert_operator c.body.bytesize, :<, 400_000
    assert AclEvaluator.allowed?(a, "room-08-s16", "put", "ingress", "room/08/asterism/wasm-0816/game/x")
    refute AclEvaluator.allowed?(a, "room-08-s16", "put", "ingress", "room/08/asterism/wasm-0815/game/x")
  end
end
