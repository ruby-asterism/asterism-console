require "test_helper"
require Rails.root.join("db/migrate/20261013100000_relay_roles").to_s

# G1.5: the rows that were "Player" (G0) become rows with the role "match"
# (db/migrate/*_relay_roles.rb). The ACL made from them must mean the same
# as the G0 one, except that calls (queries) are narrowed to the caller's
# own names. Checked by asking both ACLs the same questions (subject,
# message, flow, key) with a small evaluator of zenohd's rules.
class Relay::RoleMigrationTest < ActiveSupport::TestCase
  # The G0 generator's player and browser part, as it was (lib/relay/
  # cloud_config.rb before G1.5), for the app "game".
  module LegacyG0
    ALL = Relay::CloudConfig::ALL
    module_function

    def own_keys(node) = [ "asterism/#{node}", "asterism/#{node}/game/**", "asterism/#{node}/@profile" ]

    def access_control(players, browsers:)
      rules = []
      subjects = []
      policies = []
      players.each do |name, nodes|
        id = Relay::CloudConfig.ident(name)
        nodes = [ name ] if nodes.empty?
        rules << { "id" => "#{id}_own", "messages" => ALL, "flows" => %w[egress ingress], "permission" => "allow",
                   "key_exprs" => nodes.flat_map { own_keys(_1) } }
        subjects << { "id" => id, "cert_common_names" => [ name ] }
        policies << { "id" => id, "rules" => [ "#{id}_own", "game_in", "game_out", "game_watch" ], "subjects" => [ id ] }
      end
      if browsers
        rules << { "id" => "browsers_own", "messages" => ALL, "flows" => %w[egress ingress], "permission" => "allow",
                   "key_exprs" => own_keys("wasm-$*") }
        subjects << { "id" => "browsers", "link_protocols" => [ "ws" ] }
        policies << { "id" => "browsers", "rules" => %w[browsers_own game_in game_out game_watch], "subjects" => [ "browsers" ] }
      end
      game = [ "asterism/*", "asterism/*/game/**", "asterism/*/@profile" ]
      rules.push({ "id" => "game_in", "messages" => %w[declare_subscriber query liveliness_query], "flows" => %w[ingress],
                   "permission" => "allow", "key_exprs" => game },
                 { "id" => "game_out", "messages" => ALL, "flows" => %w[egress], "permission" => "allow", "key_exprs" => game },
                 { "id" => "game_watch", "messages" => %w[declare_liveliness_subscriber], "flows" => %w[ingress],
                   "permission" => "allow", "key_exprs" => [ "asterism/**" ] })
      { "enabled" => true, "default_permission" => "deny", "rules" => rules, "subjects" => subjects, "policies" => policies }
    end
  end

  # zenohd's decision for one message, as far as these ACLs use it: allowed
  # when a rule of the subject's policies lists the message and the flow and
  # one of its key expressions includes the key.
  def self.allowed?(acl, subject, message, flow, key)
    ids = acl["subjects"].select do |s|
      subject == :ws ? s["link_protocols"].to_a.include?("ws") : s["cert_common_names"].to_a.include?(subject)
    end.map { _1["id"] }
    rule_ids = acl["policies"].select { (_1["subjects"] & ids).any? }.flat_map { _1["rules"] }
    acl["rules"].any? do |r|
      rule_ids.include?(r["id"]) && r["messages"].include?(message) && r["flows"].include?(flow) &&
        r["key_exprs"].any? { includes?(_1, key) }
    end
  end

  # Does key expression a include b (every key b matches, a matches)?
  # Chunks: ** (any number), * (one), and $* inside a chunk.
  def self.includes?(a, b)
    chunks_include?(a.split("/"), b.split("/"))
  end

  def self.chunks_include?(a, b)
    return b.empty? if a.empty?
    if a.first == "**"
      return true if chunks_include?(a.drop(1), b)
      return false if b.empty? || b.first.start_with?("@")
      return chunks_include?(a, b.drop(1))
    end
    return false if b.empty? || b.first == "**"
    chunk_include?(a.first, b.first) && chunks_include?(a.drop(1), b.drop(1))
  end

  def self.chunk_include?(a, b)
    return !b.start_with?("@") if a == "*"
    return false if b == "*"
    return a == b unless a.include?("$*")
    Regexp.new("\\A" + a.split("$*", -1).map { Regexp.escape(_1) }.join("[^/]*") + "\\z").match?(b)
  end

  NODES = %w[alice fmruby-aaaaaa fmruby-bbbbbb wasm-abc123 carol].freeze
  KEYS = (NODES.flat_map do |n|
    [ "asterism/#{n}", "asterism/#{n}/game", "asterism/#{n}/game/othello", "asterism/#{n}/game/othello/state",
      "asterism/#{n}/game/othello/meta", "asterism/#{n}/@profile", "asterism/#{n}/demo/x",
      *NODES.map { |c| "asterism/#{n}/game/othello/call/#{c}" } ]
  end + %w[asterism/** asterism/*/game/** asterism/*/game/*/meta asterism/*/@profile demo/x fmrb/x @/x/router]).freeze

  # The node a call key names as its caller, or nil.
  def caller_of(key) = key[%r{/call/([^/]+)\z}, 1]

  test "the evaluator reads key expressions like zenohd" do
    k = self.class
    assert k.includes?("asterism/**", "asterism/a/game/x")
    assert k.includes?("asterism/**", "asterism")
    refute k.includes?("asterism/**", "asterism/a/@profile"), "@ chunks are not in **"
    assert k.includes?("asterism/*/@profile", "asterism/a/@profile")
    assert k.includes?("asterism/wasm-$*/game/**", "asterism/wasm-abc/game/o")
    refute k.includes?("asterism/wasm-$*/game/**", "asterism/alice/game/o")
    assert k.includes?("asterism/**", "asterism/*/game/**")
    refute k.includes?("asterism/*/game/**", "asterism/**")
  end

  test "after the migration a player's ACL means the same, calls narrowed to its own names" do
    players = { "alice" => [], "home-bob" => %w[fmruby-aaaaaa fmruby-bbbbbb] }
    old = LegacyG0.access_control(players, browsers: true)
    role = RelayRole.new(RelayRoles.match_role("game"))
    peers = players.map { |name, nodes| { "name" => name, "roles" => %w[match], "nodes" => nodes, "in_acl" => true } }
    new = Relay::CloudConfig.new(peers, { "browsers" => "ws/[::]:7449" }, roles: [ role.to_config ]).access_control
    own = { "alice" => %w[alice], "home-bob" => %w[fmruby-aaaaaa fmruby-bbbbbb], ws: %w[wasm-abc123] }
    narrowed = []
    [ "alice", "home-bob", :ws, "carol" ].each do |subject|
      Relay::CloudConfig::ALL.each do |message|
        %w[ingress egress].each do |flow|
          KEYS.each do |key|
            was = self.class.allowed?(old, subject, message, flow, key)
            now = self.class.allowed?(new, subject, message, flow, key)
            next if was == now
            where = "#{subject} #{message} #{flow} #{key}"
            refute now, "allowed only after the migration: #{where}"
            assert_equal [ "query", "ingress" ], [ message, flow ], "only queries from it may change: #{where}"
            refute own[subject].to_a.include?(caller_of(key)), "a call under its own name stays: #{where}"
            refute key.end_with?("/meta", "/@profile"), "meta and profiles stay: #{where}"
            narrowed << where
          end
        end
      end
    end
    assert_includes narrowed, "alice query ingress asterism/fmruby-aaaaaa/game/othello/call/carol"
    assert_includes narrowed, "home-bob query ingress asterism/alice/game/othello/call/alice"
    assert_includes narrowed, "#{:ws} query ingress asterism/alice/game/othello/call/fmruby-aaaaaa"
    assert self.class.allowed?(new, "alice", "query", "ingress", "asterism/fmruby-aaaaaa/game/othello/call/alice")
    assert self.class.allowed?(new, "home-bob", "query", "ingress", "asterism/alice/game/othello/call/fmruby-bbbbbb")
    assert self.class.allowed?(new, :ws, "query", "ingress", "asterism/alice/game/othello/call/wasm-abc123")
  end
end
