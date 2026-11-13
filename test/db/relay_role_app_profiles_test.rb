require "test_helper"
require_relative "../test_helpers/acl_evaluator"
require_relative "../test_helpers/game_host_connections"
require Rails.root.join("db/migrate/20261113100000_relay_role_app_profiles").to_s
require Rails.root.join("db/migrate/20261113300000_relay_role_shared_places").to_s

# Roles made before Asterism wire protocol 2 brought to it on update: the
# example role's nodes answer their applications' profiles, a role's
# protocol 1 status lines get their protocol 2 company, the status ask
# becomes the profile ask, nothing an admin wrote is removed, and running
# it again changes nothing.
class RelayRoleAppProfilesTest < ActiveSupport::TestCase
  def fix(name, rw, read, ask) = RelayRoleAppProfiles.with_app_profiles(name, rw.join("\n"), read.join("\n"), ask.join("\n"))
  def lines(t) = t.transform_values { _1.split("\n") }

  # docs/rooms.md before protocol 2.
  HOST = [ %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile asterism/${node}/*/@status
              asterism/${node}/spectate asterism/${node}/spectate/**], %w[asterism/*/game], [] ].freeze
  # docs/g1_5.md before protocol 2.
  VIEWER = [ %w[asterism/${node}/** asterism/${node}/@profile], %w[asterism/** asterism/*/@profile asterism/*/*/@status],
             %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@status] ].freeze

  test "the example role: its nodes' applications answer and put" do
    t, notes = fix("match", %w[asterism/${node} asterism/${node}/game/** asterism/${node}/@profile], %w[asterism/*],
                   %w[asterism/*/@profile])
    assert_equal %w[asterism/${node} asterism/${node}/game/** asterism/${node}/@profile asterism/${node}/*/@profile
                    asterism/${node}/*/@status asterism/${node}/*/@pubs], lines(t)[:rw]
    assert_equal [ %w[asterism/*], %w[asterism/*/@profile] ], lines(t).values_at(:read, :ask)
    assert_equal 3, notes.size
  end

  test "games-host: @profile and @pubs next to its @status; the other lines stay" do
    t, = fix("games-host", *HOST)
    assert_equal HOST[0] + %w[asterism/${node}/*/@profile asterism/${node}/*/@pubs], lines(t)[:rw]
    assert_equal HOST[1], lines(t)[:read]
  end

  test "viewer: the status ask becomes the profile ask, read gets @profile and @pubs" do
    t, notes = fix("viewer", *VIEWER)
    assert_equal VIEWER[0], lines(t)[:rw]
    assert_equal VIEWER[1] + %w[asterism/*/*/@pubs asterism/*/*/@profile], lines(t)[:read]
    assert_equal %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@profile], lines(t)[:ask]
    assert_includes notes, "ask asterism/*/*/@status -> asterism/*/*/@profile"
  end

  test "a role without protocol 1 status lines (and not the example) is left as it is" do
    role = [ %w[asterism/${node}/** asterism/${node}/@profile], %w[asterism/*/spectate/**], %w[asterism/*/x/*/meta] ]
    t, notes = fix("spectator", *role)
    assert_empty notes
    assert_equal({ rw: role[0], read: role[1], ask: role[2] }, lines(t))
  end

  test "again: nothing changes" do
    [ [ "match", *HOST ], [ "games-host", *HOST ], [ "viewer", *VIEWER ] ].each do |name, *role|
      t, = fix(name, *role)
      again, notes = RelayRoleAppProfiles.with_app_profiles(name, t[:rw], t[:read], t[:ask])
      assert_equal t, again, name
      assert_empty notes, name
    end
  end

  test "games-host made before protocol 2: the host's connections do all they do once updated (with the shared places)" do
    peers = [ { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true } ]
    acl = ->(rw, read) do
      role = { "name" => "games-host", "for_browsers" => false,
               "templates" => { "rw" => rw, "read" => read, "watch" => %w[asterism/**] } }
      Relay::CloudConfig.new(peers, {}, roles: [ role ]).access_control
    end
    refute_empty GameHostConnections.refused(acl.(HOST[0], HOST[1]))
    t, = fix("games-host", *HOST)
    sh, = RelayRoleSharedPlaces.with_shared_places("games-host", t[:rw], t[:read], t[:ask])
    assert_empty GameHostConnections.refused(acl.(lines(sh)[:rw], lines(sh)[:read]))
  end

  test "on the database: the rows change, logged; the router lets the host and the viewer do protocol 2" do
    RelayRole.delete_all
    host = RelayRole.create!(name: "games-host", rw_templates: HOST[0].join("\n"), read_templates: HOST[1].join("\n"),
                             watch_templates: "asterism/**")
    viewer = RelayRole.create!(name: "viewer", rw_templates: VIEWER[0].join("\n"), read_templates: VIEWER[1].join("\n"),
                               ask_templates: VIEWER[2].join("\n"), watch_templates: "asterism/**")
    m = RelayRoleAppProfiles.new
    out = StringIO.new
    $stdout = out
    m.up
    $stdout = STDOUT
    assert_match(/relay role games-host \(protocol 2\): rw \+ asterism\/\$\{node\}\/\*\/@profile/, out.string)
    assert_match(/relay role viewer \(protocol 2\): .*ask asterism\/\*\/\*\/@status -> asterism\/\*\/\*\/@profile/, out.string)
    assert host.reload.valid?
    assert viewer.reload.valid?
    peers = [ { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
              { "name" => "admin-viewer", "kind" => "client", "roles" => %w[viewer], "in_acl" => true } ]
    acl = Relay::CloudConfig.new(peers, {}, roles: [ host.to_config, viewer.to_config ]).access_control
    assert AclEvaluator.allowed?(acl, "games", "declare_queryable", "ingress", "asterism/games/games/@profile")
    assert AclEvaluator.allowed?(acl, "games", "put", "ingress", "asterism/games/games/@pubs")
    assert AclEvaluator.allowed?(acl, "admin-viewer", "query", "ingress", "asterism/games/games/@profile")
    assert AclEvaluator.allowed?(acl, "admin-viewer", "reply", "egress", "asterism/games/games/@profile")
    assert AclEvaluator.allowed?(acl, "admin-viewer", "put", "egress", "asterism/games/games/@pubs")
    out = StringIO.new
    $stdout = out
    m.up
    $stdout = STDOUT
    assert_empty out.string, "again: nothing to say"
  ensure
    $stdout = STDOUT
  end
end
