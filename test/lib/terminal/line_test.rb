require "test_helper"

# How the Terminal reads a command line before it reaches the bridge: the
# asterism command line's commands only, reading for everyone, calls by the
# call permissions, no other connection, no shell.
class Terminal::LineTest < ActiveSupport::TestCase
  def check(text, rows: [])
    Terminal::Line.check(text, permissions: rows)
  end

  def allow(node, app, object, method)
    CallPermission.new(node: node, app: app, object: object, method_name: method)
  end

  test "the commands that read, with or without asterism before them" do
    [ "node list", "asterism node list", "tree --methods", "object info games/games/othello1",
      "status get games/games", "status echo games/games --once", "watch --duration 3", "object find join",
      "app info games/games", "ping games", "ping games/games/othello1 --count 2", "nodes", "objects 'g/*/x'",
      "help", "help node", "--help", "version", "node", "object get a/b/c state --timeout 30" ].each do |text|
      l = check(text)
      assert l.ok?, "#{text}: #{l.reason}"
      assert_equal "read", l.effect, text
    end
    assert_equal [ "node list", %w[node list] ], check("asterism node list").then { [ _1.command, _1.words ] }
    assert_equal "status echo", check("status echo a/b").command
    assert_equal "node", check("node frob").command, "the noun alone: the command line prints its verbs"
  end

  test "words as a shell splits them, nothing more" do
    l = check(%q(call a/b/c say "hello world" '{"x": 1}'), rows: [ allow("*", "*", "*", "*") ])
    assert_equal [ "call", "a/b/c", "say", "hello world", '{"x": 1}' ], l.words
    l = check(%q(call a/b/c say "open))
    assert_match(/does not read as words/, l.reason)
    assert check("").empty?
    assert check("asterism").empty?
    assert_match(/control character/, check("node list\nls").reason)
  end

  test "anything not in the command table is refused, with the reason" do
    %w[ls rm sh bash ruby curl cat exit].each do |w|
      l = check("#{w} -la")
      refute l.ok?
      assert_match(/is not an asterism command/, l.reason)
    end
    assert_match(/not an asterism command/, check("$(ls)").reason)
    assert_match(/not an asterism command/, check("`id`").reason)
    assert_match(/runs only as a program of its own/, check("mcp --allow '*'").reason)
    assert_match(/runs only as a program of its own/, check("completion bash").reason)
    assert_match(/press Tab/, check("__complete -- node").reason)
  end

  test "no other connection" do
    %w[--router --credentials --peer --node --app].each do |o|
      assert_match(/#{o}: the Terminal runs on the console's connection/, check("node list #{o} x").reason)
      assert_match(/#{o}:/, check("node list #{o}=x").reason)
    end
    assert check("call a/b/c m -- --router", rows: [ allow("*", "*", "*", "*") ]).ok?, "after --, a word"
    assert_match(/at most 30 s/, check("node list --timeout 31").reason)
  end

  test "call and ping --call by the call permissions" do
    rows = [ allow("fmruby-*", "demo", "screen", "say") ]
    l = check("call fmruby-aaaaaa/demo/screen say hi", rows: rows)
    assert l.ok?, l.reason
    assert_equal [ "call", "call", "fmruby-aaaaaa/demo/screen", "say" ], [ l.command, l.effect, l.path, l.method_name ]
    l = check("call fmruby-aaaaaa/demo/screen clear", rows: rows)
    assert_match(/no call permission allows fmruby-aaaaaa\/demo\/screen clear/, l.reason)
    assert_equal "call", l.effect
    l = check("call --timeout 3 fmruby-aaaaaa/demo/screen --kwargs '{a: 1}' say", rows: rows)
    assert_equal [ "fmruby-aaaaaa/demo/screen", "say" ], [ l.path, l.method_name ], "options anywhere"
    assert l.ok?
    l = check("ping fmruby-aaaaaa/demo/screen --call clear --count 1", rows: rows)
    assert_equal [ "call", "clear" ], [ l.effect, l.method_name ]
    refute l.ok?
    assert check("ping fmruby-aaaaaa/demo/screen --call=say", rows: rows).ok?
    assert_match(/which object and method/, check("call", rows: rows).reason)
    assert_match(/no call permission/, check("call a/b/c m").reason, "no rows: nothing")
  end
end
