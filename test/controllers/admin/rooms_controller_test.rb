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
    assert_select "td", text: "free"
    assert_select "td", text: "2 of 2"
    assert_match "2 of 2 good", response.body
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

  test "the apps a room opens, and the game host's tables" do
    ENV["ASTERISM_ROOM_APPS"] = "Othello=/app/test/othello.app.rb,Mahjong=/app/game/mahjong/mahjong.app.rb"
    status = { "version" => "0.3.0", "since" => Time.now.utc.iso8601, "max" => 3, "apps" => [ "/app/game/mahjong/mahjong.app.rb" ],
               "rooms_file" => { "ok" => true }, "rooms" => {}, "without_table" => [], "rss_kb" => 51200 }
    server = TCPServer.new("127.0.0.1", 0)
    ENV["ASTERISM_GAMES_STATUS_URL"] = "http://127.0.0.1:#{server.addr[1]}/status"
    th = Thread.new do
      loop do
        c = server.accept
        while (l = c.gets) && l != "\r\n"; end
        body = JSON.generate(status)
        c.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        c.close
      end
    end
    sign_in_as(users(:admin))
    get admin_rooms_path
    assert_select "select[name='room[app]'] option[value='/app/game/mahjong/mahjong.app.rb']", text: /Mahjong/
    assert_select "select[name='room[app]'] option[value='/app/test/othello.app.rb']", text: /Othello/
    assert_match "gets a table from the game host", response.body
    post admin_rooms_path, params: { room: { name: "Mahjong night", app: "/app/game/mahjong/mahjong.app.rb", hours: "2" } }
    room = Room.last
    assert_equal "/app/game/mahjong/mahjong.app.rb", room.app
    assert_equal "/app/game/mahjong/mahjong.app.rb", JSON.parse(File.read(Relay::RoomFiles.path)).dig("slots", room.slot, "app")
    get admin_rooms_path
    assert_match "waiting for the game host", response.body
    status["rooms"] = { room.slot => { "room" => room.uid, "state" => "up",
                                       "tables" => { "mahjong1" => { "st" => "play", "humans" => 3, "cpus" => 1, "members" => 5 } } } }
    get admin_room_path(room)
    assert_match "mahjong1: playing, 3 seated, 1 CPU, 5 at the table", response.body
    assert_no_match "Permanent tables", response.body
    status["permanent"] = { "node" => "games", "state" => "up", "table_names" => %w[mahjong1 mahjong2],
                            "tables" => { "mahjong1" => { "st" => "wait", "humans" => 1, "cpus" => 0, "members" => 2 },
                                          "mahjong2" => { "st" => "play", "humans" => 2, "cpus" => 2, "members" => 2, "away" => 1 } } }
    get admin_rooms_path
    assert_match "Permanent tables of the node <code>games</code>", response.body
    assert_match "mahjong1: in its lobby, 1 seated, 0 CPU, 2 at the table", response.body
    assert_match "mahjong2: playing, 2 seated, 2 CPU, 2 at the table, 1 away", response.body
    status["permanent"] = { "node" => nil, "state" => "no certificate", "table_names" => %w[mahjong1 mahjong2], "tables" => {} }
    get admin_rooms_path
    assert_match "waiting for its certificate", response.body
    assert_match "mahjong2: -", response.body
    status.delete("permanent")
    delete admin_room_path(room)
    post admin_rooms_path, params: { room: { name: "Other", app: "", app_other: "/app/test/other.app.rb", hours: "1" } }
    assert_equal "/app/test/other.app.rb", Room.last.app
    ENV["ASTERISM_GAMES_STATUS_URL"] = "http://127.0.0.1:1/status"
    get admin_rooms_path
    assert_match "The game host does not answer", response.body
  ensure
    th&.kill
    server&.close
    ENV.delete("ASTERISM_ROOM_APPS")
    ENV.delete("ASTERISM_GAMES_STATUS_URL")
  end
end
