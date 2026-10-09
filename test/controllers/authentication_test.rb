require "test_helper"

# Without signing in, every route answers with the sign-in page (HTML) or
# 401 (anything else); nothing about the network is in the answer.
class AuthenticationTest < ActionDispatch::IntegrationTest
  OPEN = %w[sessions#new sessions#create sessions#otp sessions#verify_otp rails/health#show].freeze

  def app_routes
    Rails.application.routes.routes.filter_map do |r|
      ctrl, action = r.defaults.values_at(:controller, :action)
      next unless ctrl && action && !ctrl.start_with?("rails/", "action_", "turbo/")
      verb = r.verb.to_s[/[A-Z]+/]
      next unless verb
      path = r.path.spec.to_s.sub("(.:format)", "").gsub(/:\w+/, "1")
      [ "#{ctrl}##{action}", verb.downcase.to_sym, path ]
    end.uniq
  end

  setup do
    GraphState.current.update!(snapshot: JSON.generate("nodes" => [ { "id" => "a_node:secret-node" } ], "edges" => []))
  end

  test "every route but signing in needs a signed-in user" do
    routes = app_routes
    assert routes.size >= 15, routes.inspect
    routes.each do |name, verb, path|
      next if OPEN.include?(name)
      send(verb, path)
      assert_includes [ 302, 401 ], response.status, "#{name} #{verb.upcase} #{path} answered #{response.status}"
      assert_redirected_to new_session_path if response.status == 302
      refute_includes response.body, "secret-node", name
      send(verb, path, as: :json) unless verb == :get
      get path, as: :json if verb == :get
      assert_equal 401, response.status, "#{name} as JSON"
    end
  end

  test "nothing is written without signing in" do
    assert_no_difference -> { BridgeRequest.count + Watch.count + CallPermission.count + StreamLease.count + Recording.count + Playback.count } do
      post bridge_requests_path, params: { kind: "call", path: "a/b/c", method_name: "x" }, as: :json
      post watches_path, params: { key: "demo/**" }, as: :json
      post lease_plots_path, params: { page: "page-aaaaaaaa", wanted: [ { target: "r_topic:0/cmd_vel" } ] }, as: :json
      post lease_logs_path, params: { page: "page-aaaaaaaa", wanted: [ { target: "*" } ] }, as: :json
      post call_permissions_path, params: { call_permission: { node: "*", app: "*", object: "*", method_name: "*" } }
      post recordings_path, params: { recording: { structure: "1" } }
      post upload_recordings_path, params: { file: fixture_file_upload("rosbag2_jazzy.mcap") }
      post playbacks_path, params: { recording_id: 1, speed: 1, confirm: "inject" }, as: :json
    end
  end
end
