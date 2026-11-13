# Asterism wire protocol 2: a game host's "spectate" is an application of
# its own (a second connection beside "game"), with its own profile at
# asterism/<host>/spectate/@profile and its topics' declarations on
# .../@pubs. A ** never matches a chunk that starts with @, so a role that
# reads the spectate values (the example role "spectator", docs/rooms.md:
# Read asterism/*/spectate/**) does not reach them. This lets such a role
# read that application's profile and topics too (what `asterism topic
# list` asks), adding lines and never removing one:
#
#   - a read line <base>/** whose last chunk before ** is the spectate
#     application (SPECTATE_READ) gets <base>/@profile and <base>/@pubs in
#     read (the reply and the puts reach it through read) and
#     <base>/@profile in ask (the query).
#
# Keyed on the role's own read line, so the lines follow its prefix. As
# RelayRoleAppProfiles, it applies to every role and running it again
# changes nothing; the setup of an update runs it before it writes the
# router's configuration and restarts the router.
class RelayRoleSpectateProfiles < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  # A read line on the spectate values: its base (<prefix>/spectate).
  SPECTATE_READ = %r{\A(.+/spectate)/\*\*\z}

  # { read:, ask: } (newline-separated templates) with the spectate
  # application's profile and topics, and the lines added, for the log.
  def self.with_spectate_profiles(read, ask)
    lines = ->(text) { text.to_s.lines.map(&:strip).reject(&:empty?) }
    read_l, ask_l = lines.(read), lines.(ask)
    notes = []
    add = lambda do |list, section, line|
      next if list.include?(line)
      list << line
      notes << "#{section} + #{line}"
    end
    read_l.filter_map { _1[SPECTATE_READ, 1] }.uniq.each do |base|
      add.(read_l, "read", "#{base}/@profile")
      add.(read_l, "read", "#{base}/@pubs")
      add.(ask_l, "ask", "#{base}/@profile")
    end
    [ { read: read_l.join("\n"), ask: ask_l.join("\n") }, notes ]
  end

  def up
    Role.find_each do |role|
      t, notes = self.class.with_spectate_profiles(role.read_templates, role.ask_templates)
      next if notes.empty?
      role.update_columns(read_templates: t[:read], ask_templates: t[:ask])
      say "relay role #{role.name} (spectate's profile): #{notes.join('; ')}"
    end
  end

  def down
    # The lines stay: they let a spectator read what the host tells anyway.
  end
end
