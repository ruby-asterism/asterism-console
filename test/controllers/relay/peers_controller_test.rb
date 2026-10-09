require "test_helper"

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
    assert_difference("RelayPeer.count", 1) { post relay_peers_path, params: PARAMS }
    peer = RelayPeer.find_by!(name: "w2bot")
    assert_redirected_to relay_peer_path(peer)
    assert_equal [ %w[asterism/**], %w[demo/**], 30, true ], [ peer.rw_list, peer.ro_list, peer.cert_days, peer.enabled? ]
    refute peer.in_acl?, "no certificate yet"
    patch relay_peer_path(peer), params: { relay_peer: { enabled: "0", name: "renamed" } }
    assert_equal [ "w2bot", false ], [ peer.reload.name, peer.enabled? ], "the name stays"
    get relay_peers_path
    assert_select "td a", "w2bot"
    assert_select ".badge", "disabled"
    assert_difference("RelayPeer.count", -1) { delete relay_peer_path(peer) }
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

  test "a user reads the registry but cannot change it" do
    peer = RelayPeer.create!(name: "cruby", kind: "client", rw_keys: "asterism/**")
    sign_in_as(users(:user))
    get relay_peers_path
    assert_response :success
    get relay_peer_path(peer)
    assert_response :success
    assert_select "input[type=submit][value^='Issue']", 0
    assert_no_difference("RelayPeer.count") { post relay_peers_path, params: PARAMS }
    assert_redirected_to root_path
    patch relay_peer_path(peer), params: { relay_peer: { enabled: "0" } }
    assert peer.reload.enabled?
    post relay_peer_certificates_path(peer)
    assert_redirected_to root_path
    assert_equal 0, peer.certificates.count
    post relay_applies_path
    assert_redirected_to root_path
    assert_equal 0, RelayApply.count
  end
end
