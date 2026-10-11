require "test_helper"

class MachineNameTest < ActiveSupport::TestCase
  test "a name with the node names it was given for, sorted and once each" do
    row = MachineName.new(name: "  mujoco ")
    row.member_list = [ "/b", "/a", "/b", " " ]
    assert row.save
    assert_equal({ "id" => row.id, "name" => "mujoco", "members" => %w[/a /b] }, row.to_graph)
    assert_equal [ row.to_graph ], MachineName.for_graph
  end

  test "needs a name and node names" do
    row = MachineName.new(name: "")
    row.member_list = []
    refute row.valid?
    assert row.errors[:name].any?
    assert row.errors[:members].any?
    row = MachineName.new(name: "x" * 65, members: "not json")
    refute row.valid?
  end
end
