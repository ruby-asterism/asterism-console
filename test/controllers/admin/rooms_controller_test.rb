require "test_helper"
require_relative "../../test_helpers/room_test_helper"

class Admin::RoomsControllerTest < ActionDispatch::IntegrationTest
  include RoomTestHelper

  setup do
    setup_rooms(slots: 1)
    ENV["ASTERISM_ROOM_PAGE"] = "https://play.example.org/?zenoh={router}#room={room}&app={app}"
    ENV["ASTERISM_DOOR_STATUS_URL"] = "http://127.0.0.1:1/status"
  end

  teardown do
    ENV.delete("ASTERISM_ROOM_PAGE")
    ENV.delete("ASTERISM_DOOR_STATUS_URL")
    teardown_rooms
  end

  test "an admin makes a room, sees its link once, makes another, closes it" do
    sign_in_as(users(:admin))
    get admin_rooms_path
    assert_response :success
    assert_match "01 free", response.body
    post admin_rooms_path, params: { room: { name: "Friday", app: "/app/test/othello.app.rb", hours: "2", max_connections: "16" } }
    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    room = Room.last
    token = @signer.tokens.last
    assert_includes response.body, "#room=#{ERB::Util.url_encode(token)}&amp;app=%2Fapp%2Ftest%2Fothello.app.rb"
    assert_includes File.read(Relay::RoomFiles.path), room.uid
    get admin_room_path(room)
    refute_includes response.body, token, "shown once"
    post link_admin_room_path(room)
    assert_response :success
    assert_includes response.body, ERB::Util.url_encode(@signer.tokens.last)
    assert_equal 2, room.reload.links_made
    post admin_rooms_path, params: { room: { name: "Second", hours: "1" } }
    assert_redirected_to admin_rooms_path
    assert_match(/every room slot is taken/, flash[:alert])
    delete admin_room_path(room)
    assert_redirected_to admin_rooms_path
    assert_equal "closed", room.reload.status
    data = JSON.parse(File.read(Relay::RoomFiles.path))
    assert_equal({}, data["slots"])
    assert_equal [ room.uid ], data["revoked"].map { _1["room"] }
    refute(Rails.logger.respond_to?(:string) && Rails.logger.string.include?(token))
  end

  test "not for someone who is not an admin" do
    sign_in_as(users(:user))
    get admin_rooms_path
    assert_response :redirect
    assert_equal 0, Room.count
  end
end
