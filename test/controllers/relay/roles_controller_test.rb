require "test_helper"

# Roles (G1.5): admins make and edit them, rows pick them, the pages show
# what they become in the ACL.
class Relay::RolesControllerTest < ActionDispatch::IntegrationTest
  PARAMS = { relay_role: { name: "rover-home", description: "show a rover", rw_templates: "asterism/${node}/rover/**\n",
                           read_templates: "", ask_templates: "asterism/*/rover/*/call/${node}\n",
                           watch_templates: "asterism/**", browser_app: "", for_browsers: "0" } }.freeze

  test "an admin makes a role, gives it to a row and sees what it becomes" do
    sign_in_as(users(:admin))
    get relay_roles_path
    assert_select "td a", "match"
    assert_difference("RelayRole.count", 1) { post relay_roles_path, params: PARAMS }
    role = RelayRole.find_by!(name: "rover-home")
    assert_redirected_to relay_role_path(role)
    assert_equal [ "asterism/${node}/rover/**" ], role.templates["rw"]
    peer = RelayPeer.create!(name: "home-a", kind: "router", nodes: "fmruby-aaaaaa\nfmruby-bbbbbb")
    get edit_relay_peer_path(peer)
    assert_select "input[type=checkbox][name='relay_peer[role_ids][]'][value='#{role.id}']"
    patch relay_peer_path(peer), params: { relay_peer: { role_ids: [ "", role.id.to_s, relay_roles(:match).id.to_s ] } }
    assert_equal %w[match rover-home], peer.reload.roles.map(&:name)
    get relay_role_path(role)
    assert_select "code", "asterism/fmruby-bbbbbb/rover/**"
    assert_select "code", "asterism/*/rover/*/call/fmruby-aaaaaa"
    get relay_peer_path(peer)
    assert_select "code", "asterism/*/game/*/call/fmruby-aaaaaa"
    patch relay_role_path(role), params: { relay_role: { rw_templates: "asterism/${nodes}/x\n" } }
    assert_response :unprocessable_content, "only ${node}"
    patch relay_role_path(role), params: { relay_role: { name: "Bad Name" } }
    assert_response :unprocessable_content
    assert_difference("RelayPeerRole.count", -1) { delete relay_role_path(role) }
    assert_equal %w[match], peer.reload.roles.map(&:name)
  end

  test "a new router starts with no keys" do
    sign_in_as(users(:admin))
    get new_relay_peer_path(kind: "router")
    assert_select "textarea[name='relay_peer[rw_keys]']", text: ""
  end

  test "users cannot see or change roles" do
    sign_in_as(users(:user))
    get relay_roles_path
    assert_redirected_to root_path
    assert_no_difference("RelayRole.count") { post relay_roles_path, params: PARAMS }
  end
end
