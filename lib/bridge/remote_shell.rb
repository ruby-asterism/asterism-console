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
#   close(id)                -> true
# A refusal is raised (RemoteError, "raised"); a machine whose remote shell
# is off has no such object ("no_object").
#
# A line's output is handed out a piece at a time: after the first answer,
# more is asked while the answer has "more" (from that position), and
# between the calls the command's stop (Ctrl-C, the page closed) is looked
# at. kill and open answer that they asked ("wait"): more is then asked
# every WAIT_EVERY until the result is in (the machine gives up after 5 s).
# The machine writes the note of a cut output itself (64 KB).
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

    # What the bridge keeps of a page in a machine (never sent to the page:
    # id is the machine's session number).
    Session = Struct.new(:page, :user_id, :node, :id, :commands, :cwd, keyword_init: true) do
      def state = { "node" => node, "cwd" => cwd }
      def column = { "node" => node, "commands" => commands, "cwd" => cwd }
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
      raise Refused, "#{node} is not on the network now (nothing of it is there)" unless present?(node)
      unless transfer?(node)
        raise Refused, "the remote shell is off on #{node} (its transfer app, which holds the remote shell, is not " \
                       "running there: its owner turns the remote shell on in the Receiving app)"
      end
      a = ask(node, "open")
      unless a.is_a?(Hash) && a["id"] && a["commands"].is_a?(Hash)
        raise Refused, "#{node} answered open with something that is not a remote shell's session (#{a.inspect[0, 120]})"
      end
      commands = a["commands"].select { |k, v| k.is_a?(String) && %w[read write].include?(v) }
      Session.new(page: page, user_id: user_id, node: node, id: a["id"], commands: commands, cwd: a["cwd"].to_s)
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
      while pos
        return [ code, "stopped" ] if stop.call
        return [ code, "cut" ] if (n += 1) > MORE_MAX
        @sleep.call(WAIT_EVERY) if waiting
        m = ask(s.node, "more", s.id, pos)
        break unless m.is_a?(Hash)
        write(out, m["out"])
        code = m["code"] unless m["code"].nil?
        waiting = m["wait"] == true
        pos = m["more"]
      end
      [ code, nil ]
    end

    # The machine's candidates for the word before the end of line:
    # {"word" => where it starts (characters), "items" => [...]}.
    def complete(s, line)
      a = ask(s.node, "complete", s.id, line, nil)
      return { "word" => line.to_s.length, "items" => [] } unless a.is_a?(Hash)
      { "word" => a["word"].to_i, "items" => Array(a["items"]).grep(String).first(200), "cut" => a["cut"] == true }
    end

    def close(s, timeout: TIMEOUT)
      ask(s.node, "close", s.id, timeout: timeout)
    rescue Refused, ::Asterism::Error
      false
    end

    private

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
