require "test_helper"

# The W4 guards: invitations instead of sign-up, a second factor for
# admins, the admin pages by address, sign-in limits, the page's CSP.
class W4GuardsTest < ActionDispatch::IntegrationTest
  setup { RateLimits::STORE.clear }

  def with_env(vars)
    old = vars.keys.to_h { [ _1, ENV[_1] ] }
    vars.each { ENV[_1] = _2 }
    yield
  ensure
    old.each { ENV[_1] = _2 }
  end

  def invite(admin: false)
    sign_in_as(users(:admin))
    post admin_invitations_path, params: { note: "for a friend", admin: admin ? "1" : "0" }
    assert_response :created
    link = css_select("code.wrap").map(&:text).find { _1.include?("/invitations/") }
    sign_out
    URI(link).path
  end

  test "there is no sign-up: no route makes a user without an invitation" do
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/users", method: :post) }
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/registrations", method: :post) }
    patch "/invitations/#{'A' * 43}", params: { user: { email_address: "x@example.org", password: "p" * 12,
                                                        password_confirmation: "p" * 12 } }
    assert_response :not_found
    refute User.exists?(email_address: "x@example.org")
  end

  test "an invitation makes one user, once" do
    path = invite
    get path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    params = { user: { email_address: "friend@example.org", password: "a-long-password", password_confirmation: "a-long-password" } }
    assert_difference("User.count", 1) { patch path, params: params }
    assert_redirected_to root_path
    u = User.find_by(email_address: "friend@example.org")
    refute u.admin?
    assert_equal u, Invitation.sole.user
    sign_out
    assert_no_difference("User.count") { patch path, params: { user: params[:user].merge(email_address: "other@example.org") } }
    assert_response :not_found
    get path
    assert_response :not_found
  end

  test "an expired or revoked invitation is closed; a bad password keeps it open" do
    path = invite
    patch path, params: { user: { email_address: "f@example.org", password: "short", password_confirmation: "short" } }
    assert_response :unprocessable_content
    assert_equal "open", Invitation.sole.status
    travel Invitation::TTL + 1.second do
      get path
      assert_response :not_found
    end
    Invitation.sole.revoke!
    get path
    assert_response :not_found
  end

  test "only admins invite" do
    sign_in_as(users(:user))
    assert_no_difference("Invitation.count") { post admin_invitations_path }
    assert_redirected_to root_path
  end

  test "an admin without a second factor reaches only the account page, when it is required" do
    with_env("CONSOLE_ADMIN_TOTP" => "required") do
      sign_in_as(users(:admin))
      get root_path
      assert_redirected_to account_path
      get relay_peers_path
      assert_redirected_to account_path
      get graph_path, as: :json
      assert_response :forbidden
      get account_path
      assert_response :success
      post start_otp_account_path
      code = ROTP::TOTP.new(users(:admin).reload.otp_secret).now
      post otp_confirm_account_path, params: { code: code }
      assert users(:admin).reload.otp_enabled?
      get relay_peers_path
      assert_response :success
      delete disable_otp_account_path, params: { current_password: "password-for-tests" }
      assert users(:admin).reload.otp_enabled?, "an admin cannot turn it off"
      sign_in_as(users(:user))
      get root_path
      assert_response :success, "a user does not need it"
    end
  end

  test "an invited admin is sent to the account page to turn the second factor on" do
    path = invite(admin: true)
    with_env("CONSOLE_ADMIN_TOTP" => "required") do
      patch path, params: { user: { email_address: "a2@example.org", password: "a-long-password", password_confirmation: "a-long-password" } }
      assert_redirected_to account_path
      get call_permissions_path
      assert_redirected_to account_path
    end
  end

  test "admin pages from an address outside CONSOLE_ADMIN_NETS: 403, even for an admin" do
    with_env("CONSOLE_ADMIN_NETS" => "192.0.2.0/24,2001:db8::/32") do
      sign_in_as(users(:admin))
      get relay_peers_path, headers: { "X-Forwarded-For" => "203.0.113.5" }
      assert_response :forbidden
      get admin_users_path, headers: { "X-Forwarded-For" => "203.0.113.5" }
      assert_response :forbidden
      get relay_peers_path, headers: { "X-Forwarded-For" => "192.0.2.44" }
      assert_response :success
      get root_path, headers: { "X-Forwarded-For" => "203.0.113.5" }
      assert_response :success, "the other pages are not limited by address"
    end
  end

  test "sign-in: 10 tries per address in 3 minutes, 20 per email address in an hour" do
    11.times { post session_path, params: { email_address: "user@example.com", password: "wrong" } }
    assert_equal "Try again later.", flash[:alert]
    RateLimits::STORE.clear
    20.times do |i|
      post session_path, params: { email_address: "user@example.com", password: "wrong" },
                         headers: { "X-Forwarded-For" => "198.51.100.#{i + 1}" }
    end
    post session_path, params: { email_address: "user@example.com", password: "password-for-tests" },
                       headers: { "X-Forwarded-For" => "198.51.100.200" }
    assert_equal "Try again later.", flash[:alert], "the right password is not taken either"
    post session_path, params: { email_address: "admin@example.com", password: "password-for-tests" },
                       headers: { "X-Forwarded-For" => "198.51.100.201" }
    assert_redirected_to root_url
  end

  test "the page's content security policy" do
    sign_in_as(users(:user))
    get root_path
    csp = response.headers["Content-Security-Policy"]
    assert_match(/script-src 'self' 'nonce-/, csp)
    assert_match(/object-src 'none'/, csp)
    assert_match(/frame-ancestors 'none'/, csp)
    refute_match(/unsafe-eval/, csp)
    nonce = csp[/'nonce-([^']+)'/, 1]
    assert_select "script[type=importmap][nonce=?]", nonce
  end

  test "the nav shows admin pages to admins only" do
    sign_in_as(users(:user))
    get calls_path
    assert_select "nav a[href=?]", "/passes"
    assert_select "nav a[href^='/admin']", 0
    assert_select "nav a[href=?]", "/recordings", 0
    sign_in_as(users(:admin))
    get calls_path
    assert_select "nav a[href=?]", "/admin/relay/peers"
  end
end
