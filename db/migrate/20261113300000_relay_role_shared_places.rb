# Asterism wire protocol 2's shared places (asterism docs/protocol.md 17):
# data with no owner at asterism/<node>/@shared/** (a node's place, written
# by its own applications) and asterism/@shared/** (the network's place).
# The chunk @shared starts with @, so no ** reaches it: a role needs lines
# of its own. The game host's spectate keys moved there
# (asterism/<host>/@shared/spectate/<table>/state, declared by the host's
# application games and by a room's application room<slot>), and the
# second connection "spectate" is gone. This brings the roles of a console
# made before to that, adding lines and removing only a spectator's old
# spectate lines, which nothing puts on any more:
#
#   - the example role "match" (seeded, docs/g1_5.md) reads the network's
#     place: asterism/@shared/** in read (members read it; writing it is
#     for the roles an admin makes);
#   - a read line asterism/** (viewer, docs/g1_5.md) gets the two places,
#     asterism/*/@shared/** and asterism/@shared/**, next to it;
#   - a read and write line <prefix>/spectate/** (games-host, docs/rooms.md)
#     gets its node's place <prefix>/@shared/** and the rooms' applications
#     <prefix>/room$* and <prefix>/room$*/** (their tokens and queryables;
#     their @profile, @status and @pubs come from the */@profile lines);
#   - a read line <prefix>/spectate/** (spectator, docs/rooms.md): its
#     spectate lines (read <prefix>/spectate, /spectate/**,
#     /spectate/@profile, /spectate/@pubs, ask /spectate/@profile) are
#     replaced by read <prefix>/@shared/spectate/** and what reads a
#     shared key's type from its senders (the host's games and rooms'
#     room<slot> applications): read <prefix>/games/@profile,
#     <prefix>/games/@pubs, <prefix>/room$*/@profile, <prefix>/room$*/@pubs
#     and ask <prefix>/games/@profile, <prefix>/room$*/@profile (the
#     replies reach it through its read lines).
#
# As the other role migrations, it applies to every role and running it
# again changes nothing; the setup of an update runs it before it writes
# the router's configuration and restarts the router.
class RelayRoleSharedPlaces < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  NODE_PLACES = "asterism/*/@shared/**".freeze
  GLOBAL_PLACE = "asterism/@shared/**".freeze
  SPECTATE = %r{\A(.+)/spectate/\*\*\z}
  # The prefix of a spectate line (<prefix>/spectate/**), not one on a
  # shared place already (the new <prefix>/@shared/spectate/**).
  def self.spectate_prefix(line)
    prefix = line[SPECTATE, 1]
    prefix unless prefix.nil? || prefix.end_with?("/@shared")
  end

  # The applications that declare the spectate keys: the permanent tables'
  # host and a room's host.
  SENDERS = %w[games room$*].freeze

  # The spectator's lines for a prefix (asterism/*): [read, ask].
  def self.spectator_lines(prefix)
    read = [ "#{prefix}/@shared/spectate/**" ]
    SENDERS.each { read.push("#{prefix}/#{_1}/@profile", "#{prefix}/#{_1}/@pubs") }
    [ read, SENDERS.map { "#{prefix}/#{_1}/@profile" } ]
  end

  # The spectator's old lines for a prefix: [read, ask].
  def self.old_spectator_lines(prefix)
    base = "#{prefix}/spectate"
    [ [ base, "#{base}/**", "#{base}/@profile", "#{base}/@pubs" ], [ "#{base}/@profile" ] ]
  end

  # { rw:, read:, ask: } (newline-separated templates) with the shared
  # places, and the lines added, removed or replaced, for the log.
  def self.with_shared_places(name, rw, read, ask)
    lines = ->(text) { text.to_s.lines.map(&:strip).reject(&:empty?) }
    rw_l, read_l, ask_l = lines.(rw), lines.(read), lines.(ask)
    notes = []
    add = lambda do |list, section, line|
      next if list.include?(line)
      list << line
      notes << "#{section} + #{line}"
    end
    add.(read_l, "read", GLOBAL_PLACE) if name == "match"
    if read_l.include?("asterism/**")
      add.(read_l, "read", NODE_PLACES)
      add.(read_l, "read", GLOBAL_PLACE)
    end
    rw_l.filter_map { spectate_prefix(_1) }.uniq.each do |prefix|
      add.(rw_l, "rw", "#{prefix}/@shared/**")
      add.(rw_l, "rw", "#{prefix}/room$*")
      add.(rw_l, "rw", "#{prefix}/room$*/**")
    end
    read_l.filter_map { spectate_prefix(_1) }.uniq.each do |prefix|
      old_read, old_ask = old_spectator_lines(prefix)
      (read_l & old_read).each { notes << "read - #{_1}" }
      (ask_l & old_ask).each { notes << "ask - #{_1}" }
      read_l -= old_read
      ask_l -= old_ask
      new_read, new_ask = spectator_lines(prefix)
      new_read.each { add.(read_l, "read", _1) }
      new_ask.each { add.(ask_l, "ask", _1) }
    end
    [ { rw: rw_l.uniq.join("\n"), read: read_l.uniq.join("\n"), ask: ask_l.uniq.join("\n") }, notes ]
  end

  def up
    Role.find_each do |role|
      t, notes = self.class.with_shared_places(role.name, role.rw_templates, role.read_templates, role.ask_templates)
      next if notes.empty?
      role.update_columns(rw_templates: t[:rw], read_templates: t[:read], ask_templates: t[:ask])
      say "relay role #{role.name} (shared places): #{notes.join('; ')}"
    end
  end

  def down
    # The lines stay; a spectator's old spectate lines come back only by
    # hand (an asterism-games before the shared places puts there).
  end
end
