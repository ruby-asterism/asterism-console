require "test_helper"
require_relative "../../test_helpers/acl_evaluator"

# The viewer role of docs/g1_5.md ("Looking only", 0.3.4): an admin's row
# for the asterism gem's command line and MCP bridge. It sees every node,
# object, profile and status outside the rooms, and calls nothing.
class Relay::ViewerRoleTest < ActiveSupport::TestCase
  VIEWER = { "name" => "viewer", "for_browsers" => false,
             "templates" => { "rw" => %w[asterism/${node}/** asterism/${node}/@profile],
                              "read" => %w[asterism/** asterism/*/@profile asterism/*/*/@status],
                              "ask" => %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@status],
                              "watch" => %w[asterism/**] } }.freeze
  PEERS = [
    { "name" => "admin-viewer", "kind" => "client", "roles" => %w[viewer], "in_acl" => true },
    { "name" => "games", "kind" => "client", "rw" => %w[asterism/games/**], "in_acl" => true }
  ].freeze

  def allowed?(message, flow, key)
    @acl ||= Relay::CloudConfig.new(PEERS, { "room_seats" => { "01" => %w[01] } }, roles: [ VIEWER ]).access_control
    AclEvaluator.allowed?(@acl, "admin-viewer", message, flow, key)
  end

  test "it sees every node, object, profile and status" do
    assert allowed?("declare_liveliness_subscriber", "ingress", "asterism/**")
    assert allowed?("liveliness_token", "egress", "asterism/games/games/mahjong1"), "the tokens reach it"
    assert allowed?("declare_subscriber", "ingress", "asterism/*/*/@status")
    assert allowed?("put", "egress", "asterism/games/games/@status")
    assert allowed?("put", "egress", "asterism/games/games/mahjong1/state")
    %w[asterism/*/*/*/meta asterism/games/games/mahjong1/meta asterism/*/@profile asterism/*/*/@status].each do |k|
      assert allowed?("query", "ingress", k), k
    end
    assert allowed?("reply", "egress", "asterism/games/games/mahjong1/meta"), "the meta's answer reaches it"
    assert allowed?("reply", "egress", "asterism/games/@profile")
    assert allowed?("reply", "egress", "asterism/games/games/@status")
  end

  test "it calls nothing and writes only its own place" do
    refute allowed?("query", "ingress", "asterism/games/games/mahjong1/call/admin-viewer"), "no call, even as itself"
    refute allowed?("query", "ingress", "asterism/*/*/*/call/admin-viewer")
    refute allowed?("put", "ingress", "asterism/games/games/mahjong1/state")
    refute allowed?("put", "ingress", "asterism/games/games/@status")
    refute allowed?("declare_queryable", "ingress", "asterism/games/games/**")
    assert allowed?("liveliness_token", "ingress", "asterism/admin-viewer/cli-0a1b"), "its own app shows"
    assert allowed?("declare_queryable", "ingress", "asterism/admin-viewer/cli-0a1b/**")
    assert allowed?("put", "ingress", "asterism/admin-viewer/@profile")
  end

  test "the rooms stay closed" do
    refute allowed?("declare_liveliness_subscriber", "ingress", "room/*/asterism/**")
    refute allowed?("liveliness_token", "egress", "room/01/asterism/wasm-0101/game")
    refute allowed?("query", "ingress", "room/01/asterism/*/*/*/meta")
  end
end
