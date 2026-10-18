require "test_helper"
require_relative "../test_helpers/room_test_helper"

# Invite links to make rooms (0.3.5, docs/rooms.md "Invite links"): the
# admin's side (make, list, revoke) and the invite link's page (enter, make a
# room, see and close its own rooms, and nothing else).
class RoomInvitesTest < ActionDispatch::IntegrationTest
  include RoomTestHelper

  APPS = "Othello=/app/test/othello.app.rb,Mahjong=/app/game/mahjong/mahjong.app.rb".freeze

  setup do
    RateLimits::STORE.clear
    setup_rooms(slots: 3)
    ENV["ASTERISM_ROOM_PAGE"] = "https://play.example.org/?zenoh={router}#room={room}&app={app}"
    ENV["ASTERISM_DOOR_STATUS_URL"] = "http://127.0.0.1:1/status"
    ENV["ASTERISM_ROOM_APPS"] = APPS
  end

  teardown do
    %w[ASTERISM_ROOM_PAGE ASTERISM_DOOR_STATUS_URL ASTERISM_ROOM_APPS ASTERISM_ROOM_MAX_HOURS].each { ENV.delete(_1) }
    teardown_rooms
    RateLimits::STORE.clear
  end

  # Makes an invite link as the admin; returns [invite, secret], signed out.
  def make_invite(name: "Friday club", days: "7", max_rooms: "1", apps: [ "/app/test/othello.app.rb" ], message: nil)
    sign_in_as(users(:admin))
    post admin_room_invites_path, params: { room_invite: { name: name, days: days, max_rooms: max_rooms, apps: apps,
                                                           message: message }.compact }
    assert_response :created
    link = css_select("#invite-link").text
    secret = link[/#invite=([A-Za-z0-9_-]+)\z/, 1]
    assert secret, link
    sign_out
    [ RoomInvite.last, secret ]
  end

  def enter(secret)
    post invite_enter_path, params: { token: secret }
  end

  def make_room(app: "/app/test/othello.app.rb", hours: nil, name: nil)
    post invite_rooms_path, params: { room: { app: app, hours: hours, name: name }.compact }
  end

  test "an admin makes an invite link: shown once, only its hash kept, listed on the rooms' page" do
    invite, secret = make_invite(max_rooms: "2", apps: [ "/app/test/othello.app.rb", "/app/game/mahjong/mahjong.app.rb" ])
    assert_operator secret.size, :>=, 43
    assert_equal Digest::SHA256.hexdigest(secret), invite.token_digest
    refute_includes RoomInvite.column_names, "token"
    refute(RoomInvite.pluck(*RoomInvite.column_names).flatten.any? { _1.to_s.include?(secret) }, "no secret in the table")
    assert_equal 2, invite.max_rooms
    assert_in_delta 7.days.from_now, invite.expires_at, 5
    assert_equal %w[/app/test/othello.app.rb /app/game/mahjong/mahjong.app.rb], invite.app_paths
    assert_equal users(:admin), invite.created_by
    sign_in_as(users(:admin))
    get admin_room_invite_path(invite)
    assert_response :success
    refute_includes response.body, secret, "shown once"
    get admin_rooms_path
    assert_select "#invites td a", text: "Friday club"
    assert_select "#invites input[type=checkbox][value='/app/game/mahjong/mahjong.app.rb']"
  end

  test "an invite link offers only apps of ASTERISM_ROOM_APPS, at least one" do
    sign_in_as(users(:admin))
    post admin_room_invites_path, params: { room_invite: { name: "x", apps: [ "/app/other.app.rb" ] } }
    assert_redirected_to admin_rooms_path(anchor: "invites")
    assert_match(/not in ASTERISM_ROOM_APPS/, flash[:alert])
    post admin_room_invites_path, params: { room_invite: { name: "x", apps: [] } }
    assert_match(/one app or more/, flash[:alert])
    post admin_room_invites_path, params: { room_invite: { name: "x", days: "91", apps: [ "/app/test/othello.app.rb" ] } }
    assert_match(/days must be/, flash[:alert])
    assert_equal 0, RoomInvite.count
  end

  test "not for someone who is not an admin" do
    sign_in_as(users(:user))
    post admin_room_invites_path, params: { room_invite: { name: "x", apps: [ "/app/test/othello.app.rb" ] } }
    assert_response :redirect
    assert_equal 0, RoomInvite.count
  end

  test "the link's page makes a room with the link once, lists it and closes it" do
    invite, secret = make_invite
    get invite_page_path
    assert_response :success
    assert_select "form[action='#{invite_enter_path}'] input[name=token]"
    enter(secret)
    assert_redirected_to invite_page_path
    get invite_page_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "select[name='room[app]'] option", count: 1
    assert_select "input[name='room[hours]'][value='3'][max='12']"
    make_room(name: "Othello night")
    assert_response :created
    room = Room.last
    assert_equal invite, room.room_invite
    assert_nil room.created_by
    assert_equal "Othello night", room.name
    assert_in_delta 3.hours.from_now, room.expires_at, 5, "3 hours unless they say"
    token = @signer.tokens.last
    assert_includes response.body, "#room=#{ERB::Util.url_encode(token)}&amp;app=%2Fapp%2Ftest%2Fothello.app.rb"
    assert_includes File.read(Relay::RoomFiles.path), room.uid
    get invite_page_path
    refute_includes response.body, ERB::Util.url_encode(token), "the room's link is shown once"
    assert_select "td", text: "Othello night"
    delete invite_room_path(room)
    assert_redirected_to invite_page_path
    assert_equal "closed", room.reload.status
    assert_equal "closed on the invite link's page", room.close_reason
    refute_includes File.read(Relay::RoomFiles.path).then { JSON.parse(_1)["slots"].to_s }, room.uid
  end

  test "the secret in a pasted link works too; a wrong one does not" do
    _, secret = make_invite
    enter("https://console.example.org/invite#invite=#{secret}")
    assert_redirected_to invite_page_path
    delete invite_leave_path
    enter("x" * 43)
    assert_response :not_found
    assert_match "not an invite link", response.body
    get invite_page_path
    assert_select "form[action='#{invite_enter_path}']"
  end

  test "a room lasts at most 12 hours, and opens only the link's apps" do
    _, secret = make_invite
    enter(secret)
    make_room(hours: "12")
    assert_response :created
    assert_in_delta 12.hours.from_now, Room.last.expires_at, 5
    Room.last.close!(nil)
    make_room(hours: "12.5")
    assert_response :unprocessable_content
    assert_match "at most 12 hours", response.body
    make_room(app: "/app/game/mahjong/mahjong.app.rb")
    assert_response :unprocessable_content
    assert_match "cannot open that app", response.body
    make_room(app: "/app/somewhere.app.rb")
    assert_response :unprocessable_content
    assert_equal 1, Room.count
    ENV["ASTERISM_ROOM_MAX_HOURS"] = "6"
    assert_equal 6, RoomInvite.max_hours, "never longer than the console's own longest"
    assert_equal 3, RoomInvite.default_hours
  end

  test "rooms open at once are limited per link, and by the slots of all rooms" do
    invite, secret = make_invite(max_rooms: "2")
    enter(secret)
    make_room
    make_room
    assert_equal 2, Room.count
    make_room
    assert_response :unprocessable_content
    assert_match "2 rooms open at once", response.body
    assert_equal 2, Room.count
    invite.update!(max_rooms: 3)
    sign_in_as(users(:admin))
    post admin_rooms_path, params: { room: { name: "Admin's", hours: "1" } }
    sign_out
    assert_equal 3, Room.open_now.count, "the three slots are taken"
    make_room
    assert_response :unprocessable_content
    assert_match "Every room is in use", response.body
    assert_equal 3, Room.open_now.count
  end

  test "a revoked or expired link is refused with its reason, also in a browser that opened it before" do
    invite, secret = make_invite
    enter(secret)
    invite.revoke!(users(:admin))
    get invite_page_path
    assert_response :forbidden
    assert_match "revoked", response.body
    enter(secret)
    assert_response :forbidden
    assert_match "revoked", response.body
    make_room
    assert_response :forbidden
    assert_equal 0, Room.count

    other, secret2 = make_invite(name: "Old")
    enter(secret2)
    other.update!(expires_at: 1.minute.ago)
    make_room
    assert_response :forbidden
    assert_match "expired", response.body
    enter(secret2)
    assert_response :forbidden
    assert_match "expired", response.body
    assert_equal 0, Room.count
  end

  test "revoking can close the link's open rooms too" do
    invite, secret = make_invite
    enter(secret)
    make_room
    room = Room.last
    sign_in_as(users(:admin))
    patch revoke_admin_room_invite_path(invite), params: { close_rooms: "1" }
    assert_redirected_to admin_room_invite_path(invite)
    assert_equal "revoked", invite.reload.status
    assert_equal users(:admin), invite.revoked_by
    assert_equal "closed", room.reload.status
    assert_equal "its invite link was revoked", room.close_reason
  end

  test "the page shows and closes only its own link's rooms" do
    _, secret_a = make_invite(name: "A")
    _, secret_b = make_invite(name: "B")
    sign_in_as(users(:admin))
    post admin_rooms_path, params: { room: { name: "Admin room", hours: "1" } }
    admin_room = Room.last
    sign_out
    enter(secret_b)
    make_room(name: "B room")
    b_room = Room.last
    delete invite_leave_path
    enter(secret_a)
    make_room(name: "A room")
    get invite_page_path
    assert_select "td", text: "A room"
    assert_select "td", text: "B room", count: 0
    assert_select "td", text: "Admin room", count: 0
    delete invite_room_path(b_room)
    assert_response :not_found
    delete invite_room_path(admin_room)
    assert_response :not_found
    assert b_room.reload.open?
    assert admin_room.reload.open?
  end

  test "the link's page opens no admin page and no other page of the console" do
    _, secret = make_invite
    enter(secret)
    get invite_page_path
    assert_select "nav", count: 0
    assert_select "a[href^='/admin']", count: 0
    get admin_rooms_path
    assert_redirected_to new_session_path
    get admin_room_invites_path
    assert_redirected_to new_session_path
    get root_path
    assert_redirected_to new_session_path
    post admin_rooms_path, params: { room: { name: "x", hours: "1" } }
    assert_redirected_to new_session_path
    assert_equal 0, Room.count
  end

  test "secrets that are no invite link's: refused for a while after #{InvitePagesController::BAD_LIMIT}" do
    _, secret = make_invite
    InvitePagesController::BAD_LIMIT.times do |i|
      enter(format("%043d", i))
      assert_response :not_found
    end
    enter(secret)
    assert_response :too_many_requests, "even the right one, from that address"
    assert_match "Too many tries", response.body
    get invite_page_path
    assert_select "select[name='room[app]']", count: 0
    RateLimits::STORE.clear
    enter(secret)
    assert_redirected_to invite_page_path
  end

  test "every try is limited too, good secrets as well" do
    _, secret = make_invite
    30.times do
      enter(secret)
      assert_redirected_to invite_page_path
    end
    enter(secret)
    assert_response :too_many_requests
  end

  test "the room's record says which invite link made it" do
    invite, secret = make_invite
    enter(secret)
    make_room(name: "Club room")
    sign_in_as(users(:admin))
    get admin_rooms_path
    assert_select "td a[href='#{admin_room_invite_path(invite)}']", text: "Friday club"
    get admin_room_path(Room.last)
    assert_match "through the invite link", response.body
    get admin_room_invite_path(invite)
    assert_select "td a", text: "Club room"
    assert_select "dd", text: "1"
  end

  test "an invite link's message: kept with its line breaks, shown above the form as plain text" do
    message = "How to play\r\n\r\n1. Choose the app.\r\n2. Make the room.\r\n<script>alert(1)</script> https://example.org/"
    invite, secret = make_invite(message: message)
    assert_equal "How to play\n\n1. Choose the app.\n2. Make the room.\n<script>alert(1)</script> https://example.org/",
                 invite.message
    enter(secret)
    get invite_page_path
    assert_response :success
    assert_select ".card h2 + .invite-message p", count: 2
    assert_select ".invite-message p", text: "How to play"
    assert_select ".invite-message p:nth-of-type(2) br", count: 2
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_select ".invite-message script", count: 0
    assert_select ".invite-message a", { count: 0 }, "no link made"
    assert_select ".invite-message + p", text: /Invite link/
    assert_select ".invite-message ~ form[action='#{invite_rooms_path}']"
  end

  test "an invite link without a message: its page as before" do
    _, secret = make_invite(message: " \r\n ")
    assert_nil RoomInvite.last.message
    enter(secret)
    get invite_page_path
    assert_response :success
    assert_select ".invite-message", count: 0
    assert_select ".card h2 + p", text: /Invite link/
  end

  test "a message has at most #{RoomInvite::MAX_MESSAGE} characters" do
    sign_in_as(users(:admin))
    post admin_room_invites_path, params: { room_invite: { name: "x", apps: [ "/app/test/othello.app.rb" ],
                                                           message: "あ" * (RoomInvite::MAX_MESSAGE + 1) } }
    assert_redirected_to admin_rooms_path(anchor: "invites")
    assert_match(/Message is too long/, flash[:alert])
    assert_equal 0, RoomInvite.count
    invite, = make_invite(message: "あ" * RoomInvite::MAX_MESSAGE)
    assert_equal RoomInvite::MAX_MESSAGE, invite.message.size
    sign_in_as(users(:admin))
    patch admin_room_invite_path(invite), params: { room_invite: { message: "x" * (RoomInvite::MAX_MESSAGE + 1) } }
    assert_response :unprocessable_content
    assert_match "Message is too long", response.body
    assert_equal "あ" * RoomInvite::MAX_MESSAGE, invite.reload.message
  end

  test "a new invite link starts with the message of the one made last" do
    sign_in_as(users(:admin))
    get admin_rooms_path
    assert_select "#invites textarea[name='room_invite[message]']", text: ""
    make_invite(name: "A", message: "First\nmessage")
    make_invite(name: "B", message: "Second <b>message</b>")
    sign_in_as(users(:admin))
    get admin_rooms_path
    assert_select "#invites textarea[name='room_invite[message]']", text: "Second <b>message</b>"
    assert_includes response.body, "Second &lt;b&gt;message&lt;/b&gt;"
    RoomInvite.last.revoke!(users(:admin))
    get admin_rooms_path
    assert_select "#invites textarea[name='room_invite[message]']", { text: "Second <b>message</b>" }, "revoked or not"
  end

  test "an admin changes an invite link's message on its page, the link's page shows the new one" do
    invite, secret = make_invite(message: "Old words")
    sign_in_as(users(:admin))
    get admin_room_invite_path(invite)
    assert_select "#message textarea[name='room_invite[message]']", text: "Old words"
    patch admin_room_invite_path(invite), params: { room_invite: { message: "New words\nsecond line" } }
    assert_redirected_to admin_room_invite_path(invite)
    assert_equal "New words\nsecond line", invite.reload.message
    sign_out
    enter(secret)
    get invite_page_path
    assert_select ".invite-message p", text: /New words/
    assert_select ".invite-message br", count: 1
    sign_in_as(users(:admin))
    patch admin_room_invite_path(invite), params: { room_invite: { message: "" } }
    assert_nil invite.reload.message
    sign_out
    get invite_page_path
    assert_select ".invite-message", count: 0
  end

  test "only an admin changes a message" do
    invite, = make_invite(message: "Words")
    patch admin_room_invite_path(invite), params: { room_invite: { message: "Other" } }
    assert_redirected_to new_session_path
    sign_in_as(users(:user))
    patch admin_room_invite_path(invite), params: { room_invite: { message: "Other" } }
    assert_response :redirect
    assert_equal "Words", invite.reload.message
  end
end
