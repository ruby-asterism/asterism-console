# The remote shell's lines (docs/terminal.md, "The remote shell"): what a
# line typed in the Terminal means while the page is in a machine
# (remote <node>), read by Rails (the page's request) and by the bridge
# again (before it is sent). Plain Ruby, no database.
#
# The machine's side is <node>/transfer/rshell (Family mruby's transfer
# app, doc/remote_shell in fmruby-core). Its open answers the commands and
# whether each only reads or changes the machine ("commands" => {name =>
# "read" | "write"}); a line goes to exec_read or exec_write by that table.
# The console keeps no table of its own: a word the machine did not name is
# not sent ("not a command of this remote shell"). exit leaves (the
# console's word, never sent); get and put are kept for the console's own
# file commands (not in this version).
#
# Who may do what is per user (User#rshell_access): none (no remote shell
# at all), read (the read commands only), write (every command).
#
# The words are split as the machine splits them (RShell.split_line:
# blanks part words, "a b" and a\ b keep one), and paths are folded the
# same way (RShell.resolve), so that the console can tell a change of the
# system's area (outside /home, /app, /mnt/sd, /tmp) before it is sent and
# ask first (the plan's decision 11).
module Terminal
  module Remote
    LEVELS = %w[none read write].freeze
    LEVEL_TEXT = { "none" => "no remote shell", "read" => "read only", "write" => "read and change" }.freeze
    # The console's own words: never sent to the machine.
    EXIT = "exit".freeze
    # Kept for the console's file commands (R4): refused in this version.
    RESERVED = %w[get put].freeze
    # The user's areas: a change outside them is asked about first.
    USER_AREAS = %w[/home /app /mnt/sd /tmp].freeze
    # What the machine takes in one line (RShell::LINE_MAX).
    LINE_MAX = 1024
    # The commands whose words after the flags are paths changed (the last
    # one of cp: its destination). kill and open change no path.
    NO_PATHS = %w[kill open].freeze
    LAST_PATH = %w[cp].freeze
    # A node ID as the console names machines (Relay::CertAuthority::NAME_RE
    # and the browsers' wasm-<handle>).
    NODE = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

    # The object of a node's remote shell.
    def self.path(node) = "#{node}/transfer/rshell"

    # A line read for the remote shell: words, name, kind ("read", "write",
    # "exit"), the reason it is not sent (nil: it may be), and the paths of
    # the system's area it would change.
    Line = Struct.new(:text, :words, :name, :kind, :reason, :system_paths, keyword_init: true) do
      def ok? = reason.nil?
      def empty? = words.empty? && reason.nil?
      def exit? = kind == EXIT
      def write? = kind == "write"
      def method_name = { "read" => "exec_read", "write" => "exec_write", "exit" => "close" }[kind]
      def asks? = !system_paths.to_a.empty?
    end

    # text: the line; commands: the machine's table (open's answer);
    # level: the user's rshell_access; cwd: where the session is (nil: the
    # paths are not looked at).
    def self.check(text, commands:, level:, cwd: nil)
      text = text.to_s
      l = Line.new(text: text, words: [], system_paths: [])
      return l.tap { _1.reason = "the line is longer than #{LINE_MAX} bytes" } if text.bytesize > LINE_MAX
      return l.tap { _1.reason = "the line has a control character" } if text.match?(/[\x00-\x08\x0a-\x1f\x7f]/)
      words, open = split(text)
      return l.tap { _1.reason = "a quote is left open" } if open
      l.words = words
      return l if words.empty?
      name = l.name = words[0]
      if name == EXIT
        l.kind = EXIT
        return l
      end
      unless LEVELS.include?(level.to_s) && level.to_s != "none"
        return l.tap { _1.reason = "you may not use the remote shell (an admin chooses who may, under Users)" }
      end
      if RESERVED.include?(name)
        return l.tap { _1.reason = "#{name}: not in this version of the console (files go through the Files page for now)" }
      end
      kind = Hash(commands)[name]
      unless %w[read write].include?(kind)
        return l.tap { _1.reason = "#{name}: not a command of this remote shell (help lists them)" }
      end
      l.kind = kind
      if kind == "write" && level.to_s != "write"
        return l.tap { _1.reason = "#{name}: changes the machine; you may only read with the remote shell (an admin chooses, under Users)" }
      end
      l.system_paths = system_paths(name, words[1..], cwd) if kind == "write" && cwd
      l
    end

    # The paths a change command would change outside the user's areas,
    # folded from cwd.
    def self.system_paths(name, args, cwd)
      return [] if NO_PATHS.include?(name)
      paths = args.reject { _1.start_with?("-") && _1.size > 1 }
      paths = paths.last(1) if LAST_PATH.include?(name)
      paths.map { resolve(cwd, _1) }.reject { user_area?(_1) }.uniq
    end

    def self.user_area?(path)
      USER_AREAS.any? { path == _1 || path.start_with?("#{_1}/") }
    end

    # The machine's RShell.resolve: path from cwd, absolute, with ".", ".."
    # and "//" folded ("/" at most at the top).
    def self.resolve(cwd, path)
      p = path.to_s
      p = cwd.to_s if p.empty?
      p = "#{cwd}/#{p}" unless p.start_with?("/")
      kept = []
      p.split("/").each do |s|
        next if s.empty? || s == "."
        s == ".." ? kept.pop : kept << s
      end
      kept.empty? ? "/" : "/#{kept.join('/')}"
    end

    # The machine's RShell.split_line: [words, whether a quote is left
    # open]. Blanks (space, tab) part words; a backslash keeps the next
    # character, "..." keeps blanks.
    def self.split(line)
      out = []
      chars = line.to_s.chars
      i = 0
      open = false
      n = chars.size
      while i < n
        if [ " ", "\t" ].include?(chars[i])
          i += 1
          next
        end
        w = +""
        quote = false
        while i < n
          c = chars[i]
          if c == "\\" && i + 1 < n
            w << chars[i + 1]
            i += 2
            next
          end
          if c == '"'
            quote = !quote
            i += 1
            next
          end
          break if !quote && [ " ", "\t" ].include?(c)
          w << c
          i += 1
        end
        open = quote
        out << w
      end
      [ out, open ]
    end

    # What a refusal of the machine (its error's text) means for the user:
    # the console's words first, the machine's after them in brackets.
    def self.explain(node, error)
      text = error.to_s
      why =
        case text
        when /no object rshell exposed/, /no_object/
          "the remote shell is off on #{node} (its owner turns it on in the Receiving app)"
        when /lets no remote shell in \(rshell_enabled is off/
          "the remote shell is off on #{node} (its owner turns it on in the Receiving app)"
        when /only over a checked connection/
          "#{node} takes the remote shell only over a checked connection (a tls/ router with certificates, or the console's door)"
        when /lets no remote shell in from/
          "#{node} does not let this console in (tick \"Remote shell from the console\" on its row under Members, and Apply)"
        when /has a remote shell open from/
          "someone else is in #{node} now (another remote shell); try again later"
        when /no remote shell session/
          "the session on #{node} has ended (not used for a while, or the machine restarted); remote #{node} opens another"
        else
          return "#{node}: #{text}"
        end
      "#{why} (#{text})"
    end
  end
end
