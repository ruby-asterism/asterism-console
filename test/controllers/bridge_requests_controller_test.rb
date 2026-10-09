require "test_helper"

class BridgeRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:user))
    CallPermission.create!(node: "*", app: "*", object: "*", method_name: "*") if name.start_with?("test_allowed")
  end

  test "allowed: a call is queued for the bridge, with who asked" do
    post bridge_requests_path, params: { kind: "call", path: "fmruby-aaaaaa/demo/screen", method_name: "say",
                                         args: '["hi"]', timeout_s: 3 }, as: :json
    assert_response :created
    req = BridgeRequest.find(response.parsed_body["id"])
    assert_equal "pending", req.status
    assert_equal [ "hi" ], req.args_value
    assert_equal({}, req.kwargs_value)
    assert_equal 3.0, req.timeout_s
    assert_equal users(:user), req.user

    get bridge_request_path(req), as: :json
    assert_equal "pending", response.parsed_body["status"]
    assert_equal "user@example.com", response.parsed_body["user"]
  end

  test "allowed: arguments may come as JSON values" do
    post bridge_requests_path, params: { kind: "call", path: "a/b/c", method_name: "echo", args: [ 1, "x" ],
                                         kwargs: { tag: "t" } }, as: :json
    assert_response :created
    assert_equal [ 1, "x" ], response.parsed_body["args"]
    assert_equal({ "tag" => "t" }, response.parsed_body["kwargs"])
  end

  test "allowed: a meta needs only the path" do
    post bridge_requests_path, params: { kind: "meta", path: "fmruby-aaaaaa/demo/info" }, as: :json
    assert_response :created
  end

  test "not allowed: refused, kept as denied, never pending" do
    post bridge_requests_path, params: { kind: "call", path: "fmruby-aaaaaa/demo/screen", method_name: "say",
                                         args: '["hi"]' }, as: :json
    assert_response :forbidden
    body = response.parsed_body
    assert_equal "denied", body["status"]
    assert_equal "NotPermitted", body["error_class"]
    req = BridgeRequest.find(body["id"])
    assert_equal [ "denied", users(:user) ], [ req.status, req.user ]
    assert_equal 0, BridgeRequest.pending.count

    post bridge_requests_path, params: { kind: "meta", path: "fmruby-aaaaaa/demo/screen" }, as: :json
    assert_response :forbidden
  end

  test "only the allowed method of an object" do
    CallPermission.create!(node: "fmruby-*", app: "demo", object: "screen", method_name: "say")
    post bridge_requests_path, params: { kind: "call", path: "fmruby-aaaaaa/demo/screen", method_name: "say" }, as: :json
    assert_response :created
    post bridge_requests_path, params: { kind: "meta", path: "fmruby-aaaaaa/demo/screen" }, as: :json
    assert_response :created
    post bridge_requests_path, params: { kind: "call", path: "fmruby-aaaaaa/demo/screen", method_name: "clear" }, as: :json
    assert_response :forbidden
    post bridge_requests_path, params: { kind: "call", path: "fmruby-aaaaaa/demo/info", method_name: "say" }, as: :json
    assert_response :forbidden
    assert_equal %w[pending pending denied denied], BridgeRequest.order(:id).pluck(:status)
  end

  test "allowed: what is not sent at all" do
    [
      { kind: "call", path: "fmruby-aaaaaa/demo/*", method_name: "say" },   # a wildcard
      { kind: "call", path: "fmruby-aaaaaa/demo", method_name: "say" },     # not three parts
      { kind: "call", path: "@/x/y", method_name: "say" },                  # the admin space
      { kind: "call", path: "a/b/c", method_name: "instance_eval(1)" },     # not a method name
      { kind: "call", path: "a/b/c", method_name: "say", args: "{\"a\":1}" }, # not an array
      { kind: "call", path: "a/b/c", method_name: "say", args: "[1," },     # not JSON
      { kind: "call", path: "a/b/c", method_name: "say", timeout_s: 120 },  # too long
      { kind: "eval", path: "a/b/c" }
    ].each do |p|
      assert_no_difference("BridgeRequest.count", p.inspect) do
        post bridge_requests_path, params: p, as: :json
      end
      assert_response :unprocessable_content
      assert response.parsed_body["errors"].any?
    end
  end
end
