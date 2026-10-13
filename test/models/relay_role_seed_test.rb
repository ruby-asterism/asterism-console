require "test_helper"
require Rails.root.join("db/migrate/20261013100000_relay_roles").to_s

# A new console (db:prepare loads the schema and runs db/seeds.rb) and a
# migrated one (the migration) start with the same role "match".
class RelayRoleSeedTest < ActiveSupport::TestCase
  test "the seed makes the migration's role, once, and only when there is none" do
    RelayRole.delete_all
    load Rails.root.join("db/seeds.rb")
    seeded = RelayRole.sole
    migrated = RelayRole.new(RelayRoles.match_role("game"))
    assert_equal migrated.to_config, seeded.to_config
    load Rails.root.join("db/seeds.rb")
    assert_equal 1, RelayRole.count
  end
end
