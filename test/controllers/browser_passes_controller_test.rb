require "test_helper"

# Passes for the browser build's wss:// (W4): made by a signed-in user,
# shown once, checked by the proxy (check), good for one connection, refused
# when used, expired or revoked.
class BrowserPassesControllerTest < ActionDispatch::IntegrationTest
  setup { RateLimits::STORE.clear }

  def make_pass(user = users(:user))
    sign_in_as(user)
    post browser_passes_path
    assert_response :created
    css_select("dd code.wrap").first.text
  end

  def check(token, ip: "198.51.100.7", page: nil)
    get check_browser_passes_path, headers: { "X-Asterism-Pass" => token, "X-Asterism-Page" => page,
                                              "X-Forwarded-For" => ip }.compact
    response.status
  end

  # The way nginx hands it over: the WebSocket URL's query, in a header.
  def check_uri(token, page, ip: "198.51.100.7")
    get check_browser_passes_path, headers: { "X-Original-URI" => "/?pass=#{token}&page=#{page}", "X-Forwarded-For" => ip }
    response.status
  end

  PAGE_A = "pageAAAAAAAAAAAAAAAAAAAA".freeze
  PAGE_B = "pageBBBBBBBBBBBBBBBBBBBB".freeze

  test "a pass is shown once, as a link with the router; only its digest is kept" do
    with_env("ASTERISM_PASS_ROUTER" => "ws/router.example.org:7443",
             "ASTERISM_STUDIO_URL" => "https://studio.example.org/index.html") do
      token = make_pass
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_select "a[href=?]", "https://studio.example.org/index.html?zenoh=ws%2Frouter.example.org%3A7443#zenoh_pass=#{token}"
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
    other = make_pass
    sign_out
    get check_browser_passes_path, headers: { "X-Original-URI" => "/?pass=#{token}", "X-Forwarded-For" => "198.51.100.7" }
    assert_response :no_content, "the pass from the WebSocket URL nginx hands over"
    pass = BrowserPass.find_by!(token_digest: BrowserPass.digest(token))
    assert_equal [ 1, "198.51.100.7" ], [ pass.reload.uses, pass.last_used_ip ]
    assert_equal 401, check(nil)
    assert_equal 401, check("nonsense")
    assert_equal 401, check("A" * 43)
    travel BrowserPass::TTL + 1.second do
      assert_equal 401, check(other)
      get check_browser_passes_path, headers: { "X-Original-URI" => "/?pass=#{other}", "X-Forwarded-For" => "198.51.100.8" }
      assert_response :unauthorized, "expired (from the URI nginx hands over)"
    end
    unused = BrowserPass.find_by!(token_digest: BrowserPass.digest(other))
    assert_equal [ 2, 0, nil ], [ unused.reload.refused, unused.uses, unused.used_at ]
    third = make_pass
    sign_out
    BrowserPass.find_by!(token_digest: BrowserPass.digest(third)).revoke!(users(:user))
    assert_equal 401, check(third)
  end

  test "a pass belongs to the page that used it first, while it is open" do
    token = make_pass
    sign_out
    assert_equal 204, check_uri(token, PAGE_A)
    pass = BrowserPass.sole.reload
    assert_equal "open", pass.status
    assert_in_delta BrowserPass::LIFETIME.from_now, pass.open_until, 5
    assert_equal pass.open_until.to_i.to_s, response.headers["X-Asterism-Until"], "the door closes it then"
    assert_equal 204, check_uri(token, PAGE_A), "the same page connects again (the router restarted)"
    assert_equal 204, check(token, page: PAGE_A, ip: "198.51.100.9"), "also from another address (a new line)"
    assert_equal 401, check_uri(token, PAGE_B), "another page"
    assert_equal 401, check(token), "a page that names no key"
    assert_equal 401, check(token, page: "short"), "not a key"
    assert_equal [ 3, 3 ], [ pass.reload.uses, pass.refused ]
    travel BrowserPass::LIFETIME + 1.second do
      assert_equal 401, check_uri(token, PAGE_A), "closed after its lifetime"
      assert_equal "closed", pass.reload.status
    end
    pass.revoke!(users(:user))
    assert_equal 401, check_uri(token, PAGE_A), "revoked: nothing connects again"
  end

  test "the page that comes first takes the pass; one connection when it names no key" do
    token = make_pass
    other = make_pass
    sign_out
    assert_equal 204, check_uri(token, PAGE_B)
    assert_equal 401, check_uri(token, PAGE_A), "too late"
    assert_equal 204, check(other)
    assert_equal 401, check(other), "no key: one connection, as before"
    assert_equal 401, check(other, page: PAGE_A), "and no page can take it later"
  end

  test "a pass opens one connection: the first 204 consumes it" do
    token = make_pass
    sign_out
    assert_equal 204, check(token, ip: "198.51.100.7")
    pass = BrowserPass.sole
    assert_equal "used", pass.reload.status
    assert pass.used_at
    assert_equal 401, check(token, ip: "198.51.100.7"), "the same pass again"
    get check_browser_passes_path, headers: { "X-Original-URI" => "/?pass=#{token}", "X-Forwarded-For" => "198.51.100.7" }
    assert_response :unauthorized, "also from the URI"
    assert_equal [ 1, 2 ], [ pass.reload.uses, pass.refused ]
    assert_not pass.live?
    assert_not_includes BrowserPass.live, pass
    sign_in_as(users(:user))
    get browser_passes_path
    assert_select "span.badge", "used"
  end

  test "two checks racing for one pass: only one wins" do
    token = make_pass
    pass = BrowserPass.sole
    copy = BrowserPass.find(pass.id)
    assert pass.consume!("198.51.100.7")
    assert_not copy.consume!("198.51.100.8"), "the second, holding a stale copy"
    assert_equal 1, pass.reload.uses
  end

  test "a used pass does not count among a user's live passes" do
    token = make_pass
    sign_out
    assert_equal 204, check(token)
    3.times { make_pass }
    assert_equal %w[used live live live], BrowserPass.order(:id).map(&:status)
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
    check(token, page: PAGE_A)
    check(token, page: PAGE_A)
    check(token, page: PAGE_B)
    refute_includes io.string, token
    refute_includes io.string, PAGE_A
    refute_includes io.string, PAGE_B
    refute_includes io.string, "user@example.com"
    assert_includes io.string, "opened a connection from"
    assert_includes io.string, "opened a connection again"
    assert_includes io.string, "refused from 198.51.100.7 (another page)"

  ensure
    Rails.logger = ActionController::Base.logger = old
  end

  test "admins see every pass under /admin" do
    make_pass(users(:user))
    sign_in_as(users(:admin))
    get admin_browser_passes_path
    assert_response :success
    assert_select "td", /user@example.com/
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
