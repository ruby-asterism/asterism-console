require "test_helper"

# Roles (G1.5): admins make and edit them, rows pick them, the pages show
# what they become in the ACL.
class Relay::RolesControllerTest < ActionDispatch::IntegrationTest
  PARAMS = { relay_role: { name: "rover-home", description: "show a rover", rw_templates: "asterism/${node}/rover/**\n",
                           read_templates: "", ask_templates: "asterism/*/rover/*/call/${node}\n",
                           watch_templates: "asterism/**", for_browsers: "0" } }.freeze

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

  test "the role form has the app helper, help for each template, and the descriptions are shown" do
    sign_in_as(users(:admin))
    get new_relay_role_path
    assert_select "form.role-form[data-controller=role-form]" do
      assert_select "input#role_app[data-role-form-target=app]:not([name])", 1, "the helper is not sent"
      assert_select "button[type=button][data-action='role-form#fill']", "Fill in"
      %w[name description rw read ask watch].each { assert_select "[data-role-form-target=#{_1}]", 1 }
      assert_select "textarea[name='relay_role[rw_templates]'][data-role-form-target=rw]"
      assert_select ".field-help", minimum: 5
      assert_select ".template-help dt code", "${node}"
      assert_select ".template-help dt code", "**"
      assert_select "input[name='relay_role[for_browsers]']"
      assert_select "[name='relay_role[browser_app]']", 0, "a role is permissions only (0.3.12)"
    end
    assert_no_match "Opens in a browser page", response.body
    get relay_roles_path
    assert_select "th", "What it is for"
    assert_select "td.role-desc", relay_roles(:match).description
    peer = RelayPeer.create!(name: "home-a", kind: "router")
    get edit_relay_peer_path(peer)
    assert_select "label.role-pick strong", "match"
    assert_select "label.role-pick .role-desc", relay_roles(:match).description
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
