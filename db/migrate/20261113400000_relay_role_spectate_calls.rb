# The game host's applications that put the spectate keys (games and a
# room's room<slot>) expose an object "spectate" whose state(table) gives
# the table's last spectate view, delayed as the key's values are: a reader
# that lost values or saw a new run (asterism docs/protocol.md 9.4) asks it
# again instead of waiting for the next put (the current value is an
# object's call, decision 31 of the protocol's design). A spectator may call
# that object and no other:
#
#   - a read line <prefix>/@shared/spectate/** (spectator, docs/rooms.md)
#     gets read and ask <prefix>/games/spectate/call/${node} and
#     <prefix>/room$*/spectate/call/${node} (a call is a query on
#     asterism/<node>/<app>/<object>/call/<caller>, the caller its own
#     name; the reply reaches it through the read line).
#
# It adds lines only, to every role that has such a line, and running it
# again changes nothing; the setup of an update runs it before it writes
# the router's configuration and restarts the router.
class RelayRoleSpectateCalls < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  SPECTATE = %r{\A(.+)/@shared/spectate/\*\*\z}
  # The applications that expose the spectate object.
  SENDERS = %w[games room$*].freeze

  # The call lines of a prefix (asterism/*): one per sender.
  def self.call_lines(prefix)
    SENDERS.map { "#{prefix}/#{_1}/spectate/call/${node}" }
  end

  # { rw:, read:, ask: } (newline-separated templates) with the spectate
  # calls, and the lines added, for the log.
  def self.with_spectate_calls(rw, read, ask)
    lines = ->(text) { text.to_s.lines.map(&:strip).reject(&:empty?) }
    rw_l, read_l, ask_l = lines.(rw), lines.(read), lines.(ask)
    notes = []
    add = lambda do |list, section, line|
      next if list.include?(line)
      list << line
      notes << "#{section} + #{line}"
    end
    read_l.filter_map { _1[SPECTATE, 1] }.uniq.each do |prefix|
      call_lines(prefix).each do |line|
        add.(read_l, "read", line)
        add.(ask_l, "ask", line)
      end
    end
    [ { rw: rw_l.uniq.join("\n"), read: read_l.uniq.join("\n"), ask: ask_l.uniq.join("\n") }, notes ]
  end

  def up
    Role.find_each do |role|
      t, notes = self.class.with_spectate_calls(role.rw_templates, role.read_templates, role.ask_templates)
      next if notes.empty?
      role.update_columns(rw_templates: t[:rw], read_templates: t[:read], ask_templates: t[:ask])
      say "relay role #{role.name} (spectate calls): #{notes.join('; ')}"
    end
  end

  def down
    # The lines stay (an admin removes them by hand).
  end
end
