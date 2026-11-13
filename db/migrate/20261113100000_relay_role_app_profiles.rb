# Asterism wire protocol 2: an application answers its own profile at
# asterism/<node>/<app>/@profile (a queryable, where protocol 1 answered
# @status) and puts its status and its topics' declarations on .../@status
# and .../@pubs. A ** never matches a chunk that starts with @, so a role
# needs lines of its own for them. This brings the roles of a console made
# before it to protocol 2, adding lines and never removing one, except the
# ask line of the protocol 1 status query, which nobody answers any more:
#
#   - the example role "match" (seeded, docs/g1_5.md) writes its nodes'
#     applications' profiles: asterism/${node}/*/@profile, @status and @pubs
#     in read and write (the queryable, its replies and the puts);
#   - a read and write line <prefix>/*/@status (games-host, docs/rooms.md)
#     gets <prefix>/*/@profile and <prefix>/*/@pubs next to it;
#   - a read line <prefix>/*/@status (viewer, docs/g1_5.md) gets
#     <prefix>/*/@pubs next to it;
#   - an ask line <prefix>/*/@status becomes <prefix>/*/@profile, and the
#     read lines get <prefix>/*/@profile too (the replies reach the asker
#     through its read lines).
#
# The console cannot tell an admin's edits from the example, so these rules
# apply to every role; each only adds what the role's protocol 1 lines
# meant. Running it again changes nothing. The setup of an update runs the
# migrations before it writes the router's configuration and restarts the
# router, so the router takes the new lines in the same update.
class RelayRoleAppProfiles < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  STATUS_RE = %r{\A(.+)/\*/@status\z}
  # What the example role "match" gets.
  MATCH_RW = %w[asterism/${node}/*/@profile asterism/${node}/*/@status asterism/${node}/*/@pubs].freeze

  # { rw:, read:, ask: } (newline-separated templates) brought to protocol 2,
  # and the lines added or replaced, for the log.
  def self.with_app_profiles(name, rw, read, ask)
    lines = ->(text) { text.to_s.lines.map(&:strip).reject(&:empty?) }
    rw_l, read_l, ask_l = lines.(rw), lines.(read), lines.(ask)
    notes = []
    add = lambda do |list, section, line|
      next if list.include?(line)
      list << line
      notes << "#{section} + #{line}"
    end
    MATCH_RW.each { add.(rw_l, "rw", _1) } if name == "match"
    rw_l.filter_map { _1[STATUS_RE, 1] }.uniq.each do |prefix|
      add.(rw_l, "rw", "#{prefix}/*/@profile")
      add.(rw_l, "rw", "#{prefix}/*/@pubs")
    end
    read_l.filter_map { _1[STATUS_RE, 1] }.uniq.each { add.(read_l, "read", "#{_1}/*/@pubs") }
    ask_l = ask_l.map do |line|
      prefix = line[STATUS_RE, 1] or next line
      notes << "ask #{line} -> #{prefix}/*/@profile"
      add.(read_l, "read", "#{prefix}/*/@profile")
      "#{prefix}/*/@profile"
    end
    [ { rw: rw_l.uniq.join("\n"), read: read_l.uniq.join("\n"), ask: ask_l.uniq.join("\n") }, notes ]
  end

  def up
    Role.find_each do |role|
      t, notes = self.class.with_app_profiles(role.name, role.rw_templates, role.read_templates, role.ask_templates)
      next if notes.empty?
      role.update_columns(rw_templates: t[:rw], read_templates: t[:read], ask_templates: t[:ask])
      say "relay role #{role.name} (protocol 2): #{notes.join('; ')}"
    end
  end

  def down
    # The lines stay: a protocol 1 console makes no use of them, and the
    # status ask line comes back only by hand (a protocol 1 node answers it).
  end
end
