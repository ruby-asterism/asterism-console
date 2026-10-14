require "test_helper"
require Rails.root.join("db/migrate/20261013100000_relay_roles").to_s
require Rails.root.join("db/migrate/20261014090000_relay_role_match_description").to_s
require Rails.root.join("db/migrate/20261014170000_relay_role_adv_keys").to_s

# A new console (db:prepare loads the schema and runs db/seeds.rb) and a
# migrated one (the migration) start with the same role "match".
class RelayRoleSeedTest < ActiveSupport::TestCase
  test "the seed makes the migration's role, once, and only when there is none" do
    RelayRole.delete_all
    load Rails.root.join("db/seeds.rb")
    seeded = RelayRole.sole
    # A migrated console gets the role from the G1.5 migration, then the
    # @adv lines from RelayRoleAdvKeys.
    migrated = RelayRole.new(RelayRoles.match_role("game"))
    adv = RelayRoleAdvKeys.with_adv(migrated.rw_templates, migrated.read_templates, migrated.ask_templates)
    migrated.assign_attributes(rw_templates: adv[:rw], read_templates: adv[:read], ask_templates: adv[:ask])
    assert_equal migrated.to_config["templates"].transform_values(&:sort), seeded.to_config["templates"].transform_values(&:sort)
    assert_equal migrated.to_config.except("templates"), seeded.to_config.except("templates")
    load Rails.root.join("db/seeds.rb")
    assert_equal 1, RelayRole.count
  end

  test "the seeded role says what it is for" do
    RelayRole.delete_all
    load Rails.root.join("db/seeds.rb")
    assert_match(/\AFor games on the app game: /, RelayRole.sole.description)
  end

  test "a match role without a description gets one, for its own app, only when blank" do
    role = relay_roles(:match)
    role.update!(description: "", rw_templates: "asterism/${node}\nasterism/${node}/othello/**")
    RelayRoleMatchDescription.new.up
    assert_equal RelayRoleMatchDescription.description("othello"), role.reload.description
    assert_match(/\AFor games on the app othello: /, role.description)
    role.update!(description: "Mine")
    RelayRoleMatchDescription.new.up
    load Rails.root.join("db/seeds.rb")
    assert_equal "Mine", role.reload.description, "a description an admin wrote stays"
    role.update!(description: nil)
    load Rails.root.join("db/seeds.rb")
    assert_match(/\AFor games on the app othello: /, role.reload.description, "the seed fills it too")
  end
end
