require "test_helper"

# The profile icons (V2.5), served by their hash to signed-in users.
class IconsControllerTest < ActionDispatch::IntegrationTest
  PNG = File.binread(Rails.root.join("app/assets/images/asterism_console.png"))

  test "an icon by its hash, for a signed-in user" do
    NodeIcon.keep("0a1b2c3d", PNG, 32, 32)
    get icon_path("0a1b2c3d")
    assert_redirected_to new_session_path
    sign_in_as(users(:user))
    get icon_path("0a1b2c3d")
    assert_response :ok
    assert_equal "image/png", response.media_type
    assert_equal PNG, response.body.b
    assert_match(/max-age=\d{8}, private/, response.headers["Cache-Control"])
    get icon_path("ffffffff")
    assert_response :not_found
  end

  test "keep is idempotent, and known tells which hashes are stored" do
    a = NodeIcon.keep("0a1b2c3d", PNG, 32, 32)
    assert_equal a, NodeIcon.keep("0a1b2c3d", PNG, 32, 32)
    assert_equal Set["0a1b2c3d"], NodeIcon.known([ "0a1b2c3d", "ffffffff", nil ])
    assert_raises(ActiveRecord::RecordInvalid) { NodeIcon.keep("NOT-HEX!", PNG, 1, 1) }
  end
end
