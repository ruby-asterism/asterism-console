# The Terminal's commands in the bridge (docs/terminal.md): each command
# line typed on a Terminal page (a TerminalCommand row) runs here with the
# asterism gem's command line (Asterism::CLI), on the bridge's own
# connection (CLI.new(net: the bridge's Asterism::Connection)): the
# console's node, certificate and ACL, no second session. Its output goes to that page alone
# (ConsoleChannel.send_terminal), in colour and at the page's width (the
# output answers tty? and winsize as a terminal does).
#
#   - picked up on every tick of the bridge, at most MAX_RUNNING at once and
#     PER_USER per user (the others wait; past EXPIRE_AFTER they expire);
#   - read again here before it runs (Terminal::Line, with the call
#     permissions of the moment), and the command line asks once more when it
#     has parsed the options its own way (permit:): a call (call, ping
#     --call) only when a call permission allows the object and the method,
#     never mcp or completion, no --timeout past 30 s;
#   - each on a thread of its own that never touches the database: the
#     output is buffered (Output) and sent by the main thread on its ticks,
#     at most CHUNK bytes a tick and MAX_OUTPUT in all (then it is stopped);
#   - stopped (CLI stop:) by Ctrl-C (the row's status "stopping"), when its
#     page is closed (its TerminalSession is gone or ran out), and when the
#     bridge stops or loses its router;
#   - when it ends, the row says how (ok, failed, denied, stopped), with its
#     exit code, the reason, its time and the start of its output: the
#     record the call log shows.
#
# A Tab (a row of kind "complete") runs the command line's __complete on the
# words before the cursor; the candidates go to the page and the row is
# removed.
#
# The remote shell (docs/terminal.md, "The remote shell"; the rows with
# remote, and remote alone): remote <node> opens a session on the machine
# (Bridge::RemoteShell, <node>/transfer/rshell) for the page, kept here
# (@remotes, page => session; the machine's session number never leaves
# the bridge) and copied for Rails into the page's TerminalSession (remote).
# One page at a time per machine: the machine sees one caller, the console.
# A line in it is read again here (Terminal::Remote: the machine's table,
# the user's rshell_access of the moment, and the paths: a change outside
# the user's areas not yet confirmed ends "asked" and the page asks), then
# sent on the command's thread, its output piece by piece. exit closes the
# session; so do the page closing (the bridge writes the exit row), the
# machine ending it, and the bridge stopping. A bridge that starts clears
# the copies (what it held is gone). Tab in a machine asks its complete.
#
# get and put (the console's file commands in a machine, docs/terminal.md
# "Files: get and put"): get brings the file into TerminalFiles and, when
# it is whole, tells the page to download it (a link only its user may take,
# once); put sends the files the page uploaded (the row's files: the
# upload's token), after asking (y/N, the page sends the line again with the
# same upload) when a file of the same name is there or the place is in the
# system's area. Both show their progress on one line and stop on Ctrl-C;
# what they carried goes into the row's files (the record).
module Bridge
  class Terminal
    MAX_RUNNING = TerminalCommand::MAX_RUNNING
    PER_USER = TerminalCommand::PER_USER
    # Tabs being answered at once.
    MAX_COMPLETING = 4
    MAX_OUTPUT = Integer(ENV.fetch("ASTERISM_TERMINAL_MAX_OUTPUT", 4 * 1024 * 1024))
    CHUNK = 64 * 1024
    # How long a stopped command's thread is waited for when the bridge stops.
    JOIN = 3.0
    # How often the files of get and put that nobody took are looked for.
    SWEEP_EVERY = 30
    # The messages that end a command's (or a Tab's) messages to its page.
    LAST_MESSAGES = %w[done complete].freeze

    # What a command prints: an IO for the command line (write, puts, print,
    # flush; a terminal of the page's width), filled by its thread and
    # drained by the bridge's main thread.
    class Output
      attr_reader :total, :head

      def initialize(cols: 80, limit: MAX_OUTPUT, keep: TerminalCommand::OUTPUT_KEPT * 2)
        @cols = cols
        @limit = limit
        @keep = keep
        @buf = +"".b
        @head = +"".b
        @total = 0
        @over = false
        @lock = Mutex.new
      end

      def write(*parts)
        n = 0
        @lock.synchronize do
          parts.each do |p|
            s = p.to_s.b
            n += s.bytesize
            @head << s.byteslice(0, @keep - @head.bytesize) if @head.bytesize < @keep
            if @total + s.bytesize > @limit
              @over = true
              s = s.byteslice(0, [ @limit - @total, 0 ].max)
            end
            @total += s.bytesize
            @buf << s
          end
        end
        n
      end

      def print(*parts)
        write(*parts)
        nil
      end

      def <<(s)
        write(s)
        self
      end

      def puts(*args)
        return write("\n") && nil if args.empty?
        args.flatten.each do |a|
          s = a.nil? ? "" : a.to_s
          write(s.end_with?("\n") ? s : "#{s}\n")
        end
        nil
      end

      def flush = self
      def sync = true
      def sync=(_v); end
      def tty? = true
      def isatty = true
      def winsize = [ 24, @cols ]
      def fileno = nil

      def over?
        @lock.synchronize { @over }
      end

      # Up to max bytes of what is waiting, cut where a character ends.
      def take(max = CHUNK)
        s = @lock.synchronize do
          out = @buf.byteslice(0, max)
          @buf = @buf.byteslice(out.bytesize..) || +"".b
          out
        end
        Output.utf8_cut(s) { |rest| @lock.synchronize { @buf = rest + @buf } }
      end

      def pending?
        @lock.synchronize { !@buf.empty? }
      end

      # The bytes as UTF-8, the last character's start given back when it
      # is cut (yielded), anything else invalid replaced.
      def self.utf8_cut(bytes)
        s = bytes.dup.force_encoding(Encoding::UTF_8)
        return s if s.valid_encoding?
        3.times do |i|
          cut = s.bytesize - i - 1
          break if cut <= 0
          head = s.byteslice(0, cut).force_encoding(Encoding::UTF_8)
          next unless head.valid_encoding?
          yield s.byteslice(cut..).b
          return head
        end
        s.scrub
      end
    end

    Entry = Struct.new(:id, :page, :user_id, :kind, :thread, :output, :started, :stop, :stop_reason, :result, :plan,
                       :remote, keyword_init: true)

    # cli: makes the command line (out:, err:, stop:, permit:); the tests give
    # a stand-in. say: the bridge's log.
    # net: a callable giving the bridge's connection (nil while it has none).
    # rshell: the machines' remote shells (a Bridge::RemoteShell; the tests
    # give one with a stand-in call).
    def initialize(say:, cli: nil, net: -> { }, rshell: nil)
      @say = say
      @net = net
      @cli = cli || method(:default_cli)
      @rshell = rshell || RemoteShell.new(net: net)
      @entries = {} # row id => Entry
      @done = Queue.new
      @remotes = {} # page => RemoteShell::Session
      @opening = {} # node => page, while its open is asked
      @closers = []
      @seqs = {} # row id => the number of its last message to the page
    end

    def self.available?
      require "asterism/cli"
      ::Asterism::CLI.instance_method(:initialize).parameters.any? { _1[1] == :net }
    rescue LoadError
      false
    end

    # The rows a bridge left running when it stopped.
    def start
      TerminalCommand.where(kind: "run", status: %w[running stopping])
                     .update_all(status: "stopped", reason: "the bridge stopped while it ran", finished_at: Time.current,
                                 updated_at: Time.current)
      TerminalCommand.where(kind: "complete").delete_all
      TerminalSession.where.not(remote: nil).update_all(remote: nil, updated_at: Time.current)
      self
    end

    # The pages in a machine now: {page => node}.
    def remotes
      @remotes.transform_values(&:node)
    end

    # Every tick of the bridge: the output out, the ended ones written, the
    # waiting ones started.
    def tick
      flush_outputs
      finish_done
      take_pending
    end

    # Every sync: Ctrl-C, closed pages, the rows nobody picked up.
    def sync
      stopping = TerminalCommand.where(id: @entries.keys, status: "stopping").pluck(:id)
      stopping.each { stop(_1, "stopped (Ctrl-C)") }
      live = TerminalSession.live_pages
      @entries.each_value { |e| stop(e.id, "stopped: the page was closed") unless live.include?(e.page) }
      (@remotes.keys - live).each { leave(_1, "the page was closed") }
      @closers.reject! { !_1.alive? }
      if !@swept_at || mono - @swept_at > SWEEP_EVERY
        @swept_at = mono
        TerminalFiles.sweep
      end
      TerminalCommand.where(status: "pending").where(created_at: ...TerminalCommand::EXPIRE_AFTER.ago).find_each do |r|
        if r.kind == "complete"
          r.delete
        else
          r.update!(status: "expired", reason: "the bridge did not pick it up in time", finished_at: Time.current)
          send_page(r.page, "done", r.as_payload)
        end
      end
    end

    def running
      @entries.size
    end

    # The bridge stops (or lost its router): every command is stopped,
    # waited for a moment, and its row written.
    def close(why = "the bridge stopped (or lost its router)")
      @entries.each_value { stop(_1.id, why) }
      deadline = mono + JOIN
      @entries.each_value { _1.thread.join([ deadline - mono, 0.01 ].max) }
      flush_outputs
      finish_done
      @entries.each_value do |e|
        e.result ||= { code: nil }
        finish(e)
      end
      @entries.clear
      @remotes.keys.each { leave(_1, "the bridge stopped", timeout: RemoteShell::CLOSE_TIMEOUT) }
      @closers.each { _1.join(RemoteShell::CLOSE_TIMEOUT + 1) }
      @closers.clear
    rescue ActiveRecord::ActiveRecordError => e
      @say.call("bridge: terminal: #{e.message}")
    end

    private

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def stop(id, why)
      e = @entries[id]
      return unless e && !e.stop
      e.stop_reason = why
      e.stop = true
    end

    def take_pending
      runs = @entries.values.count { _1.kind == "run" }
      tabs = @entries.size - runs
      TerminalCommand.where(status: "pending").order(:id).limit(32).each do |row|
        if row.kind == "complete"
          next if tabs >= MAX_COMPLETING
          tabs += 1
        else
          next if runs >= MAX_RUNNING
          next if @entries.values.count { _1.kind == "run" && _1.user_id == row.user_id } >= PER_USER
          runs += 1
        end
        next unless TerminalCommand.where(id: row.id, status: "pending").update_all(status: "running",
                                                                                     started_at: Time.current).positive?
        row.reload
        if row.kind == "complete"
          row.remote.present? ? start_remote_complete(row) : start_complete(row)
        elsif row.remote.present? || row.command == "remote"
          start_remote(row)
        else
          start_run(row)
        end
      end
    end

    def start_run(row)
      line = ::Terminal::Line.check(row.line, permissions: (perms = CallPermission.all.to_a))
      unless line.ok? && !line.empty?
        row.update!(status: "denied", reason: line.reason || "an empty line", finished_at: Time.current,
                    command: line.command, effect: line.effect, path: line.path, method_name: line.method_name)
        @say.call("bridge: terminal #{row.id}: #{row.line.inspect} -> denied (checked by the bridge)")
        send_page(row.page, "done", row.as_payload)
        return
      end
      e = Entry.new(id: row.id, page: row.page, user_id: row.user_id, kind: "run", output: Output.new(cols: row.cols),
                    started: mono, stop: false)
      permit = ->(plan) { e.plan = plan; Terminal.refusal(plan, perms) }
      e.thread = Thread.new do
        cli = @cli.call(out: e.output, err: e.output, stop: -> { e.stop }, permit: permit)
        code = cli.run(line.words.dup)
        @done << [ e, { code: code, refused: cli.respond_to?(:refused) ? cli.refused : nil } ]
      rescue Exception => ex # rubocop:disable Lint/RescueException -- a command must never take the bridge down
        e.output.puts "asterism: #{ex.class}: #{ex.message}"
        @done << [ e, { code: 1, error: "#{ex.class}: #{ex.message}" } ]
      end
      @entries[row.id] = e
      @say.call("bridge: terminal #{row.id}: #{row.user&.email_address}: #{row.line}")
      send_page(row.page, "started", "id" => row.id)
    end

    def start_complete(row)
      require "asterism/cli/complete"
      words = ::Asterism::CLI::Complete.split_line("asterism #{row.line}")
      out = StringIO.new
      e = Entry.new(id: row.id, page: row.page, user_id: row.user_id, kind: "complete", output: out, started: mono,
                    stop: false)
      permit = ->(plan) { plan.key == "__complete" ? nil : "only __complete" }
      e.thread = Thread.new do
        code = @cli.call(out: out, err: StringIO.new, stop: -> { e.stop }, permit: permit).run([ "__complete", "--", *words ])
        @done << [ e, { code: code, word: words.last.to_s } ]
      rescue Exception => ex # rubocop:disable Lint/RescueException
        @done << [ e, { code: 1, word: words.last.to_s, error: "#{ex.class}: #{ex.message}" } ]
      end
      @entries[row.id] = e
    end

    # Why the command line's plan may not run (nil: it may). Asked on the
    # command's thread, so the call permissions come as rows read before.
    def self.refusal(plan, permissions)
      case plan.kind
      when :local
        return "#{plan.key} runs only as a program of its own (asterism #{plan.key}), not in the Terminal"
      when :call
        if (why = CallPermission.reserved_reason(plan.path))
          return why
        end
        unless plan.path && plan.method &&
               CallPermission.allows?(plan.path, plan.method, rows: permissions)
          return "no call permission allows #{plan.path} #{plan.method} (an admin allows calls under Call permissions)"
        end
      end
      %i[timeout put_timeout].each do |k|
        v = plan.options && plan.options[k]
        return "--timeout: at most #{::Terminal::Line::MAX_TIMEOUT.to_i} s in the Terminal" if v && v > ::Terminal::Line::MAX_TIMEOUT
      end
      nil
    end

    # A message to a page about one of its commands (or Tabs), with its
    # number: 1, 2, ... per command, the last one "done" (or "complete").
    # Action Cable gives two messages that come close together to the
    # socket from a pool of threads (Solid Cable's listener posts each to
    # the stream event loop's pool, the channel's handler then to the
    # worker pool), so the page may get them in either order: a "done"
    # before the "output" it follows, and the output dropped. The page
    # puts them back in this order (seq) before it handles them.
    def send_page(page, type, payload)
      id = payload["id"]
      seq = @seqs[id] = @seqs.fetch(id, 0) + 1
      @seqs.delete(id) if LAST_MESSAGES.include?(type)
      ConsoleChannel.send_terminal(page, type, payload.merge("seq" => seq))
    end

    def flush_outputs
      @entries.each_value do |e|
        next unless e.kind == "run"
        stop(e.id, "stopped: it printed more than #{MAX_OUTPUT} bytes") if e.output.over?
        next unless e.output.pending?
        data = e.output.take(CHUNK)
        send_page(e.page, "output", "id" => e.id, "data" => data) unless data.empty?
      end
    end

    def finish_done
      until @done.empty?
        e, result = @done.pop(true)
        next unless @entries.key?(e.id)
        e.result = result
        if e.kind == "run"
          while e.output.pending?
            data = e.output.take(CHUNK)
            send_page(e.page, "output", "id" => e.id, "data" => data) unless data.empty?
          end
        end
        finish(e)
        @entries.delete(e.id)
      end
    rescue ThreadError
      nil
    end

    def finish(e)
      r = e.result || {}
      if e.kind == "complete" && e.remote
        got = r[:remote_items] || {}
        send_page(e.page, "complete", "id" => e.id, "remote" => true, "start" => got["word"],
                                      "candidates" => Array(got["items"]))
        TerminalCommand.where(id: e.id).delete_all
        return
      end
      if e.kind == "complete"
        cands = r[:code].to_i.zero? ? e.output.string.lines.map(&:chomp).reject(&:empty?).first(200) : []
        send_page(e.page, "complete", "id" => e.id, "word" => r[:word].to_s, "candidates" => cands)
        TerminalCommand.where(id: e.id).delete_all
        return
      end
      return finish_remote(e, r) if e.remote
      status, reason =
        if r[:refused] then [ "denied", r[:refused] ]
        elsif e.stop then [ "stopped", e.stop_reason ]
        elsif r[:error] then [ "failed", r[:error] ]
        elsif r[:code].nil? then [ "stopped", e.stop_reason ]
        elsif r[:code].zero? then [ "ok", nil ]
        else [ "failed", nil ]
        end
      attrs = { status: status, exit_code: r[:code], reason: reason, output: TerminalCommand.summary(e.output.head),
                output_bytes: e.output.total, took_ms: ((mono - e.started) * 1000).round(1), finished_at: Time.current }
      if (pl = e.plan)
        attrs.merge!(command: pl.key, effect: pl.kind.to_s, path: (pl.path if pl.kind == :call),
                     method_name: (pl.method if pl.kind == :call))
      end
      row = TerminalCommand.find_by(id: e.id)
      return unless row
      row.update!(attrs)
      @say.call("bridge: terminal #{row.id}: #{row.command} -> #{row.status}#{" (#{row.exit_code})" if row.exit_code}")
      send_page(row.page, "done", row.as_payload)
    end

    # ------------------------------------------------------- the remote shell

    def start_remote(row)
      user = row.user
      level = user&.rshell_access.to_s
      words = ::Terminal::Remote.split(row.line)[0]
      if row.command == "remote"
        node = row.remote.presence
        return deny_remote(row, "you may not use the remote shell (an admin chooses who may, under Users)") unless user&.rshell?
        return run_remote(row, :list) { |out| list_nodes(out, row.page) } unless node
        if (cur = @remotes[row.page])
          return deny_remote(row, "this page is in #{cur.node} (exit leaves it first)")
        end
        other = @remotes.values.find { _1.node == node } || (@opening[node] && :opening)
        if other
          whose = other != :opening && other.user_id == row.user_id ? "you are in #{node} on another Terminal page" :
                    "another user of the console is in #{node} now"
          return deny_remote(row, "#{whose} (one Terminal page at a time per machine); try again later")
        end
        @opening[node] = row.page
        row.update!(effect: "open", path: ::Terminal::Remote.path(node), method_name: "open")
        return run_remote(row, :open) { @rshell.open(node, page: row.page, user_id: row.user_id) }
      end
      s = @remotes[row.page]
      unless s && s.node == row.remote
        return deny_remote(row, "the remote shell on #{row.remote} has ended (remote #{row.remote} opens another)",
                           remote: s&.state)
      end
      line = ::Terminal::Remote.check(row.line, commands: s.commands, level: level, cwd: s.cwd)
      row.update!(command: line.exit? ? "exit" : line.name, effect: line.exit? ? "close" : line.effect,
                  path: ::Terminal::Remote.path(s.node), method_name: line.method_name)
      return run_remote(row, :exit) { @rshell.close(s) } if line.exit?
      return deny_remote(row, "#{line.reason} (checked by the bridge)", remote: s.state) unless line.ok? && !line.empty?
      return start_get(row, s, line) if line.kind == "get"
      return start_put(row, s, line) if line.kind == "put"
      if line.asks? && !row.confirmed?
        why = "changes the system's area (#{line.system_paths.join(', ')}): asked first"
        row.update!(status: "asked", reason: why, finished_at: Time.current, effect: line.kind,
                    method_name: line.method_name)
        send_page(row.page, "done", row.as_payload.merge(
          "remote" => s.state,
          "confirm" => "#{line.system_paths.join(', ')} #{line.system_paths.size == 1 ? 'is' : 'are'} in the " \
                       "system's area of #{s.node} (outside /home, /app, /mnt/sd, /tmp). Go on? (y/N) "
        ))
        return
      end
      run_remote(row, :line) { |out, stop| @rshell.run(s, row.line, line.method_name, out: out, stop: stop) }
    end

    def deny_remote(row, why, remote: nil)
      row.update!(status: "denied", reason: why, finished_at: Time.current)
      @say.call("bridge: terminal #{row.id}: #{row.line.inspect} -> denied (#{why})")
      send_page(row.page, "done", row.as_payload.merge("remote" => remote))
    end

    # Runs what the block does on a thread of its own (out: the page's
    # output, stop: Ctrl-C / the page closed); what: :list, :open, :exit
    # or :line.
    def run_remote(row, what)
      e = Entry.new(id: row.id, page: row.page, user_id: row.user_id, kind: "run", output: Output.new(cols: row.cols),
                    started: mono, stop: false, remote: what)
      e.thread = Thread.new do
        v = yield(e.output, -> { e.stop })
        res = case what
              when :open then { code: 0, session: v }
              when :line then { code: v[0], how: v[1] }
              when :get, :put then { code: v["code"], how: v["how"], files: v }
              else { code: 0 }
              end
        @done << [ e, res ]
      rescue RemoteShell::Refused => ex
        # A refusal the machine gave already starts with its name
        # (Terminal::Remote.explain): say it once.
        e.output.puts "\e[31m#{row.remote || 'remote'}: #{ex.message.delete_prefix("#{row.remote}: ")}\e[0m"
        @done << [ e, { code: 1, refused: ex.message, ended: ex.ended } ]
      rescue Exception => ex # rubocop:disable Lint/RescueException -- a command must never take the bridge down
        e.output.puts "remote: #{ex.class}: #{ex.message}"
        @done << [ e, { code: 1, error: "#{ex.class}: #{ex.message}" } ]
      end
      @entries[row.id] = e
      @say.call("bridge: terminal #{row.id}: #{row.user&.log_name}: #{row.remote ? "#{row.remote}: " : ''}#{row.line}")
      send_page(row.page, "started", "id" => row.id)
    end

    def list_nodes(out, page)
      nodes = @rshell.nodes
      if nodes.empty?
        out.puts "No machine has its remote shell on the network now (its owner turns it on in the Receiving app; " \
                 "the console needs \"Remote shell from the console\" on its row under Members)."
        return
      end
      busy = @remotes.values.to_h { [ _1.node, _1.page ] }
      nodes.each do |n|
        note = if busy[n] == page then "  (this page is in it)"
        elsif busy[n] then "  (another Terminal page is in it)"
        else ""
        end
        out.puts "#{n}#{note}"
      end
    end

    def finish_remote(e, r)
      row = TerminalCommand.find_by(id: e.id)
      @opening.delete(row.remote) if row && e.remote == :open && @opening[row.remote] == row.page
      s = @remotes[e.page]
      case e.remote
      when :open
        if (sess = r[:session])
          @remotes[e.page] = sess
          s = sess
          TerminalSession.set_remote(e.page, sess.column)
        end
      when :exit
        @remotes.delete(e.page)
        TerminalSession.set_remote(e.page, nil)
        s = nil
      when :line, :get, :put
        if r[:ended]
          @remotes.delete(e.page)
          TerminalSession.set_remote(e.page, nil)
          s = nil
        elsif s
          TerminalSession.set_remote(e.page, s.column)
        end
      end
      return unless row
      files = r[:files]
      return ask_put(e, row, files, s) if e.remote == :put && files && files["asked"]
      TerminalFiles.drop_put(upload_of(row)) if e.remote == :put
      if e.remote == :get && files
        row.files = JSON.generate("files" => [ files.slice("path", "size", "got").merge("result" => files["how"] || "ok") ])
      elsif e.remote == :put
        row.files = JSON.generate("files" => Array(files && files["files"]))
      end
      if e.remote == :get && files && files["token"] && files["how"].nil?
        send_page(row.page, "download", "id" => row.id, "url" => "/terminal/files/#{files['token']}",
                                        "name" => files["name"])
      end
      status, reason =
        if r[:refused] then [ "denied", r[:refused] ]
        elsif r[:how] == "stopped" then [ "stopped", e.stop_reason || "stopped (Ctrl-C)" ]
        elsif r[:how] == "cut" then [ "failed", "more than #{RemoteShell::MORE_MAX} pieces of output" ]
        elsif r[:how] == "stalled" then [ "failed", "the machine's progress stopped for #{RemoteShell::STALL} s" ]
        elsif r[:error] then [ "failed", r[:error] ]
        elsif r[:code].nil? && e.stop then [ "stopped", e.stop_reason ]
        elsif r[:code].to_i.zero? then [ "ok", nil ]
        else [ "failed", nil ]
        end
      row.update!(status: status, exit_code: r[:code], reason: reason, output: TerminalCommand.summary(e.output.head),
                  output_bytes: e.output.total, took_ms: ((mono - e.started) * 1000).round(1), finished_at: Time.current)
      @say.call("bridge: terminal #{row.id}: #{row.remote}: #{row.command} -> #{row.status}" \
                "#{" (#{row.exit_code})" if row.exit_code}")
      send_page(row.page, "done", row.as_payload.merge("remote" => s&.state))
    end

    # get <path>: the file into the console's place for it, then a link
    # for the page.
    def start_get(row, s, line)
      path = line.words[1]
      full = ::Terminal::Remote.resolve(s.cwd, path)
      name = File.basename(full)
      run_remote(row, :get) do |out, stop|
        token, to = TerminalFiles.new_get(user_id: row.user_id, page: row.page, node: s.node, name: name, size: 0)
        begin
          r = @rshell.get(s, path, to: to, out: out, stop: stop)
        rescue Exception # rubocop:disable Lint/RescueException -- the place goes whatever happened
          TerminalFiles.drop_get(token)
          raise
        end
        if r["how"] == "stopped"
          TerminalFiles.drop_get(token)
          out.puts "get #{r['path']}: stopped at #{RemoteShell.kb(r['got'])} of #{RemoteShell.kb(r['size'])}"
          r.merge("code" => nil)
        else
          out.puts "get #{r['path']}: #{RemoteShell.sized(r['size'])}; the browser saves it as #{name}"
          r.merge("code" => 0, "token" => token, "name" => name)
        end
      end
    end

    # put [<path>]: the files the page uploaded, into the folder (the
    # session's, or path) or as the file path (one file).
    def start_put(row, s, line)
      if s.version.to_i < ::Terminal::Remote::PUT_VERSION
        return deny_remote(row, "put: #{s.node}'s remote shell is version #{s.version.to_i}; put needs " \
                                "#{::Terminal::Remote::PUT_VERSION} (a newer Family mruby)", remote: s.state)
      end
      files = TerminalFiles.put_files(upload_of(row), row.user)
      unless files
        return deny_remote(row, "put: no files came with the line (put opens the browser's file chooser, or drop " \
                                "files on the Terminal; chosen files wait #{TerminalFiles::KEEP / 60} min)", remote: s.state)
      end
      arg = line.words[1]
      dest = ::Terminal::Remote.resolve(s.cwd, arg.to_s)
      run_remote(row, :put) do |out, stop|
        folder = arg.nil? || arg.end_with?("/") || @rshell.there(s, [ dest ])[dest] == "directory"
        if !folder && files.size > 1
          raise RemoteShell::Refused, "put: #{dest} is not a folder on #{s.node} (#{files.size} files go into a folder)"
        end
        targets = files.map { folder ? (dest == "/" ? "/#{_1['name']}" : "#{dest}/#{_1['name']}") : dest }
        unless row.confirmed?
          there = @rshell.there(s, targets).select { |_, k| k == "file" }.keys
          parts = []
          if line.asks?
            parts << "#{line.system_paths.join(', ')} #{line.system_paths.size == 1 ? 'is' : 'are'} in the system's " \
                     "area of #{s.node} (outside /home, /app, /mnt/sd, /tmp)"
          end
          parts << "#{there.join(', ')} #{there.size == 1 ? 'is' : 'are'} there already (written over)" if there.any?
          next { "asked" => "#{parts.join('; ')}. Go on? (y/N) " } if parts.any?
        end
        results = []
        code = 0
        how = nil
        files.each_with_index do |f, i|
          begin
            r = @rshell.put(s, f["path"], targets[i], size: f["size"], overwrite: row.confirmed?, out: out, stop: stop)
          rescue RemoteShell::Refused => ex
            out.puts "\e[31mput #{targets[i]}: #{ex.message.delete_prefix("#{s.node}: ")}\e[0m"
            results << { "path" => targets[i], "size" => f["size"], "result" => "refused", "reason" => ex.message }
            code = 1
            next
          end
          if r["how"] == "stopped"
            out.puts "put #{r['path']}: stopped at #{RemoteShell.kb(r['got'])} of #{RemoteShell.kb(r['size'])} (nothing kept)"
            results << { "path" => r["path"], "size" => f["size"], "got" => r["got"], "result" => "stopped" }
            how = "stopped"
            break
          end
          out.puts "put #{r['path']}: #{RemoteShell.sized(r['size'])}"
          results << { "path" => r["path"], "size" => r["size"], "result" => "ok" }
        end
        { "code" => how ? nil : code, "how" => how, "files" => results }
      end
    end

    # A put that asks first (a name there, the system's area): the row ends
    # "asked", the upload stays for the line sent again.
    def ask_put(e, row, files, s)
      row.update!(status: "asked", reason: files["asked"].delete_suffix(" Go on? (y/N) "), finished_at: Time.current,
                  took_ms: ((mono - e.started) * 1000).round(1))
      send_page(row.page, "done", row.as_payload.merge("remote" => s&.state,
                                                       "confirm" => files["asked"],
                                                       "upload" => upload_of(row)))
    end

    def upload_of(row) = row.files_value["upload"]

    def start_remote_complete(row)
      s = @remotes[row.page]
      e = Entry.new(id: row.id, page: row.page, user_id: row.user_id, kind: "complete", output: StringIO.new,
                    started: mono, stop: false, remote: :complete)
      e.thread = Thread.new do
        got = s && s.node == row.remote && row.user&.rshell? ? @rshell.complete(s, row.line) : nil
        @done << [ e, { code: 0, remote_items: got } ]
      rescue Exception => ex # rubocop:disable Lint/RescueException
        @done << [ e, { code: 1, error: "#{ex.class}: #{ex.message}" } ]
      end
      @entries[row.id] = e
    end

    # The page left its machine without exit (closed, or the bridge
    # stops): the machine's session is closed on a thread of its own and the
    # record gets the exit.
    def leave(page, why, timeout: RemoteShell::CLOSE_TIMEOUT)
      s = @remotes.delete(page) or return
      waiting = @entries.values.select { _1.page == page }.map(&:thread)
      @closers << Thread.new do
        waiting.each { _1.join(JOIN) }
        @rshell.close(s, timeout: timeout)
      rescue StandardError
        nil
      end
      TerminalSession.set_remote(page, nil)
      TerminalCommand.create!(user_id: s.user_id, page: page, kind: "run", line: "exit", command: "exit",
                              effect: "close", remote: s.node, path: ::Terminal::Remote.path(s.node),
                              method_name: "close", status: "ok", reason: why, cols: 80,
                              started_at: Time.current, finished_at: Time.current)
      @say.call("bridge: terminal: #{page}: left #{s.node} (#{why})")
    rescue ActiveRecord::ActiveRecordError => e
      @say.call("bridge: terminal: #{e.message}")
    end

    # The command line on the bridge's connection. Never without one: a
    # command line given no connection would open its own.
    def default_cli(out:, err:, stop:, permit:)
      net = @net.call or raise ::Asterism::Disconnected, "the bridge is not connected"
      ::Asterism::CLI.new(out: out, err: err, env: {}, net: net, stop: stop, permit: permit)
    end
  end
end
