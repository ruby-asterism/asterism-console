# The machine's side of the remote shell as the bridge calls it
# (docs/terminal.md, "The remote shell"): <node>/transfer/rshell of a
# Family mruby machine (its transfer app, doc/remote_shell in fmruby-core),
# called on the bridge's connection as the console's node. Bridge::Terminal
# keeps one Session per Terminal page that is in a machine and runs these
# on the threads of its commands; nothing here touches the database.
#
# The machine's calls (its report r1, 2):
#   open()                   -> {"id", "cwd", "commands" => {name => "read" | "write"}, ...}
#   exec_read / exec_write(id, line) -> {"out", "code", "cwd", "more", "cut", "wait"}
#   more(id, pos)            -> {"out", "more", "cut", "wait", "code"}
#   complete(id, line, pos)  -> {"word" (characters), "items", "cut"}
#   read(id, path, pos, len) -> {"data", "pos", "size"}         (get)
#   write_begin(id, path, size, overwrite) -> {"path", "piece", ...}
#   write_chunk(id, pos, data) -> the position it holds now   (put, r4)
#   write_end(id) -> {"path", "size"}; write_cancel(id); stop(id)
#   close(id)                -> true
# A refusal is raised (RemoteError, "raised"); a machine whose remote shell
# is off has no such object ("no_object").
#
# A line's output is handed out a piece at a time: after the first answer,
# more is asked while the answer has "more" (from that position), and
# between the calls the command's stop (Ctrl-C, the page closed) is looked
# at. kill and open answer that they asked ("wait"): more is then asked
# every WAIT_EVERY until the result is in (the machine gives up after 5 s).
# A long cp (the machine's version 3) waits the same way, with its
# progress: shown on one line, and Ctrl-C asks the machine to stop it.
# The machine writes the note of a cut output itself (64 KB).
#
# get and put (the console's words, docs/terminal.md "Files: get and
# put"): get reads a file READ_LEN at a time into the console's place for
# it (TerminalFiles), put writes the files the page uploaded a piece at a
# time; both show how far they are and stop between the calls.
module Bridge
  class RemoteShell
    APP_OBJECT = "transfer/rshell".freeze
    TIMEOUT = 10
    # How often more is asked while the machine waits for its kernel.
    WAIT_EVERY = 0.25
    # How many more calls one line may take (64 KB in 8 KB pieces, and the
    # waits of kill / open, with room).
    MORE_MAX = 200
    # How long the close of a page that went away is waited for.
    CLOSE_TIMEOUT = 3
    # get's read and put's pieces (the machine's READ_MAX, WRITE_MAX).
    READ_LEN = 8192
    PIECE_MAX = 8192
    # A long cp whose progress does not move for this long is left.
    STALL = 30
    # How often the progress line is written again (seconds).
    PROGRESS_EVERY = 0.2

    # What the bridge keeps of a page in a machine (never sent to the page:
    # id is the machine's session number).
    Session = Struct.new(:page, :user_id, :node, :id, :commands, :cwd, :version, keyword_init: true) do
      def state = { "node" => node, "cwd" => cwd }
      def column = { "node" => node, "commands" => commands, "cwd" => cwd, "rshell" => version }
    end

    # Not let in, or the machine did not take a call: the reason for the
    # user (Terminal::Remote.explain).
    class Refused < StandardError
      # The session on the machine is gone (closed, timed out, the machine
      # restarted): the page leaves it.
      attr_reader :ended

      def initialize(message, ended: false)
        super(message)
        @ended = ended
      end
    end

    # call: (node, method, *args) -> the machine's answer (the tests give a
    # stand-in); net: the bridge's connection, for the list of machines.
    def initialize(net: -> { }, call: nil, sleep: ->(s) { Kernel.sleep(s) })
      @net = net
      @call = call || method(:default_call)
      @sleep = sleep
    end

    # The nodes whose remote shell is on the network now.
    def nodes
      net = @net.call
      return [] unless net
      net.each("*/#{APP_OBJECT}").map { _1.asterism_path.split("/", 2)[0] }.uniq.sort
    end

    # Whether anything of node's is on the network (to tell "not there"
    # from "its remote shell is off").
    def present?(node)
      net = @net.call
      net ? net.each("#{node}/**").any? : true
    end

    # Whether node's transfer app is there (a machine with every switch of
    # it off runs none, and a call would only wait).
    def transfer?(node)
      net = @net.call
      net ? net.each("#{node}/transfer/*").any? : true
    end

    # Opens a session on node for page. Raises Refused.
    def open(node, page:, user_id:)
      # A Family mruby machine with its remote shell off (and nothing else
      # of it on Asterism) is not there either: the two cannot be told apart.
      unless present?(node)
        raise Refused, "#{node} is not on the network now (nothing of it is there: it is off or away, or its remote " \
                       "shell is off and nothing else of it is on the network)"
      end
      unless transfer?(node)
        raise Refused, "the remote shell is off on #{node} (its transfer app, which holds the remote shell, is not " \
                       "running there: its owner turns the remote shell on in the Receiving app)"
      end
      a = ask(node, "open")
      unless a.is_a?(Hash) && a["id"] && a["commands"].is_a?(Hash)
        raise Refused, "#{node} answered open with something that is not a remote shell's session (#{a.inspect[0, 120]})"
      end
      commands = a["commands"].select { |k, v| k.is_a?(String) && %w[read write].include?(v) }
      v = a["version"].is_a?(Hash) ? a["version"]["rshell"].to_i : 0
      Session.new(page: page, user_id: user_id, node: node, id: a["id"], commands: commands, cwd: a["cwd"].to_s,
                  version: v)
    end

    # Sends a line (method: exec_read or exec_write) and writes its output
    # to out, piece by piece. Returns [code, how it ended]: how is nil
    # (done), "stopped" (stop said so between the calls) or "cut" (more
    # calls than MORE_MAX).
    def run(s, line, method, out:, stop: -> { false })
      a = ask(s.node, method, s.id, line)
      raise Refused, "#{s.node} answered #{method} with #{a.inspect[0, 120]}" unless a.is_a?(Hash)
      s.cwd = a["cwd"].to_s if a["cwd"].is_a?(String)
      write(out, a["out"])
      code = a["code"]
      pos = a["more"]
      waiting = a["wait"] == true
      n = 0
      shown = nil # the progress on the line now
      moved = mono
      while pos
        if stop.call
          return [ code, "stopped" ] unless waiting && s.version.to_i >= 3
          # the machine stops what it does (a long cp) and says so
          ask(s.node, "stop", s.id)
          m = ask(s.node, "more", s.id, pos)
          clear_progress(out) if shown
          write(out, m["out"]) if m.is_a?(Hash)
          return [ m.is_a?(Hash) && !m["code"].nil? ? m["code"] : code, "stopped" ]
        end
        return [ code, "cut" ] if !waiting && (n += 1) > MORE_MAX
        return [ code, "stalled" ] if waiting && mono - moved > STALL
        @sleep.call(WAIT_EVERY) if waiting
        m = ask(s.node, "more", s.id, pos)
        break unless m.is_a?(Hash)
        if (pr = m["progress"]).is_a?(Hash) && m["out"].to_s.empty?
          if pr != shown
            moved = mono
            shown = pr
            out.write("\r\e[K  #{kb(pr['done'])} / #{kb(pr['total'])}")
          end
        else
          clear_progress(out) if shown && !m["out"].to_s.empty?
          shown = nil if shown && !m["out"].to_s.empty?
        end
        write(out, m["out"])
        code = m["code"] unless m["code"].nil?
        waiting = m["wait"] == true
        moved = mono unless waiting
        pos = m["more"]
      end
      [ code, nil ]
    end

    # get: the file at path (as the machine reads it from the session's
    # place) into to, READ_LEN at a time. Returns {"path" (folded),
    # "size", "how" => nil | "stopped"}; raises Refused (not a file, a
    # secret, over max).
    def get(s, path, to:, out:, stop: -> { false }, max: TerminalFiles::FILE_MAX)
      full = ::Terminal::Remote.resolve(s.cwd, path)
      a = ask(s.node, "read", s.id, full, 0, READ_LEN)
      raise Refused, "#{s.node} answered read with #{a.inspect[0, 120]}" unless a.is_a?(Hash) && a["size"].is_a?(Integer)
      size = a["size"]
      if size > max
        raise Refused, "#{full}: #{kb(size)}, over the console's limit of #{kb(max)} for get (ASTERISM_RSHELL_FILE_MAX_BYTES)"
      end
      got = 0
      p = Progress.new(out, "get #{full}", size)
      File.open(to, "wb") do |f|
        data = a["data"].to_s.b
        loop do
          f.write(data)
          got += data.bytesize
          p.show(got)
          break if got >= size
          if stop.call
            p.done
            return { "path" => full, "size" => size, "got" => got, "how" => "stopped" }
          end
          a = ask(s.node, "read", s.id, full, got, READ_LEN)
          data = a.is_a?(Hash) ? a["data"].to_s.b : "".b
          raise Refused, "#{full}: it ended at #{got} of #{size} bytes (the file changed while it was read?)" if data.empty?
        end
      end
      p.done
      { "path" => full, "size" => got, "got" => got, "how" => nil }
    end

    # The files that are on the machine already among targets (folded
    # paths), and whether each target is a folder: {path => "file" |
    # "directory"} for those there.
    def there(s, targets)
      targets.to_h do |t|
        a = ask(s.node, "exec_read", s.id, "stat #{::Terminal::Remote.escape(t)}")
        kind = if !a.is_a?(Hash) || a["code"] != 0 then nil
        elsif a["out"].to_s.include?("type: directory") then "directory"
        else "file"
        end
        [ t, kind ]
      end.compact.reject { |_, k| k.nil? }
    end

    # put: one file (local path, size) to the folded path target. Returns
    # {"path", "size", "how" => nil | "stopped"}; raises Refused (the
    # machine's refusal: a secret, read-only, there and not overwrite, no
    # room).
    def put(s, local, target, size:, overwrite:, out:, stop: -> { false })
      b = ask(s.node, "write_begin", s.id, target, size, overwrite)
      raise Refused, "#{s.node} answered write_begin with #{b.inspect[0, 120]}" unless b.is_a?(Hash)
      piece = b["piece"].to_i.clamp(512, PIECE_MAX)
      full = b["path"].is_a?(String) ? b["path"] : target
      p = Progress.new(out, "put #{full}", size)
      pos = 0
      File.open(local, "rb") do |f|
        while pos < size
          if stop.call
            ask(s.node, "write_cancel", s.id)
            p.done
            return { "path" => full, "size" => size, "got" => pos, "how" => "stopped" }
          end
          f.seek(pos)
          data = f.read(piece).to_s.b
          raise Refused, "#{full}: the console's copy ended at #{pos} of #{size} bytes" if data.empty?
          at = ask(s.node, "write_chunk", s.id, pos, data)
          raise Refused, "#{s.node} answered write_chunk with #{at.inspect[0, 60]}" unless at.is_a?(Integer)
          pos = at
          p.show(pos)
        end
      end
      e = ask(s.node, "write_end", s.id)
      p.done
      { "path" => e.is_a?(Hash) && e["path"].is_a?(String) ? e["path"] : full, "size" => size, "got" => size, "how" => nil }
    rescue Refused
      begin
        ask(s.node, "write_cancel", s.id, timeout: CLOSE_TIMEOUT)
      rescue Refused
        nil
      end
      raise
    end

    # The line saying how far a get or put is, written again at most every
    # PROGRESS_EVERY on the same line.
    class Progress
      def initialize(out, what, total)
        @out = out
        @what = what
        @total = total
        @at = nil
        @shown = false
      end

      def show(done)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @at && now - @at < PROGRESS_EVERY && done < @total
        @at = now
        @shown = true
        @out.write("\r\e[K#{@what}: #{RemoteShell.kb(done)} / #{RemoteShell.kb(@total)}")
      end

      def done
        @out.write("\r\e[K") if @shown
      end
    end

    # n bytes for a line of the output: "12 KB (12345 bytes)".
    def self.sized(n) = n.to_i < 1024 ? "#{n.to_i} bytes" : "#{kb(n)} (#{n.to_i} bytes)"

    def self.kb(n)
      n = n.to_i
      return "#{n} bytes" if n < 1024
      n >= 10 * 1024 * 1024 ? "#{(n / 1048576.0).round(1)} MB" : "#{(n + 512) / 1024} KB"
    end

    # The machine's candidates for the word before the end of line:
    # {"word" => where it starts (characters), "items" => [...]}.
    def complete(s, line)
      a = ask(s.node, "complete", s.id, line, nil)
      return { "word" => line.to_s.length, "items" => [] } unless a.is_a?(Hash)
      items = Array(a["items"]).grep(String).first(200)
      # the first word: the console's file commands too (the machine does not
      # know them; their arguments are its paths, which it completes)
      if line.to_s.lstrip == line.to_s && !line.to_s.match?(/[ \t]/) && a["word"].to_i.zero?
        items = (items + ::Terminal::Remote::FILE_COMMANDS.keys.select { _1.start_with?(line.to_s) }).uniq.sort
      end
      { "word" => a["word"].to_i, "items" => items, "cut" => a["cut"] == true }
    end

    def close(s, timeout: TIMEOUT)
      ask(s.node, "close", s.id, timeout: timeout)
    rescue Refused, ::Asterism::Error
      false
    end

    private

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def kb(n) = self.class.kb(n)

    def clear_progress(out)
      out.write("\r\e[K")
    end

    def write(out, text)
      t = text.to_s
      out.write(t) unless t.empty?
    end

    # One call; the machine's refusals as Refused with the user's words.
    def ask(node, method, *args, timeout: TIMEOUT)
      @call.call(node, method, *args, timeout: timeout)
    rescue ::Asterism::RemoteError => e
      msg = e.respond_to?(:remote_message) && e.remote_message ? e.remote_message : e.message
      msg = "#{e.remote_kind}: #{msg}" if e.respond_to?(:remote_kind) && e.remote_kind == "no_object"
      raise Refused.new(::Terminal::Remote.explain(node, msg), ended: msg.include?("no remote shell session"))
    rescue ::Asterism::TimeoutError
      raise Refused, "#{node} did not answer #{method} in #{timeout} s (it is not on the network, or the router " \
                     "does not let the console reach it)"
    rescue ::Asterism::Disconnected => e
      raise Refused, "the bridge is not connected (#{e.message})"
    end

    def default_call(node, method, *args, timeout:)
      net = @net.call or raise ::Asterism::Disconnected, "the bridge is not connected"
      net["#{node}/#{APP_OBJECT}", timeout: timeout].asterism_call(method, *args)
    end
  end
end
