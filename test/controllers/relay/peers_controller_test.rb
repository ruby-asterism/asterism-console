require "test_helper"
require "tmpdir"

class Relay::PeersControllerTest < ActionDispatch::IntegrationTest
  PARAMS = { relay_peer: { name: "w2bot", kind: "client", description: "a test node", rw_keys: "asterism/**\n",
                           ro_keys: "demo/**\n", admin_space: "0", enabled: "1", cert_days: "30" } }.freeze

  test "an admin registers, edits and removes a peer" do
    sign_in_as(users(:admin))
    get relay_peers_path
    assert_response :success
    assert_select ".hint", /Nobody is registered/
    get new_relay_peer_path(kind: "router")
    assert_select "select option[selected]", "router"
    assert_select "input[type=checkbox][name='relay_peer[admin_space]'][checked]", 1, "a router's is read through by default"
    assert_select "label", /Console can see behind this router/
    get new_relay_peer_path(kind: "client")
    assert_select "input[type=checkbox][name='relay_peer[admin_space]'][checked]", 0, "a client does not read the cloud's"
    assert_select "label", /May read the cloud router's status/
    assert_difference("RelayPeer.count", 1) { post relay_peers_path, params: PARAMS }
    peer = RelayPeer.find_by!(name: "w2bot")
    assert_redirected_to relay_peer_path(peer)
    assert_equal [ %w[asterism/**], %w[demo/**], 30, true ], [ peer.rw_list, peer.ro_list, peer.cert_days, peer.enabled? ]
    refute peer.in_acl?, "no certificate yet"
    patch relay_peer_path(peer), params: { relay_peer: { enabled: "0", name: "renamed" } }
    assert_equal [ "w2bot", false ], [ peer.reload.name, peer.enabled? ], "the name stays"
    get relay_peers_path
    assert_select "td a", "w2bot"
    assert_select "th", "Console sees"
    assert_select ".badge", "disabled"
    assert_difference("RelayPeer.count", -1) { delete relay_peer_path(peer) }
  end

  test "a display name (0.3.5): saved when registering and editing, shown before the name" do
    sign_in_as(users(:admin))
    get new_relay_peer_path(kind: "client")
    assert_select "input[name='relay_peer[display_name]'][maxlength=?]", RelayPeer::DISPLAY_NAME_MAX.to_s
    post relay_peers_path, params: { relay_peer: PARAMS[:relay_peer].merge(name: "fmruby-aaaaaa", display_name: " Tab5 ") }
    peer = RelayPeer.find_by!(name: "fmruby-aaaaaa")
    assert_equal [ "Tab5", "Tab5 (fmruby-aaaaaa)" ], [ peer.display_name, peer.label ]
    get relay_peers_path
    assert_select "h2", "Members"
    assert_select "th", "Display name"
    assert_select "td.display-name a[href=?]", relay_peer_path(peer), "Tab5"
    assert_select "td a", "fmruby-aaaaaa"
    get relay_peer_path(peer)
    assert_select "h2", /Tab5 \(fmruby-aaaaaa\)/
    patch relay_peer_path(peer), params: { relay_peer: { display_name: "P4-Nano" } }
    assert_equal [ "P4-Nano", "fmruby-aaaaaa" ], [ peer.reload.display_name, peer.name ]
    assert_equal "P4-Nano", RelayPeer.registry.find { _1["name"] == "fmruby-aaaaaa" }["display_name"]
    patch relay_peer_path(peer), params: { relay_peer: { display_name: "x" * 41 } }
    assert_response :unprocessable_content
    patch relay_peer_path(peer), params: { relay_peer: { display_name: "  " } }
    assert_equal [ nil, "fmruby-aaaaaa" ], [ peer.reload.display_name, peer.label ], "emptied: the name alone"
    get relay_peers_path
    assert_select "td.display-name .hint", "-"
  end

  test "the display name is not in the router's configuration: changing it needs no apply" do
    peer = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client", cert_days: 30)
    before = peer.to_config
    peer.update!(display_name: "Tab5")
    assert_equal before, peer.reload.to_config
  end

  test "the URLs before 0.3.5 (/admin/relay/...) lead to the same pages under /admin/members" do
    sign_in_as(users(:admin))
    assert_equal "/admin/members/peers", relay_peers_path
    get "/admin/relay/peers"
    assert_redirected_to "/admin/members/peers"
    get "/admin/relay/peers/new?kind=router"
    assert_redirected_to "/admin/members/peers/new?kind=router"
    get "/admin/relay/roles/3/edit"
    assert_redirected_to "/admin/members/roles/3/edit"
    get "/admin/relay"
    assert_redirected_to "/admin/members"
    get "/admin/members"
    assert_redirected_to "/admin/members/peers"
    get "/admin"
    assert_redirected_to "/admin/members/peers"
    get relay_peers_path
    assert_select ".nav-group.admin a.current", "Members"
  end

  test "apply is not a tab: a banner leads to it while the cloud router's file differs" do
    Dir.mktmpdir do |dir|
      old = ENV["ASTERISM_RELAY_GENERATED_DIR"]
      ENV["ASTERISM_RELAY_GENERATED_DIR"] = dir
      sign_in_as(users(:admin))
      get relay_peers_path
      assert_select ".tabs a", 2
      assert_select ".tabs a.current", "Registry"
      assert_select ".tabs a[href=?]", new_relay_apply_path, 0
      assert_select ".apply-banner", /Changes not yet applied to the cloud router/
      assert_select ".apply-banner a[href=?]", new_relay_apply_path, "Review and apply"
      get relay_roles_path
      assert_select ".tabs a.current", "Roles"
      assert_select ".apply-banner a[href=?]", new_relay_apply_path
      get new_relay_apply_path
      assert_response :success
      assert_select ".apply-banner", 0, "not on the confirmation itself"
      assert_select "a[href=?]", relay_applies_path, "Applies so far"
      get relay_applies_path
      assert_response :success
      Relay::Applier.new.write(Relay::Applier.config_for.text(by: "admin@example.com"))
      get relay_peers_path
      assert_select ".apply-banner", 0
      assert_select ".tabs .tabs-aside", /runs this registry/
    ensure
      ENV["ASTERISM_RELAY_GENERATED_DIR"] = old
    end
  end

  test "the relay pages show the router watch's last automatic restart (0.3.2)" do
    Dir.mktmpdir do |dir|
      old = ENV["ASTERISM_RELAY_GENERATED_DIR"]
      ENV["ASTERISM_RELAY_GENERATED_DIR"] = dir
      sign_in_as(users(:admin))
      get relay_peers_path
      assert_select ".router-watch", 0
      File.write(File.join(dir, Bridge::RouterWatch::STATUS_FILE),
                 JSON.generate("state" => "ok", "restarted_at" => 2.hours.ago.utc.iso8601,
                               "reason" => "2 checks in a row could not open a new session (last: timeout)"))
      get relay_peers_path
      assert_select ".notice-bar.router-watch", /Last automatic restart of the cloud router: .*2 checks in a row/
      get relay_applies_path
      assert_select ".router-watch", 1
      File.write(File.join(dir, Bridge::RouterWatch::STATUS_FILE),
                 JSON.generate("restarted_at" => 3.days.ago.utc.iso8601, "reason" => "x"))
      get relay_peers_path
      assert_select ".hint.router-watch", 1
    ensure
      ENV["ASTERISM_RELAY_GENERATED_DIR"] = old
    end
  end

  test "bad names and keys are not saved" do
    sign_in_as(users(:admin))
    [ { name: "../x" }, { name: "ca" }, { rw_keys: "a b\n" }, { ro_keys: "x?y" }, { kind: "bridge" },
      { cert_days: "9999" }, { ip_addresses: "not-an-ip" } ].each do |bad|
      assert_no_difference("RelayPeer.count", bad.inspect) do
        post relay_peers_path, params: { relay_peer: PARAMS[:relay_peer].merge(bad) }
      end
      assert_response :unprocessable_content
    end
  end

  test "a user can neither read nor change the registry (admin pages)" do
    peer = RelayPeer.create!(name: "cruby", kind: "client", rw_keys: "asterism/**")
    sign_in_as(users(:user))
    get relay_peers_path
    assert_redirected_to root_path
    get relay_peer_path(peer)
    assert_redirected_to root_path
    assert_no_difference("RelayPeer.count") { post relay_peers_path, params: PARAMS }
    assert_redirected_to root_path
    patch relay_peer_path(peer), params: { relay_peer: { enabled: "0" } }
    assert peer.reload.enabled?
    post relay_peer_certificates_path(peer), params: { spki: "x" }, as: :json
    assert_response :forbidden
    assert_equal 0, peer.certificates.count
    post relay_applies_path
    assert_redirected_to root_path
    assert_equal 0, RelayApply.count
  end
end
