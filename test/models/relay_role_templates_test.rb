require "test_helper"

# What a role's line may be: a key expression once ${node} is put in, with
# Zenoh's $* inside a chunk (the rooms' applications room$*, docs/rooms.md).
class RelayRoleTemplatesTest < ActiveSupport::TestCase
  def role(read) = RelayRole.new(name: "r", read_templates: read)

  test "key expressions, ${node} and $* inside a chunk" do
    [ "asterism/*/room$*/@profile", "asterism/${node}/room$*/**", "asterism/*/@shared/spectate/**", "asterism/@shared/**" ].each do |t|
      assert role(t).valid?, t
    end
  end

  test "other ${...}, a lone $ and characters outside key expressions" do
    [ "asterism/${other}/x", "asterism/a$b", "asterism/a b", "asterism/?" ].each do |t|
      refute role(t).valid?, t
    end
  end
end
