require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    RateLimits::STORE.clear
    @user = users(:user)
  end

  test "new" do
    get new_session_path
    assert_response :success
    assert_select "input[type=password]"
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password-for-tests" }
    assert_redirected_to root_url
    assert cookies[:session_id]
    get root_path
    assert_response :success
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }
    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "destroy" do
    sign_in_as(@user)
    delete session_path
    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
    get root_path
    assert_redirected_to new_session_path
  end

  test "a session older than its lifetime is not taken" do
    sign_in_as(@user)
    Current.session.update!(created_at: (Session::LIFETIME + 1.minute).ago)
    get root_path
    assert_redirected_to new_session_path
  end

  test "with TOTP on, the password alone does not sign in" do
    @user.start_otp!
    @user.update!(otp_enabled_at: Time.current)
    post session_path, params: { email_address: @user.email_address, password: "password-for-tests" }
    assert_redirected_to otp_session_path
    assert_nil cookies[:session_id]
    get root_path
    assert_redirected_to new_session_path

    post verify_otp_session_path, params: { code: "000000" }
    assert_redirected_to otp_session_path
    assert_nil cookies[:session_id]

    code = ROTP::TOTP.new(@user.otp_secret).now
    post verify_otp_session_path, params: { code: code }
    assert_redirected_to root_url
    assert cookies[:session_id]

    # The same code is not taken twice.
    sign_out
    post session_path, params: { email_address: @user.email_address, password: "password-for-tests" }
    post verify_otp_session_path, params: { code: code }
    assert_redirected_to otp_session_path
  end

  test "the code step without the password step" do
    get otp_session_path
    assert_redirected_to new_session_path
    post verify_otp_session_path, params: { code: "123456" }
    assert_redirected_to new_session_path
  end

  # T8c: "Remember this browser for 30 days" on the code page.
  def turn_on_otp
    @user.start_otp!
    @user.update!(otp_enabled_at: Time.current)
  end

  def sign_in_with_password
    post session_path, params: { email_address: @user.email_address, password: "password-for-tests" }
  end

  def code_now(at = Time.current)
    ROTP::TOTP.new(@user.reload.otp_secret).at(at)
  end

  def remember_with_code(at = Time.current)
    sign_in_with_password
    assert_redirected_to otp_session_path
    post verify_otp_session_path, params: { code: code_now(at), remember: "1" }
    assert_redirected_to root_url
    row = RememberedBrowser.sole
    assert_equal @user.id, row.user_id
    refute_includes row.token_digest, cookies[:remembered_browser].to_s, "only the SHA-256 is kept"
    row
  end

  test "a remembered browser signs in with the password alone; the password is still asked" do
    turn_on_otp
    row = remember_with_code
    assert_in_delta (Time.current + 30.days).to_i, row.expires_at.to_i, 5
    raw = cookies[:remembered_browser]
    assert raw.present?
    delete session_path
    post session_path, params: { email_address: @user.email_address, password: "wrong" }
    assert_redirected_to new_session_path, "the password is asked as before"
    assert_empty cookies[:session_id].to_s
    sign_in_with_password
    assert_redirected_to root_url, "no code"
    assert cookies[:session_id].present?
    assert row.reload.last_used_at
  end

  test "without ticking the box nothing is remembered" do
    turn_on_otp
    sign_in_with_password
    post verify_otp_session_path, params: { code: code_now }
    assert_redirected_to root_url
    assert_equal 0, RememberedBrowser.count
    assert_nil cookies[:remembered_browser]
  end

  test "an expired, forgotten or foreign row asks for the code again" do
    turn_on_otp
    row = remember_with_code(30.seconds.ago)
    delete session_path
    row.update!(expires_at: 1.minute.ago)
    sign_in_with_password
    assert_redirected_to otp_session_path, "expired"
    row.update!(expires_at: 1.day.from_now)
    sign_in_with_password
    assert_redirected_to root_url
    delete forget_browser_account_path(row)
    assert_redirected_to account_path(anchor: "browsers")
    assert_equal 0, RememberedBrowser.count
    delete session_path
    sign_in_with_password
    assert_redirected_to otp_session_path, "forgotten"
    # Another user's row with this browser's cookie is not this user's.
    other = users(:admin)
    other.start_otp!
    other.update!(otp_enabled_at: Time.current)
    token = "a" * 43
    RememberedBrowser.create!(user: other, token_digest: RememberedBrowser.digest(token), expires_at: 1.day.from_now)
    assert_nil RememberedBrowser.find_for(@user, token)
    assert RememberedBrowser.find_for(other, token)
  end

  test "a new password or a change to TOTP forgets every remembered browser" do
    turn_on_otp
    remember_with_code
    @user.update!(password: "another-password-for-tests", password_confirmation: "another-password-for-tests")
    assert_equal 0, RememberedBrowser.count, "new password"
    @user.update!(password: "password-for-tests", password_confirmation: "password-for-tests")
    delete session_path
    remember_with_code(31.seconds.from_now)
    @user.otp_last_step = nil
    @user.verify_otp(code_now)
    assert_equal 1, RememberedBrowser.count, "a code used is not a change to TOTP"
    @user.disable_otp!
    assert_equal 0, RememberedBrowser.count, "TOTP turned off"
    delete session_path
    turn_on_otp
    remember_with_code
    @user.start_otp!
    assert_equal 0, RememberedBrowser.count, "a new secret"
    @user.update!(otp_enabled_at: Time.current)
    delete session_path
    sign_in_with_password
    assert_redirected_to otp_session_path, "the cookie is left, its row is not"
  end

  test "the account page lists them and forgets them all" do
    turn_on_otp
    remember_with_code
    get account_path
    assert_select "#browsers"
    assert_select "span.badge", "this browser"
    assert_select "td code", /./
    delete forget_browsers_account_path
    assert_redirected_to account_path(anchor: "browsers")
    assert_equal 0, RememberedBrowser.count
    get account_path
    assert_select "span.badge", { text: "this browser", count: 0 }
  end

  test "the box is on the code page and is off by default" do
    turn_on_otp
    sign_in_with_password
    get otp_session_path
    assert_select "input[type=checkbox][name=remember][value='1']:not([checked])"
  end
end
