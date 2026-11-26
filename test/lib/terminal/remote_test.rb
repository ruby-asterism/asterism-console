require "test_helper"

# The remote shell's lines as Rails and the bridge read them
# (Terminal::Remote): the words as the machine splits them, the machine's
# table, the three permissions, the console's own words, the system's
# area, and the machine's refusals put in the user's words.
class Terminal::RemoteTest < ActiveSupport::TestCase
  COMMANDS = { "ls" => "read", "cat" => "read", "cd" => "read", "help" => "read",
               "cp" => "write", "mv" => "write", "rm" => "write", "mkdir" => "write", "kill" => "write",
               "open" => "write" }.freeze

  def check(line, level: "write", cwd: nil)
    Terminal::Remote.check(line, commands: COMMANDS, level: level, cwd: cwd)
  end

  test "the words as the machine splits them" do
    assert_equal [ %w[cat my\ file.txt], false ], Terminal::Remote.split('cat "my file.txt"')
    assert_equal [ [ "cat", "my file.txt" ], false ], Terminal::Remote.split("cat my\\ file.txt")
    assert_equal [ [ "ls", "-l", "かな" ], false ], Terminal::Remote.split("  ls\t-l  かな ")
    assert_equal [ [ "cat", "a b" ], true ], Terminal::Remote.split('cat "a b')
    assert_equal [ [], false ], Terminal::Remote.split("   ")
  end

  test "read, write and exit by the machine's table" do
    l = check("ls -l /home")
    assert_equal [ true, "read", "exec_read" ], [ l.ok?, l.kind, l.method_name ]
    l = check("rm old.txt")
    assert_equal [ true, "write", "exec_write" ], [ l.ok?, l.kind, l.method_name ]
    l = check("exit")
    assert_equal [ true, "exit", "close" ], [ l.ok?, l.kind, l.method_name ]
    assert check("").empty?
  end

  test "the permissions: none refuses everything but exit, read refuses the changes" do
    assert_match(/may not use the remote shell/, check("ls", level: "none").reason)
    assert check("exit", level: "none").ok?, "leaving is always possible"
    assert check("ls", level: "read").ok?
    assert_match(/rm: changes the machine; you may only read/, check("rm x", level: "read").reason)
    assert_match(/kill: changes the machine/, check("kill 3", level: "read").reason)
    assert check("rm x", level: "write").ok?
    assert_match(/may not use/, check("ls", level: "bogus").reason)
  end

  test "words the machine did not name are not sent" do
    assert_match(/run: not a command of this remote shell/, check("run 1+1").reason)
    assert_match(/irb: not a command/, check("irb").reason)
  end

  test "get and put are the console's: get reads, put changes; their usage" do
    l = check("get a.txt", level: "read")
    assert_equal [ true, "get", "read", "read" ], [ l.ok?, l.kind, l.effect, l.method_name ]
    l = Terminal::Remote.check("get a", commands: COMMANDS.merge("get" => "write"), level: "read")
    assert l.ok?, "the console's even when a machine names it"
    assert_match(/usage: get <file/, check("get").reason)
    assert_match(/usage: get <file/, check("get a b").reason)
    l = check("put", cwd: "/home")
    assert_equal [ true, "put", "write", "write_begin", [] ], [ l.ok?, l.kind, l.effect, l.method_name, l.system_paths ]
    assert_match(/put: changes the machine; you may only read/, check("put", level: "read").reason)
    assert_match(/usage: put/, check("put a b").reason)
    assert_equal [ "/usr/share" ], check("put ../usr/share", cwd: "/home").system_paths
    assert_equal [ "/" ], check("put", cwd: "/").system_paths
    assert_equal 'a\ \"b\\\\', Terminal::Remote.escape('a "b\\')
  end

  test "lines the machine would not take" do
    assert_match(/longer than 1024 bytes/, check("cat #{'a' * 1030}").reason)
    assert_match(/control character/, check("ls\n").reason)
    assert_match(/a quote is left open/, check('cat "a b').reason)
  end

  test "a change outside the user's areas is asked about, the paths folded from where the session is" do
    assert_empty check("rm a.txt", cwd: "/home").system_paths
    assert_empty check("mkdir /tmp/x /mnt/sd/y /app/z", cwd: "/").system_paths
    assert_equal %w[/etc/system_conf.toml], check("rm ../etc/system_conf.toml", cwd: "/home").system_paths
    assert_equal %w[/usr/share/x], check("rm -r x", cwd: "/usr/share").system_paths
    assert check("rm x", cwd: "/usr/share").asks?
    assert_equal %w[/etc/a], check("cp /etc/a /etc/a", cwd: "/home").system_paths, "cp: its destination"
    assert_empty check("cp /etc/a /home/a", cwd: "/home").system_paths, "copying out of it changes nothing there"
    assert_equal %w[/etc/a], check("mv /etc/a /home/a", cwd: "/home").system_paths, "mv takes it away"
    assert_empty check("kill 7", cwd: "/usr").system_paths
    assert_empty check("open /usr/app/x.app.rb", cwd: "/").system_paths
    assert_equal %w[/homeless], check("rm /homeless", cwd: "/").system_paths, "a name that only starts like /home"
    assert_equal %w[/], check("rm -r ../../..", cwd: "/home").system_paths
    assert_empty check("rm x", cwd: nil).system_paths, "without where it is, nothing is looked at"
    assert_empty check("ls /etc", cwd: "/").system_paths, "a read"
  end

  test "resolve folds as the machine does" do
    assert_equal "/home/a", Terminal::Remote.resolve("/home", "a")
    assert_equal "/etc", Terminal::Remote.resolve("/home/x", "../../etc/")
    assert_equal "/", Terminal::Remote.resolve("/", "../..")
    assert_equal "/home", Terminal::Remote.resolve("/home", "")
    assert_equal "/a/b", Terminal::Remote.resolve("/", "//a/./b")
  end

  test "the machine's refusals in the user's words, its own after them in brackets" do
    {
      "no_object: no object rshell exposed by fmruby-a/transfer" => /the remote shell is off on fmruby-a/,
      "fmruby-a lets no remote shell in (rshell_enabled is off there)" => /the remote shell is off on fmruby-a/,
      "fmruby-a takes the remote shell only over a checked connection (a tls/ router ...)" => /only over a checked connection/,
      "fmruby-a lets no remote shell in from console (not in rshell in receive.toml ...)" => /does not let this console in/,
      "fmruby-a has a remote shell open from pc (called 5 s ago); try again later" => /someone else is in fmruby-a/,
      "no remote shell session 3 from console on fmruby-a (closed ...)" => /session on fmruby-a has ended/
    }.each do |machine, ours|
      text = Terminal::Remote.explain("fmruby-a", machine)
      assert_match ours, text
      assert text.end_with?("(#{machine})"), "the machine's own words follow: #{text}"
    end
    assert_equal "fmruby-a: something else", Terminal::Remote.explain("fmruby-a", "something else")
  end
end
