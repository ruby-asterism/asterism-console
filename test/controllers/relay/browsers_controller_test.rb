require "test_helper"
require_relative "../../test_helpers/room_test_helper"

# Members > Browsers (T8): the users' browsers' certificates (made when the
# handle is chosen, gone with a handle given up), whether the router's
# configuration lets them in or they wait for the apply, and whom each
# browser receives files from.
class Relay::BrowsersControllerTest < ActionDispatch::IntegrationTest
  include RoomTestHelper

  setup { setup_rooms(slots: 0, apply: false) }
  teardown { teardown_rooms }

  def cert?(name) = File.exist?(File.join(Relay::BrowserCerts.dir, "#{name}.pem"))

  test "choosing a handle makes the browser's certificate; it waits for the apply, then is in the ACL" do
    user = users(:user)
    sign_in_as(user)
    patch handle_account_path, params: { handle: "quill" }
    assert cert?("wasm-quill"), "made with the handle"
    refute cert?("wasm-pat"), "the old handle's had none here; nothing left of it"
    get account_path
    assert_select "#browser-certificate", /waiting to apply/
    assert_includes Relay::Applier.config_for.subject_names, "wasm-quill"
    write_router_config
    Relay::BrowserCerts.write_door_file!
    get account_path
    assert_select "#browser-certificate", /joins as\s+wasm-quill/
    assert_equal [ "wasm-quill" ], JSON.parse(File.read(Relay::BrowserCerts.door_file))["nodes"]
    patch handle_account_path, params: { handle: "rook" }
    refute cert?("wasm-quill"), "a handle given up takes its certificate with it"
    assert cert?("wasm-rook")
    assert_equal [], JSON.parse(File.read(Relay::BrowserCerts.door_file))["nodes"], "the door forgets the old name at once"
  end

  test "an admin sees the browsers, makes the missing certificates and chooses whom a browser receives from" do
    Relay::Issuer.new.issue_local(RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client")) # in the ACL
    sign_in_as(users(:admin))
    get relay_browsers_path
    assert_response :success
    assert_select "#browser-pat td", /none/
    post certify_relay_browsers_path
    assert_redirected_to relay_browsers_path
    assert cert?("wasm-pat")
    get relay_browsers_path
    assert_select "#browser-pat .badge", "waiting to apply"
    user = users(:user)
    get edit_relay_browser_path(user)
    assert_select "input[type=checkbox][name='user[receive_files_from_picked][]'][value=fmruby-aaaaaa]"
    assert_select "input[type=checkbox][value=wasm-pat]", 0, "not its own sender"
    patch relay_browser_path(user), params: { user: { receive_files_from_picked: [ "fmruby-aaaaaa", "" ],
                                                      receive_files_from_more: "wasm-*" } }
    assert_redirected_to relay_browsers_path
    user.reload
    assert_equal %w[fmruby-aaaaaa wasm-*], user.receivers("file")
    assert user.managed_receivers?
    entry = Relay::BrowserCerts.config_entries.find { _1["name"] == "wasm-pat" }
    assert_equal({ "file" => %w[fmruby-aaaaaa wasm-*], "checkpoint" => [] }, entry["receives"])
    rules = Relay::Applier.config_for.to_h.dig("access_control", "rules")
    assert(rules.any? { _1["key_exprs"].include?("asterism/wasm-pat/transfer/inbox/call/fmruby-aaaaaa") })
    write_router_config
    Relay::BrowserCerts.write_door_file!
    get relay_browsers_path
    assert_select "#browser-pat .badge", "in the ACL"
    get edit_relay_peer_path(RelayPeer.find_by!(name: "fmruby-aaaaaa"))
    assert_select "input[type=checkbox][value=wasm-pat]", 2, "a member may receive from the browser (both kinds)"
  end

  test "a user removed takes its browser's certificate with it" do
    Relay::BrowserCerts.ensure!(@signer.ca_pem)
    assert cert?("wasm-pat")
    users(:user).destroy!
    refute cert?("wasm-pat")
  end
end
