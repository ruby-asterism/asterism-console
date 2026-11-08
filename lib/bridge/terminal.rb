# The Terminal's commands in the bridge (docs/terminal.md): each command
# line typed on a Terminal page (a TerminalCommand row) runs here with the
# asterism gem's command line (Asterism::CLI), on the bridge's own
# connection (CLI.new(net: Asterism.net)): the console's node, certificate
# and ACL, no second session. Its output goes to that page alone
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
                       keyword_init: true)

    # cli: makes the command line (out:, err:, stop:, permit:); the tests give
    # a stand-in. say: the bridge's log.
    def initialize(say:, cli: nil)
      @say = say
      @cli = cli || method(:default_cli)
      @entries = {} # row id => Entry
      @done = Queue.new
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
      self
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
      TerminalCommand.where(status: "pending").where(created_at: ...TerminalCommand::EXPIRE_AFTER.ago).find_each do |r|
        if r.kind == "complete"
          r.delete
        else
          r.update!(status: "expired", reason: "the bridge did not pick it up in time", finished_at: Time.current)
          ConsoleChannel.send_terminal(r.page, "done", r.as_payload)
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
        row.kind == "complete" ? start_complete(row) : start_run(row)
      end
    end

    def start_run(row)
      line = ::Terminal::Line.check(row.line, permissions: (perms = CallPermission.all.to_a))
      unless line.ok? && !line.empty?
        row.update!(status: "denied", reason: line.reason || "an empty line", finished_at: Time.current,
                    command: line.command, effect: line.effect, path: line.path, method_name: line.method_name)
        @say.call("bridge: terminal #{row.id}: #{row.line.inspect} -> denied (checked by the bridge)")
        ConsoleChannel.send_terminal(row.page, "done", row.as_payload)
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
      ConsoleChannel.send_terminal(row.page, "started", "id" => row.id)
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

    def flush_outputs
      @entries.each_value do |e|
        next unless e.kind == "run"
        stop(e.id, "stopped: it printed more than #{MAX_OUTPUT} bytes") if e.output.over?
        next unless e.output.pending?
        data = e.output.take(CHUNK)
        ConsoleChannel.send_terminal(e.page, "output", "id" => e.id, "data" => data) unless data.empty?
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
            ConsoleChannel.send_terminal(e.page, "output", "id" => e.id, "data" => data) unless data.empty?
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
      if e.kind == "complete"
        cands = r[:code].to_i.zero? ? e.output.string.lines.map(&:chomp).reject(&:empty?).first(200) : []
        ConsoleChannel.send_terminal(e.page, "complete", "id" => e.id, "word" => r[:word].to_s, "candidates" => cands)
        TerminalCommand.where(id: e.id).delete_all
        return
      end
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
      ConsoleChannel.send_terminal(row.page, "done", row.as_payload)
    end

    # The command line on the bridge's connection. Never without one: a
    # command line given no connection would open its own.
    def default_cli(out:, err:, stop:, permit:)
      net = ::Asterism.net or raise ::Asterism::Disconnected, "the bridge is not connected"
      ::Asterism::CLI.new(out: out, err: err, env: {}, net: net, stop: stop, permit: permit)
    end
  end
end
