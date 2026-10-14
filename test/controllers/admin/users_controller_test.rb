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

  test "the backups' state: a failed backup warns on Users and Relay, the last good one is named" do
    dir = Dir.mktmpdir("backups")
    ENV["ASTERISM_BACKUP_DIR"] = dir
    sign_in_as(users(:admin))
    get admin_users_path
    assert_select ".backup-warning", 0
    ConsoleBackup::Status.record(dir, ok: true, name: "asterism-20261014-030000-0.1.3-daily.tar.gz")
    get admin_users_path
    assert_select ".backup-warning", 0
    assert_select "p.hint code", "asterism-20261014-030000-0.1.3-daily.tar.gz"
    ConsoleBackup::Status.record(dir, ok: false, error: "no space left on device", now: Time.now + 1)
    get admin_users_path
    assert_select ".backup-warning", /no space left on device/
    get relay_peers_path
    assert_select ".backup-warning", /no space left on device/
  ensure
    ENV.delete("ASTERISM_BACKUP_DIR")
    FileUtils.rm_rf(dir) if dir
  end
end
