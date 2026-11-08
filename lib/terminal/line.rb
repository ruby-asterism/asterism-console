# A command line typed in the Terminal (docs/terminal.md), read before it
# reaches the bridge, by Rails (the page's request) and by the bridge again
# (before it runs it): its words, which command of the asterism command
# line it is, whether it only reads or calls a method, and why it may not
# run.
#
# The commands come from the asterism gem's own table (its
# lib/asterism/cli/commands.rb, loaded without the Zenoh binding): a line
# whose first word is not one of them is refused. The words are split as a
# shell would (quotes, backslashes) and handed to the command line as they
# are: nothing is given to a shell, and nothing but the asterism command
# line runs them.
#
# Allowed:
#   - every command that only reads (CLI.kind :read), to every signed-in user;
#   - call, and ping --call, when a call permission allows the object and
#     the method (the same rows as the page's calls);
#   - help and version.
# Refused: anything else (an OS command, mcp, completion, the hidden
# __complete), the options that choose another connection (--router,
# --credentials, --peer, --node, --app: the Terminal runs on the console's).
#
# Here the line is read as the words say; the bridge asks the command line
# itself (CLI.new(permit:)) once it has parsed the options its own way,
# and that is what decides (an option written short, such as --cal for
# --call, is refused there).
require "shellwords"

module Terminal
  class Line
    MAX_BYTES = 2000
    MAX_WORDS = 64
    # The longest wait a command may ask for (--timeout): the bridge's
    # threads, like the page's calls (BridgeRequest::MAX_TIMEOUT).
    MAX_TIMEOUT = 30.0

    attr_reader :text, :words, :command, :effect, :path, :method_name, :reason

    # Whether the asterism gem has the command table (0.13.0 and later).
    def self.available?
      table
      true
    rescue LoadError
      false
    end

    def self.table
      require "asterism/cli/commands"
      ::Asterism::CLI
    end

    def self.check(text, permissions: nil)
      new(text).tap { _1.check!(permissions) }
    end

    def initialize(text)
      @text = text.to_s
      @words = []
    end

    def ok?
      @reason.nil?
    end

    def empty?
      @words.empty? && @reason.nil?
    end

    def call?
      @effect == "call"
    end

    def check!(permissions = nil)
      return refuse("the line is longer than #{MAX_BYTES} bytes") if @text.bytesize > MAX_BYTES
      return refuse("the line has a control character") if @text.match?(/[\x00-\x08\x0a-\x1f\x7f]/)
      begin
        @words = Shellwords.split(@text)
      rescue ArgumentError => e
        return refuse("the line does not read as words (#{e.message})")
      end
      @words.shift if @words.first == "asterism"
      return self if @words.empty?
      return refuse("more than #{MAX_WORDS} words") if @words.size > MAX_WORDS
      begin
        cli = self.class.table
      rescue LoadError
        return refuse("the Terminal needs the asterism gem 0.13.0 or newer (its command table)")
      end
      classify(cli)
      return self unless ok?
      check_options(cli)
      return self unless ok?
      check_call(permissions) if call?
      self
    end

    def as_payload
      { "words" => @words, "command" => @command, "effect" => @effect, "path" => @path, "method" => @method_name,
        "reason" => @reason }
    end

    private

    def refuse(why)
      @reason = why
      self
    end

    def classify(cli)
      first = @words[0]
      if %w[help -h --help].include?(first)
        @command = "help"
      elsif %w[version --version -v].include?(first)
        @command = "version"
      elsif cli::NOUNS.key?(first)
        verb = @words[1]
        @command = cli::NOUNS[first].key?(verb) ? "#{first} #{verb}" : first # the noun alone: its usage
      elsif cli::COMMANDS.key?(first) || cli::ALIASES.key?(first)
        @command = first
      elsif first == "__complete"
        return refuse("__complete is what Tab asks; press Tab")
      else
        return refuse("#{first.inspect} is not an asterism command (the Terminal runs the asterism command " \
                      "line's commands only; help lists them)")
      end
      if cli::LOCAL.include?(@command)
        return refuse("#{@command} runs only as a program of its own (asterism #{@command}), not in the Terminal")
      end
      call = (option_value("--call") if %w[ping echo].include?(@command))
      @effect = cli.kind(@command, call: call).to_s
      return unless call?
      pos = positional(cli)
      if @command == "call"
        @path, @method_name = pos[1], pos[2]
      else
        @path, @method_name = pos[1], call
      end
    end

    # The options that choose another connection, and waits past the limit.
    def check_options(cli)
      words = @words.take_while { _1 != "--" }
      given = words.find { cli::CONNECTION_OPTIONS.include?(_1.split("=", 2)[0]) }
      return refuse("#{given.split('=', 2)[0]}: the Terminal runs on the console's connection") if given
      t = option_value("--timeout")
      return unless t
      v = Float(t, exception: false)
      refuse("--timeout: at most #{MAX_TIMEOUT.to_i} s in the Terminal") if v && v > MAX_TIMEOUT
    end

    def check_call(permissions)
      unless @path && @method_name
        return refuse("#{@command}: which object and method? (call node/app/object METHOD [ARG...])")
      end
      rows = permissions || CallPermission.all
      return if CallPermission.allows?(@path, @method_name, rows: rows)
      refuse("no call permission allows #{@path} #{@method_name} (an admin allows calls under Call permissions)")
    end

    # The value of an option (--name VALUE or --name=VALUE; the last one
    # given), nil when it is not there.
    def option_value(name)
      v = nil
      words = @words.take_while { _1 != "--" }
      words.each_with_index do |w, i|
        if w == name
          v = words[i + 1]
        elsif w.start_with?("#{name}=")
          v = w.split("=", 2)[1]
        end
      end
      v
    end

    # The words that are not options or their values (as the command line
    # reads them: an option of VALUE_OPTIONS takes the next word).
    def positional(cli)
      out = []
      skip = false
      past = false
      @words.each do |w|
        if skip
          skip = false
          next
        end
        if past
          out << w
        elsif w == "--"
          past = true
        elsif w.start_with?("-") && w.size > 1 && !w.match?(/\A-\d/)
          skip = cli::VALUE_OPTIONS.include?(w)
        else
          out << w
        end
      end
      out
    end
  end
end
