require "test_helper"

# Passes for the browser build's wss:// (W4): made by a signed-in user,
# shown once, checked by the proxy (check), refused when expired or revoked.
class BrowserPassesControllerTest < ActionDispatch::IntegrationTest
  setup { RateLimits::STORE.clear }

  def make_pass(user = users(:user))
    sign_in_as(user)
    post browser_passes_path
    assert_response :created
    css_select("dd code.wrap").first.text
  end

  def check(token, ip: "198.51.100.7")
    get check_browser_passes_path, headers: { "X-Asterism-Pass" => token, "X-Forwarded-For" => ip }.compact
    response.status
  end

  test "a pass is shown once, as a link with the router; only its digest is kept" do
    with_env("ASTERISM_PASS_ROUTER" => "ws/router.example.org:7443",
             "ASTERISM_STUDIO_URL" => "https://studio.example.org/index.html") do
      token = make_pass
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_select "a[href=?]", "https://studio.example.org/index.html?zenoh=ws%2Frouter.example.org%3A7443&zenoh_pass=#{token}"
      pass = BrowserPass.sole
      assert_equal BrowserPass.digest(token), pass.token_digest
      refute_includes BrowserPass.all.map(&:attributes).to_s, token
      assert_in_delta BrowserPass::TTL.from_now, pass.expires_at, 5
      get browser_passes_path
      refute_includes response.body, token, "not shown again"
    end
  end

  test "the proxy's check: 204 for a live pass, 401 without, expired or revoked" do
    token = make_pass
    sign_out
    assert_equal 204, check(token)
    get check_browser_passes_path, headers: { "X-Original-URI" => "/?pass=#{token}", "X-Forwarded-For" => "198.51.100.7" }
    assert_response :no_content, "the pass from the WebSocket URL nginx hands over"
    pass = BrowserPass.sole
    assert_equal [ 2, "198.51.100.7" ], [ pass.reload.uses, pass.last_used_ip ]
    assert_equal 401, check(nil)
    assert_equal 401, check("nonsense")
    assert_equal 401, check("A" * 43)
    travel BrowserPass::TTL + 1.second do
      assert_equal 401, check(token)
      get check_browser_passes_path, headers: { "X-Original-URI" => "/?pass=#{token}", "X-Forwarded-For" => "198.51.100.8" }
      assert_response :unauthorized, "expired (from the URI nginx hands over)"
    end
    assert_equal 2, pass.reload.refused
    pass.revoke!(users(:user))
    assert_equal 401, check(token)
  end

  test "revoking: the owner or an admin, nobody else" do
    make_pass(users(:admin))
    pass = BrowserPass.sole
    sign_in_as(users(:user))
    patch revoke_browser_pass_path(pass)
    assert_response :not_found
    assert_equal "live", pass.reload.status
    sign_in_as(users(:admin))
    patch revoke_browser_pass_path(pass)
    assert_equal "revoked", pass.reload.status
  end

  test "at most three live passes a user; older ones are revoked" do
    4.times { make_pass }
    assert_equal %w[revoked live live live], BrowserPass.order(:id).map(&:status)
  end

  test "rate limits: making passes, and the check" do
    sign_in_as(users(:user))
    10.times { post browser_passes_path }
    post browser_passes_path
    assert_redirected_to browser_passes_path
    assert_equal 10, BrowserPass.count
    sign_out
    60.times { check("A" * 43, ip: "203.0.113.9") }
    assert_equal 429, check("A" * 43, ip: "203.0.113.9")
    assert_equal 401, check("A" * 43, ip: "203.0.113.10"), "per address"
  end

  test "the pass does not reach the log" do
    token = make_pass
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActionController::Base.logger = ActiveSupport::TaggedLogging.logger(io)
    check(token)
    refute_includes io.string, token
    assert_includes io.string, "opened a connection"
  ensure
    Rails.logger = ActionController::Base.logger = old
  end

  test "admins see every pass under /admin" do
    make_pass(users(:user))
    sign_in_as(users(:admin))
    get admin_browser_passes_path
    assert_response :success
    assert_select "td", "user@example.com"
    sign_in_as(users(:user))
    get admin_browser_passes_path
    assert_redirected_to root_path
  end

  private

  def with_env(vars)
    old = vars.keys.to_h { [ _1, ENV[_1] ] }
    vars.each { ENV[_1] = _2 }
    yield
  ensure
    old.each { ENV[_1] = _2 }
  end
end
