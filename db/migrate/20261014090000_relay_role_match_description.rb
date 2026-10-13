# The example role "match" with no description (an admin emptied it, or an
# older console left it blank) gets the one a new console seeds, for the
# app its templates name. Only when blank; running it again changes nothing.
class RelayRoleMatchDescription < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "relay_roles"
  end

  # The app of the match role: the part after asterism/${node}/ in its
  # read-and-write templates ("game" when none says).
  def self.app_of(rw_templates)
    rw_templates.to_s.lines.map(&:strip).filter_map { _1[%r{\Aasterism/\$\{node\}/([^/@]+)/\*\*\z}, 1] }.first || "game"
  end

  def self.description(app)
    "For games on the app #{app}: reads and writes its own #{app} keys and profile, reads every node's, " \
      "calls others' #{app} objects in its own name."
  end

  def up
    role = Role.find_by(name: "match")
    return unless role && role.description.blank?
    role.update_columns(description: self.class.description(self.class.app_of(role.rw_templates)))
  end

  def down
    # Nothing to undo: the description stays.
  end
end
