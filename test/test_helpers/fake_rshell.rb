# A stand-in for a Family mruby machine's remote shell (<node>/transfer/rshell,
# fmruby-core flash/usr/share/transfer/rshell.rb; its calls and answers as
# doc/remote_shell/report/r1.md, 2 tells them, kill / open as r2's brief):
# a few files in memory, the output in 8 KB pieces with more, kill's "asked"
# and its result through more, Tab, one session, the callers let in, and its
# refusals raised as ArgumentError (the caller hears "raised"); R4: read
# gives a file's bytes as they are, write_begin / write_chunk / write_end /
# write_cancel put one into a hidden piece first (pending), stat says
# whether a path is there. Plain Ruby:
# the bridge's tests call it directly, the live test exposes it from a node in
# another process (caller: :from).
class FakeRShell
  OUT_MAX = 8192
  # The machine's whole table (its open's answer, in its order); the
  # stand-in answers the ones it does not play with nothing (code 0).
  TABLE = { "pwd" => "read", "cd" => "read", "ls" => "read", "cat" => "read", "head" => "read", "tail" => "read",
            "stat" => "read", "df" => "read", "free" => "read", "ps" => "read", "ver" => "read", "help" => "read",
            "cp" => "write", "mv" => "write", "rm" => "write", "mkdir" => "write", "kill" => "write",
            "open" => "write" }.freeze
  METHODS = { "open" => 0, "exec_read" => 2, "exec_write" => 2, "more" => 2, "complete" => 3, "read" => 4,
              "write_begin" => 4, "write_chunk" => 3, "write_end" => 1, "write_cancel" => 1, "stop" => 1,
              "close" => 1 }.freeze
  READ_MAX = 8192
  WRITE_MAX = 8192

  attr_reader :calls, :closed, :files, :pending
  attr_accessor :allow, :kill_waits, :version, :read_only

  def initialize(node = "fmruby-aaaaaa", allow: %w[console])
    @node = node
    @allow = allow
    @files = { "/home/notes.txt" => "hello\n", "/home/my file.txt" => "spaced\n", "/home/big.txt" => ("x" * 99 + "\n") * 200,
               "/home/apps/" => nil, "/etc/system_conf.toml" => "a = 1\n" }
    @s = nil
    @next = 1
    @calls = []
    @closed = []
    @kill_waits = 2
    @version = 3
    @read_only = []
    @pending = nil # put: {path, size, data}
  end

  def open(from: nil)
    let_in(from)
    if @s && @s[:from] != from
      raise ArgumentError, "#{@node} has a remote shell open from #{@s[:from]} (called 1 s ago); try again later"
    end
    @s = { id: @next, from: from, cwd: "/home", text: nil, wait: nil }
    @next += 1
    { "id" => @s[:id], "cwd" => "/home", "version" => { "os" => "test", "board" => "test", "rshell" => @version },
      "commands" => TABLE, "out_max" => OUT_MAX, "total_max" => 65536, "idle_ms" => 300000 }
  end

  def exec_read(id, line, from: nil) = exec(id, line, false, from)
  def exec_write(id, line, from: nil) = exec(id, line, true, from)

  def more(id, pos, from: nil)
    s = session(id, from)
    @calls << [ "more", pos ]
    if (w = s[:wait])
      if w[:left].positive?
        w[:left] -= 1
        return { "out" => "", "more" => pos, "cut" => false, "wait" => true, "code" => nil }
      end
      s[:wait] = nil
      s[:text] = "#{s[:text]}kill: PID #{w[:pid]} ended\n"
      out = s[:text].byteslice(pos..)
      return { "out" => out, "more" => nil, "cut" => false, "wait" => false, "code" => 0 }
    end
    # the machine's more says it is not waiting, and no code yet
    page(s, pos).merge("wait" => false, "code" => nil)
  end

  def complete(id, line, pos, from: nil)
    s = session(id, from)
    @calls << [ "complete", line ]
    words = line.split(/(?<!\\) /, -1)
    word = words.last.to_s
    start = line.length - word.length
    if words.size <= 1
      return { "word" => start, "items" => TABLE.keys.select { _1.start_with?(word) }.sort, "cut" => false }
    end
    plain = word.gsub("\\ ", " ")
    dir = plain.include?("/") ? plain[0..plain.rindex("/")] : ""
    base = File.join(dir.start_with?("/") ? "" : s[:cwd], dir).sub(%r{/?\z}, "/")
    items = @files.keys.filter_map do |path|
      next unless path.start_with?(base)
      rest = path.delete_prefix(base)
      name = rest.include?("/") ? rest[0..rest.index("/")] : rest
      next if name.empty? || !name.start_with?(plain.delete_prefix(dir))
      (dir + name).gsub(" ", "\\ ")
    end.uniq.sort
    { "word" => start, "items" => items, "cut" => false }
  end

  # get's reads (R4): up to READ_MAX bytes from pos.
  def read(id, path, pos, len, from: nil)
    s = session(id, from)
    @calls << [ "read", path, pos ]
    p = full(s, path)
    raise ArgumentError, "#{p}: kept from the remote shell (keys and passwords)" if p.start_with?("/home/asterism")
    data = @files[p]
    raise ArgumentError, "#{p}: not a file" unless data.is_a?(String)
    raise ArgumentError, "len: 1 to #{READ_MAX}" unless len.between?(1, READ_MAX)
    { "data" => data.b.byteslice(pos, len).to_s, "pos" => pos, "size" => data.bytesize }
  end

  def write_begin(id, path, size, overwrite, from: nil)
    s = session(id, from)
    @calls << [ "write_begin", path, size, overwrite ]
    @pending = nil
    p = full(s, path)
    raise ArgumentError, "#{p}: kept from the remote shell (keys and passwords)" if p.start_with?("/home/asterism")
    raise ArgumentError, "#{p}: read-only here" if @read_only.any? { p.start_with?(_1) }
    raise ArgumentError, "#{p}: a directory there" if @files.key?("#{p}/")
    raise ArgumentError, "#{p}: already there (overwrite to write over it)" if @files.key?(p) && overwrite != true
    @pending = { path: p, size: size, data: +"".b }
    { "path" => p, "size" => size, "pos" => 0, "piece" => WRITE_MAX }
  end

  def write_chunk(id, pos, data, from: nil)
    session(id, from)
    w = @pending or raise ArgumentError, "no file is coming in (write_begin first; it may have been dropped)"
    @calls << [ "write_chunk", pos, data.bytesize ]
    cur = w[:data].bytesize
    return cur if pos > cur || pos + data.bytesize <= cur
    w[:data] << data.b.byteslice(cur - pos..)
    w[:data].bytesize
  end

  def write_end(id, from: nil)
    session(id, from)
    w = @pending or raise ArgumentError, "no file is coming in"
    raise ArgumentError, "#{w[:path]}: #{w[:data].bytesize} of #{w[:size]} bytes are in" if w[:data].bytesize != w[:size]
    @calls << [ "write_end", w[:path] ]
    @files[w[:path]] = w[:data]
    @pending = nil
    { "path" => w[:path], "size" => w[:size] }
  end

  def write_cancel(id, from: nil)
    session(id, from)
    @calls << [ "write_cancel" ]
    @pending = nil
    true
  end

  def stop(id, from: nil)
    s = session(id, from)
    @calls << [ "stop" ]
    s[:wait] = nil
    true
  end

  def close(id, from: nil)
    return false unless @s && @s[:id] == id && @s[:from] == from
    @closed << id
    @s = nil
    true
  end

  private

  def let_in(from)
    raise ArgumentError, "#{@node} lets no remote shell in from #{from} (not in rshell in receive.toml, by hand or " \
                         "from the console)" unless @allow.include?(from)
  end

  def session(id, from)
    let_in(from)
    unless @s && @s[:id] == id && @s[:from] == from
      raise ArgumentError, "no remote shell session #{id} from #{from} on #{@node} (closed, or not called for 300 s: open again)"
    end
    @s
  end

  def exec(id, line, write, from)
    s = session(id, from)
    @calls << [ write ? "exec_write" : "exec_read", line ]
    s[:wait] = nil
    words = line.split(/(?<!\\) /).map { _1.gsub("\\ ", " ").delete('"') }
    name = words[0]
    kind = TABLE[name]
    return answer(s, "#{name}: no such command (help lists them)\n", 127) unless kind
    return answer(s, "#{name}: changes the machine; not taken by exec_read (exec_write)\n", 126) if kind == "write" && !write
    case name
    when "pwd" then answer(s, "#{s[:cwd]}\n", 0)
    when "cd"
      s[:cwd] = words[1] || "/home"
      answer(s, "", 0)
    when "ls"
      dir = "#{s[:cwd]}/"
      names = @files.keys.select { _1.start_with?(dir) }.map { _1.delete_prefix(dir) }.map { _1.include?("/") ? _1[0.._1.index("/")] : _1 }.uniq.sort
      answer(s, names.map { "#{_1}\n" }.join, 0)
    when "cat"
      path = words[1].start_with?("/") ? words[1] : "#{s[:cwd]}/#{words[1]}"
      text = @files[path]
      text ? answer(s, text, 0) : answer(s, "cat: #{path}: no such file\n", 1)
    when "stat"
      path = full(s, words[1])
      if @files.key?("#{path}/") then answer(s, "#{path}\n  type: directory\n", 0)
      elsif @files.key?(path) then answer(s, "#{path}\n  type: file\n", 0)
      else answer(s, "stat: #{path}: no such file or directory\n", 1)
      end
    when "rm"
      path = File.expand_path(words[1], s[:cwd])
      @files.delete(path) ? answer(s, "", 0) : answer(s, "rm: #{path}: no such file\n", 1)
    when "kill"
      text = "kill: asked the kernel to end PID #{words[1]} (demo)\n"
      s[:text] = text
      s[:wait] = { pid: words[1], left: @kill_waits }
      { "out" => text, "code" => 0, "cwd" => s[:cwd], "more" => text.bytesize, "cut" => false, "wait" => true }
    else answer(s, "", 0)
    end
  end

  def full(s, path)
    File.expand_path(path.to_s, s[:cwd])
  end

  def answer(s, text, code)
    s[:text] = text
    page(s, 0).merge("code" => code, "cwd" => s[:cwd])
  end

  def page(s, pos)
    t = s[:text].to_s
    out = t.byteslice(pos, OUT_MAX).to_s
    nxt = pos + out.bytesize
    { "out" => out, "more" => nxt < t.bytesize ? nxt : nil, "cut" => false }
  end
end
