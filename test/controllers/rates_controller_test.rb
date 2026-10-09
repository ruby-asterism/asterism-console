require "test_helper"

class RatesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:user)) }

  test "a page asks for rates: all topics, or one" do
    post rates_path, params: { topic: "*" }, as: :json
    assert_response :created
    post rates_path, params: { topic: "r_topic:0/chatter" }, as: :json
    assert_response :created
    assert_equal [ "*", "r_topic:0/chatter" ], RateLease.wanted
    assert_operator Time.zone.parse(response.parsed_body["expires_at"]), :>, 20.seconds.from_now
  end

  test "anything else is refused" do
    post rates_path, params: { topic: "**" }, as: :json
    assert_response :unprocessable_content
    assert_equal 0, RateLease.count
  end
end
