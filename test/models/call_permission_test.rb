require "test_helper"

class CallPermissionTest < ActiveSupport::TestCase
  def allow(node, app, object, method)
    CallPermission.create!(node: node, app: app, object: object, method_name: method)
  end

  test "with no rows nothing is allowed" do
    refute CallPermission.allows?("fmruby-aaaaaa/demo/screen", "say")
    refute CallPermission.allows?("fmruby-aaaaaa/demo/screen")
  end

  test "patterns per part" do
    allow("fmruby-*", "demo", "screen", "say")
    allow("cruby", "demo", "*", "status")
    assert CallPermission.allows?("fmruby-aaaaaa/demo/screen", "say")
    assert CallPermission.allows?("fmruby-aaaaaa/demo/screen")          # its meta
    refute CallPermission.allows?("fmruby-aaaaaa/demo/screen", "clear")
    refute CallPermission.allows?("fmruby-aaaaaa/demo/info", "say")
    refute CallPermission.allows?("fmruby-aaaaaa/other/screen", "say")
    refute CallPermission.allows?("linux/demo/screen", "say")
    assert CallPermission.allows?("cruby/demo/info", "status")
    refute CallPermission.allows?("cruby/demo/info", "status2")
    refute CallPermission.allows?("cruby/demo", "status")              # not three parts
    # * stays within its part: it does not let a path through.
    refute CallPermission.allows?("cruby/demo/x/y", "status")
    assert_equal 1, CallPermission.for_path("cruby/demo/info").size
  end

  test "the * of a method and the characters of a pattern" do
    allow("*", "*", "*", "get_*")
    assert CallPermission.allows?("a/b/c", "get_status")
    refute CallPermission.allows?("a/b/c", "set_status")
    row = CallPermission.new(node: "a.b(", app: "*", object: "*", method_name: "x")
    refute row.valid?
    row = CallPermission.new(node: "*", app: "*", object: "*", method_name: "instance_eval(1)")
    refute row.valid?
    assert CallPermission.new(node: "*", app: "*", object: "*", method_name: "respond_to?").valid?
    # Dots are plain dots, not "any character".
    allow("a.b", "x", "y", "z")
    refute CallPermission.allows?("aXb/x/y", "z")
    assert CallPermission.allows?("a.b/x/y", "z")
  end
end
