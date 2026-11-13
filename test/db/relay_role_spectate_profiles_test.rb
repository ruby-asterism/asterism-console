require "test_helper"
require_relative "../test_helpers/acl_evaluator"
require Rails.root.join("db/migrate/20261113200000_relay_role_spectate_profiles").to_s

# A role that reads the game host's spectate values gets that
# application's profile and topics on update (protocol 2: spectate is an
# application of its own): what `asterism topic list` asks with a
# spectator's certificate. Only roles with a spectate read line change,
# nothing is removed, and running it again changes nothing.
class RelayRoleSpectateProfilesTest < ActiveSupport::TestCase
  def fix(read, ask) = RelayRoleSpectateProfiles.with_spectate_profiles(read.join("\n"), ask.join("\n"))
  def lines(t) = t.transform_values { _1.split("\n") }

  # docs/rooms.md before protocol 2.
  SPECTATOR = [ %w[asterism/*/spectate asterism/*/spectate/**], [] ].freeze

  test "spectator: read gets the spectate application's @profile and @pubs, ask its @profile" do
    t, notes = fix(*SPECTATOR)
    assert_equal SPECTATOR[0] + %w[asterism/*/spectate/@profile asterism/*/spectate/@pubs], lines(t)[:read]
    assert_equal %w[asterism/*/spectate/@profile], lines(t)[:ask]
    assert_equal 3, notes.size
  end

  test "the lines follow the role's own prefix" do
    t, = fix(%w[asterism/games/spectate/**], %w[asterism/*/x/*/meta])
    assert_equal %w[asterism/games/spectate/** asterism/games/spectate/@profile asterism/games/spectate/@pubs], lines(t)[:read]
    assert_equal %w[asterism/*/x/*/meta asterism/games/spectate/@profile], lines(t)[:ask]
  end

  test "roles that do not read the spectate values are left as they are" do
    [ [ %w[asterism/*/games/**], %w[asterism/*/games/*/meta] ], # players
      [ %w[asterism/** asterism/*/*/@profile asterism/*/*/@pubs], %w[asterism/*/*/@profile] ], # viewer
      [ %w[asterism/*/game], [] ], # games-host's read (its spectate lines are in rw)
      [ %w[asterism/*/spectate], [] ] ].each do |role|
      t, notes = fix(*role)
      assert_empty notes, role.inspect
      assert_equal({ read: role[0], ask: role[1] }, lines(t))
    end
  end

  test "again: nothing changes" do
    t, = fix(*SPECTATOR)
    again, notes = RelayRoleSpectateProfiles.with_spectate_profiles(t[:read], t[:ask])
    assert_equal t, again
    assert_empty notes
  end

  test "on the database: a spectator's certificate can ask spectate's profile and receive its topics" do
    RelayRole.delete_all
    host = RelayRole.create!(name: "games-host",
                             rw_templates: %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile
                                              asterism/${node}/*/@profile asterism/${node}/*/@status
                                              asterism/${node}/*/@pubs asterism/${node}/spectate
                                              asterism/${node}/spectate/**].join("\n"),
                             read_templates: "asterism/*/game", watch_templates: "asterism/**")
    spectator = RelayRole.create!(name: "spectator", read_templates: SPECTATOR[0].join("\n"), watch_templates: "asterism/**")
    peers = [ { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
              { "name" => "spectator-a", "kind" => "client", "roles" => %w[spectator], "in_acl" => true } ]
    acl = -> { Relay::CloudConfig.new(peers, {}, roles: [ host.reload.to_config, spectator.reload.to_config ]).access_control }
    # What topic list does: query the application's @profile (?pubs), get
    # the reply; and the @pubs puts that follow.
    topic_list = lambda do |a|
      [ AclEvaluator.allowed?(a, "spectator-a", "query", "ingress", "asterism/games/spectate/@profile"),
        AclEvaluator.allowed?(a, "spectator-a", "reply", "egress", "asterism/games/spectate/@profile"),
        AclEvaluator.allowed?(a, "spectator-a", "declare_subscriber", "ingress", "asterism/games/spectate/@pubs"),
        AclEvaluator.allowed?(a, "spectator-a", "put", "egress", "asterism/games/spectate/@pubs") ]
    end
    assert_equal [ false, false, false, false ], topic_list.(acl.()), "before: the values only"
    out = StringIO.new
    $stdout = out
    RelayRoleSpectateProfiles.new.up
    $stdout = STDOUT
    assert_match(%r{relay role spectator \(spectate's profile\): read \+ asterism/\*/spectate/@profile}, out.string)
    refute_match(/games-host/, out.string)
    assert spectator.reload.valid?
    a = acl.()
    assert_equal [ true, true, true, true ], topic_list.(a)
    # Still nothing else: not the players' application, no call, no write.
    refute AclEvaluator.allowed?(a, "spectator-a", "query", "ingress", "asterism/games/games/@profile")
    refute AclEvaluator.allowed?(a, "spectator-a", "put", "egress", "asterism/games/games/@pubs")
    refute AclEvaluator.allowed?(a, "spectator-a", "query", "ingress", "asterism/games/spectate/t1/call/spectator-a")
    refute AclEvaluator.allowed?(a, "spectator-a", "put", "ingress", "asterism/games/spectate/@pubs")
    out = StringIO.new
    $stdout = out
    RelayRoleSpectateProfiles.new.up
    $stdout = STDOUT
    assert_empty out.string, "again: nothing to say"
  ensure
    $stdout = STDOUT
  end
end
