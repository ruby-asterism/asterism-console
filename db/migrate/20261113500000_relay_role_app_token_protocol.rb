# Asterism wire protocol 2 (decision 35 of its design) tells the protocol
# an application speaks on its liveliness token:
# asterism/<node>/<app>/protocol/<n>, one key longer than protocol 1's
# asterism/<node>/<app> (asterism docs/protocol.md 6.1). A line that names
# an application's key exactly (no /** after it) reached protocol 1's token
# and no longer reaches the new one: the games-host role's read line
# asterism/*/game (docs/rooms.md), with which the host sees the players'
# applications come and go. This adds, next to each such line in "Read and
# write" and "Read", the token's line <line>/protocol/*:
#
#   - a line of three chunks under asterism/ (asterism/<node>/<app>, the
#     node and app may be ${node}, * or have $*), none of them starting with
#     @ (asterism/<node>/@profile is a node's profile, not an application);
#   - not when the same section has <line>/** (which reaches the token
#     already: asterism/${node}/room$* next to asterism/${node}/room$*/**).
#
# Lines with ** (asterism/*/game/**, asterism/**) reach the new token as
# they are. It adds lines only, and running it again changes nothing; the
# setup of an update runs it before it writes the router's configuration
# and restarts the router.
class RelayRoleAppTokenProtocol < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  # The line an application line gets, or nil when it is not one.
  def self.token_line(line, section)
    parts = line.split("/")
    return nil unless parts.size == 3 && parts[0] == "asterism"
    return nil if parts.any? { _1.empty? || _1.start_with?("@") || _1 == "**" }
    return nil if section.include?("#{line}/**")
    "#{line}/protocol/*"
  end

  # { rw:, read: } (newline-separated templates) with the token lines, and
  # the lines added, for the log.
  def self.with_token_lines(rw, read)
    lines = ->(text) { text.to_s.lines.map(&:strip).reject(&:empty?) }
    out = {}
    notes = []
    { rw: rw, read: read }.each do |name, text|
      list = lines.(text)
      list.dup.each do |line|
        add = token_line(line, list)
        next if add.nil? || list.include?(add)
        list.insert(list.index(line) + 1, add)
        notes << "#{name} + #{add}"
      end
      out[name] = list.uniq.join("\n")
    end
    [ out, notes ]
  end

  def up
    Role.find_each do |role|
      t, notes = self.class.with_token_lines(role.rw_templates, role.read_templates)
      next if notes.empty?
      role.update_columns(rw_templates: t[:rw], read_templates: t[:read])
      say "relay role #{role.name} (application tokens with the protocol): #{notes.join('; ')}"
    end
  end

  def down
    # The lines stay (an admin removes them by hand).
  end
end
