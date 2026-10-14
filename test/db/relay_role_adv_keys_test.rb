require "test_helper"
require Rails.root.join("db/migrate/20261014170000_relay_role_adv_keys").to_s

class RelayRoleAdvKeysTest < ActiveSupport::TestCase
  test "adds the @adv lines for each app the role reads and writes, once" do
    t = RelayRoleAdvKeys.with_adv("asterism/${node}\nasterism/${node}/game/**\nasterism/${node}/@profile",
                                  "asterism/*\nasterism/*/game/**", "asterism/*/game/*/call/${node}")
    assert_includes t[:rw].lines.map(&:strip), "asterism/${node}/game/**/@adv/**"
    assert_includes t[:read].lines.map(&:strip), "asterism/*/game/**/@adv/**"
    assert_includes t[:ask].lines.map(&:strip), "asterism/*/game/**/@adv/**"
    again = RelayRoleAdvKeys.with_adv(t[:rw], t[:read], t[:ask])
    assert_equal t, again
  end

  test "a role with no app keys is left as it is" do
    t = RelayRoleAdvKeys.with_adv("asterism/${node}", "asterism/*", "")
    assert_equal({ rw: "asterism/${node}", read: "asterism/*", ask: "" }, t)
  end
end
