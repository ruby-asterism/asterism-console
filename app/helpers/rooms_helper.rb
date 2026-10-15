module RoomsHelper
  # The tables a game host serves in an open room (Relay::GamesStatus), for
  # the rooms' list: "-" for a room it does not serve, "?" when it does not
  # answer.
  def room_tables_text(room, games, games_apps)
    return "-" unless room.open?
    return "?" unless games
    return "-" unless games_apps.include?(room.app.to_s)
    r = games.dig("rooms", room.slot)
    return "waiting for the game host" unless r && r["room"] == room.uid
    lines = Relay::GamesStatus.tables_text(r)
    lines.empty? ? "starting" : safe_join(lines, tag.br)
  end
end
