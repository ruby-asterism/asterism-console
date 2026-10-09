require "test_helper"

# Playback to the network injects traffic: admins only, confirmed, one at
# a time, and every one is a row of the audit log.
class PlaybacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    FileUtils.mkdir_p(Recording.dir)
    @rec = Recording.new(user: users(:user), name: "drive", status: "done")
    @rec.selection_value = { "structure" => true }
    @rec.save!
    FileUtils.cp(file_fixture("rosbag2_jazzy.mcap"), @rec.path)
  end

  teardown { Recording.find_each(&:destroy) }

  test "a user who is not an admin cannot play to the network" do
    sign_in_as(users(:user))
    assert_no_difference -> { Playback.count } do
      post playbacks_path, params: { recording_id: @rec.id, speed: 1, confirm: "inject" }, as: :json
    end
    assert_response :forbidden
  end

  test "an admin, with confirm=inject: a pending row for the bridge, logged on the call log page" do
    sign_in_as(users(:admin))
    assert_no_difference -> { Playback.count } do
      post playbacks_path, params: { recording_id: @rec.id, speed: 1 }, as: :json
    end
    assert_response :unprocessable_content
    assert_match(/confirm=inject/, response.parsed_body["errors"].join)
    post playbacks_path, params: { recording_id: @rec.id, speed: 4, confirm: "inject", start_ns: "1791533800737687083" }, as: :json
    assert_response :created
    pb = Playback.last
    assert_equal [ "pending", 4.0, users(:admin), "drive", 1_791_533_800_737_687_083 ],
                 [ pb.status, pb.speed, pb.user, pb.recording_name, pb.start_ns ]
    assert_no_difference -> { Playback.count } do
      post playbacks_path, params: { recording_id: @rec.id, speed: 1, confirm: "inject" }, as: :json
    end
    assert_match(/another playback is running/, response.parsed_body["errors"].join)
    get calls_path
    assert_includes response.body, "Playbacks to the network"
    assert_includes response.body, "drive"
    post stop_playback_path(pb), as: :json
    assert_equal "stopped", pb.reload.status
  end

  test "only speeds 0.25, 1 and 4; only a finished recording" do
    sign_in_as(users(:admin))
    post playbacks_path, params: { recording_id: @rec.id, speed: 2, confirm: "inject" }, as: :json
    assert_response :unprocessable_content
    @rec.update!(status: "recording")
    post playbacks_path, params: { recording_id: @rec.id, speed: 1, confirm: "inject" }, as: :json
    assert_match(/not a finished recording/, response.parsed_body["errors"].join)
  end

  test "stopping is for admins too" do
    pb = Playback.create!(user: users(:admin), recording: @rec, speed: 1.0)
    sign_in_as(users(:user))
    post stop_playback_path(pb), as: :json
    assert_response :forbidden
    assert_equal "pending", pb.reload.status
  end
end
