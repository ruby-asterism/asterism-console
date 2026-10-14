# `**` in a zenohd ACL does not reach keys with an @adv chunk (advanced
# pub/sub's history and its liveliness), so a role that lets an app's keys
# through drops that app's history (found with the rooms, G2 step 2). For
# every app a role reads and writes (asterism/${node}/<app>/**), add the
# @adv lines next to the plain ones: read and write its own, read and ask
# every node's. Lines already there are kept; running it again changes
# nothing.
class RelayRoleAdvKeys < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  APP_RE = %r{\Aasterism/\$\{node\}/([^/@*]+)/\*\*\z}

  # { rw:, read:, ask: } with the @adv lines added for each app of rw.
  def self.with_adv(rw, read, ask)
    lines = ->(text) { text.to_s.lines.map(&:strip).reject(&:empty?) }
    rw_l, read_l, ask_l = lines.(rw), lines.(read), lines.(ask)
    rw_l.filter_map { _1[APP_RE, 1] }.uniq.each do |app|
      rw_l << "asterism/${node}/#{app}/**/@adv/**"
      read_l << "asterism/*/#{app}/**/@adv/**"
      ask_l << "asterism/*/#{app}/**/@adv/**"
    end
    { rw: rw_l.uniq.join("\n"), read: read_l.uniq.join("\n"), ask: ask_l.uniq.join("\n") }
  end

  def up
    Role.find_each do |role|
      t = self.class.with_adv(role.rw_templates, role.read_templates, role.ask_templates)
      next if t[:rw] == role.rw_templates.to_s && t[:read] == role.read_templates.to_s && t[:ask] == role.ask_templates.to_s
      role.update_columns(rw_templates: t[:rw], read_templates: t[:read], ask_templates: t[:ask])
    end
  end

  def down
    # The added lines stay: they only let through what the plain lines meant to.
  end
end
