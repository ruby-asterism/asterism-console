require "test_helper"

class CallsControllerTest < ActionDispatch::IntegrationTest
  test "the log: who, when, what and the answer, refusals included" do
    BridgeRequest.create!(kind: "call", path: "cruby/demo/info", method_name: "status", user: users(:admin),
                          status: "ok", result: '{"up_ms":5}', took_ms: 3.2)
    BridgeRequest.new(kind: "call", path: "cruby/demo/info", method_name: "boom", user: users(:user)).deny!
    BridgeRequest.create!(kind: "meta", path: "cruby/demo/info", user: users(:user), status: "ok")
    sign_in_as(users(:user))

    get calls_path
    assert_response :success
    assert_select "tbody tr", 2
    assert_select "tr.status-denied td", /user@example.com/
    assert_select "tr.status-ok td", /admin@example.com/
    assert_select "tr.status-ok code", /up_ms/

    get calls_path(all: 1)
    assert_select "tbody tr", 3

    get calls_path, as: :json
    assert_equal %w[denied ok], response.parsed_body.map { _1["status"] }
    assert_equal "boom", response.parsed_body[0]["method"]
  end
end
