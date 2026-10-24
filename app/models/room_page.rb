# The link a room is shown with (G2, docs/rooms.md): a page that joins the
# network from a browser (the browser build of Family mruby, say),
# configured by a URL template like ASTERISM_BROWSER_PAGE's:
#
#   ASTERISM_ROOM_PAGE  the page's URL with placeholders, each filled in
#                       URL-encoded:
#                         {router}  ASTERISM_PASS_ROUTER (the wss:// door's locator;
#                                   the page goes to its /room path)
#                         {room}    the room's key; MUST be in the fragment
#                         {app}     what the page starts ("" for nothing)
#                       e.g. https://play.example.org/?zenoh={router}#room={room}&app={app}
#
# A fragment is never sent to the server that serves the page, so its log
# never sees the key. Not set: the key is shown alone.
module RoomPage
  PLACEHOLDERS = %w[router room app].freeze

  module_function

  def template(env = ENV)
    t = env["ASTERISM_ROOM_PAGE"].presence
    t if t && usable?(t)
  end

  def enabled?(env = ENV) = template(env).present?

  def usable?(t)
    uri_part, fragment = t.split("#", 2)
    t.match?(%r{\Ahttps?://[^/\s]+}) && fragment.to_s.include?("{room}") && !uri_part.include?("{room}")
  end

  # What a room's link may open, offered on the rooms' page: the apps of
  # ASTERISM_ROOM_APPS ("Othello=/app/test/othello.app.rb,Mahjong=/app/game/mahjong/mahjong.app.rb")
  # first, then the Studio apps (BrowserApp, the roles' browser apps before
  # 0.3.12). [[label, value]] (no blank one).
  def apps(env = ENV)
    (listed_apps(env) + BrowserPage.apps.reject { _1[1].blank? }).uniq { _1[1] }
  end

  # The apps of ASTERISM_ROOM_APPS alone ([[label, value]]): what an invite
  # link may offer (RoomInvite).
  def listed_apps(env = ENV)
    env["ASTERISM_ROOM_APPS"].to_s.split(",").filter_map do |item|
      label, path = item.split("=", 2).map(&:strip)
      path, label = label, nil if path.nil?
      next if path.blank? || !Room::APP.match?(path)
      [ label.presence ? "#{label} (#{path})" : path, path ]
    end.uniq { _1[1] }
  end

  def url(room:, app: "", router: PassLink.router, env: ENV)
    t = template(env) or return nil
    values = { "router" => router.to_s, "room" => room.to_s, "app" => app.to_s }
    t.gsub(/\{(#{PLACEHOLDERS.join('|')})\}/) { ERB::Util.url_encode(values.fetch(Regexp.last_match(1))) }
  end
end
