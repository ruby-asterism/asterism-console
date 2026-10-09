require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:user) }

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
end
