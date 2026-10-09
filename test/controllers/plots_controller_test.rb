require "test_helper"

class PlotsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:user)) }

  test "the page lists the ROS 2 topics and takes ?topic=" do
    GraphState.current.update!(snapshot: JSON.generate("nodes" => [
      { "id" => "r_topic:0/cmd_vel", "kind" => "r_topic", "data" => { "name" => "/cmd_vel", "type" => "geometry_msgs/msg/Twist", "domain" => "0" } }
    ], "edges" => []))
    get plots_path(topic: "r_topic:0/cmd_vel")
    assert_response :success
    assert_includes response.body, "geometry_msgs/msg/Twist"
    assert_includes response.body, 'data-plots-topic-value="r_topic:0/cmd_vel"'
  end

  test "lease, renew with other fields, release" do
    post lease_plots_path, params: { page: "page-aaaaaaaa", wanted: [ { target: "r_topic:0/cmd_vel", fields: [ "linear.x" ] } ] }, as: :json
    assert_response :success
    assert_equal [ "linear.x" ], response.parsed_body["leases"][0]["fields"]
    post lease_plots_path, params: { page: "page-aaaaaaaa", wanted: [ { target: "r_topic:0/cmd_vel", fields: [ "angular.z" ] } ] }, as: :json
    assert_equal({ "r_topic:0/cmd_vel" => [ "angular.z" ] }, StreamLease.wanted("plot"))
    assert_equal users(:user), StreamLease.last.user
    post release_plots_path, params: { page: "page-aaaaaaaa" }
    assert_response :no_content
    assert_equal 0, StreamLease.count
  end

  test "a bad target or path is refused" do
    post lease_plots_path, params: { page: "page-aaaaaaaa", wanted: [ { target: "**", fields: [] } ] }, as: :json
    assert_response :unprocessable_content
    assert_equal 0, StreamLease.count
  end
end
