# A spectator sees the applications that put the spectate keys come and go
# (decision 37 of asterism protocol 2's design): their liveliness tokens,
# asterism/<node>/<app>/protocol/<n>, for the game host's applications
# games and room<slot> only. With them the command line finds those
# applications and asks their own profiles by name (the Read and Ask lines
# on games/@profile and room$*/@profile are there already), so a
# spectator's `asterism topic list` and `topic info` show the spectate
# keys with their types. Without them the router never sent a spectator a
# token, and both said nothing.
#
#   - a read line <prefix>/@shared/spectate/** (spectator, docs/rooms.md)
#     gets read <prefix>/games/protocol/* and <prefix>/room$*/protocol/*.
#
# It adds lines only, to every role that has such a line, and running it
# again changes nothing; the setup of an update runs it before it writes
# the router's configuration and restarts the router.
class RelayRoleSpectateTokens < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  SPECTATE = %r{\A(.+)/@shared/spectate/\*\*\z}
  # The applications that put the spectate keys.
  SENDERS = %w[games room$*].freeze

  # The token lines of a prefix (asterism/*): one per sender.
  def self.token_lines(prefix)
    SENDERS.map { "#{prefix}/#{_1}/protocol/*" }
  end

  # { read: } (newline-separated templates) with the senders' tokens, and
  # the lines added, for the log.
  def self.with_spectate_tokens(read)
    read_l = read.to_s.lines.map(&:strip).reject(&:empty?)
    notes = []
    read_l.filter_map { _1[SPECTATE, 1] }.uniq.each do |prefix|
      token_lines(prefix).each do |line|
        next if read_l.include?(line)
        read_l << line
        notes << "read + #{line}"
      end
    end
    [ { read: read_l.uniq.join("\n") }, notes ]
  end

  def up
    Role.find_each do |role|
      t, notes = self.class.with_spectate_tokens(role.read_templates)
      next if notes.empty?
      role.update_columns(read_templates: t[:read])
      say "relay role #{role.name} (spectate tokens): #{notes.join('; ')}"
    end
  end

  def down
    # The lines stay (an admin removes them by hand).
  end
end
