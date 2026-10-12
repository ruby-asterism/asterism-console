require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  test "an admin lists users, changes another's role, turns off another's second factor; not their own" do
    sign_in_as(users(:admin))
    get admin_users_path
    assert_response :success
    assert_select "td", "user@example.com"
    patch admin_user_path(users(:user), admin: true)
    assert users(:user).reload.admin?
    patch admin_user_path(users(:admin), admin: false)
    assert users(:admin).reload.admin?, "not their own role"
    users(:user).update!(otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    delete otp_admin_user_path(users(:user))
    refute users(:user).reload.otp_enabled?
    delete admin_user_path(users(:admin))
    assert User.exists?(users(:admin).id), "not themselves"
  end

  test "a user cannot reach the users page" do
    sign_in_as(users(:user))
    get admin_users_path
    assert_redirected_to root_path
    patch admin_user_path(users(:user), admin: true)
    refute users(:user).reload.admin?
  end
end
