# Log lines for the log page (like rqt_console), from two sources:
#
#   - ROS 2: /rosout of each domain (<domain>/rosout/<type>/<hash>), each
#     message an rcl_interfaces/msg/Log, decoded with the generated type
#     (vendor/msgs; asterism does not bundle rcl_interfaces).
#   - Asterism (a proposal, docs/v3.md): asterism/<node>/<app>/log, each
#     message a MessagePack Hash { "level", "msg", "time" } and optionally
#     "name", "file", "line", "function".
#
# The bridge subscribes while a log page is open (StreamLease "log") and
# feeds every message to record, on the receiving thread; record keeps at
# most PENDING raw messages until the main thread drains them (more are
# dropped and counted). drain decodes at most PER_SECOND lines a second
# (the rest are dropped and counted too), so a node that logs in a tight
# loop costs the bridge a bounded amount.
module Bridge
  class Logs
    PENDING = 1000
    PER_SECOND = 200
    MAX_TEXT = 4000
    LEVELS = { 10 => "DEBUG", 20 => "INFO", 30 => "WARN", 40 => "ERROR", 50 => "FATAL" }.freeze
    NAMES = { "debug" => 10, "info" => 20, "warn" => 30, "warning" => 30, "error" => 40, "fatal" => 50 }.freeze
    ASTERISM_KEY = "asterism/*/*/log"
    LOG_TYPE = "rcl_interfaces/msg/Log"

    attr_reader :dropped

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   wall: -> { (Time.now.to_f * 1000).round })
      @clock = clock
      @wall = wall
      @lock = Mutex.new
      @pending = []
      @dropped = 0
      @errors = 0
      @second = -1
      @in_second = 0
    end

    attr_reader :errors

    def clear
      @lock.synchronize { @pending.clear }
    end

    # One message (any thread).
    def record(key, bytes)
      at = @wall.call
      @lock.synchronize do
        if @pending.size >= PENDING
          @dropped += 1
          return false
        end
        @pending << [ key.to_s, bytes, at ]
      end
      true
    end

    # The lines decoded since the last drain (main thread), oldest first.
    def drain
      batch = @lock.synchronize do
        b = @pending
        @pending = []
        b
      end
      sec = @clock.call.floor
      if sec != @second
        @second = sec
        @in_second = 0
      end
      lines = []
      batch.each do |key, bytes, at|
        if @in_second >= PER_SECOND
          @dropped += 1
          next
        end
        line = self.class.line(key, bytes, at)
        if line
          @in_second += 1
          lines << line
        else
          @errors += 1
        end
      end
      lines
    end

    # A line from a message, or nil when it does not decode.
    #   { "at" (ms since the epoch), "level" ("INFO"), "severity" (20),
    #     "name", "msg", "file", "line", "function", "source" ("ros" /
    #     "asterism"), "key" }
    def self.line(key, bytes, at)
      if key.start_with?("asterism/")
        asterism_line(key, bytes, at)
      else
        ros_line(key, bytes, at)
      end
    rescue StandardError
      nil
    end

    def self.ros_type
      @ros_type ||= Asterism::ROS.require_type(LOG_TYPE)
    end

    def self.ros_line(key, bytes, at)
      m = ros_type.decode(bytes)
      stamp = m.stamp.sec * 1000 + m.stamp.nanosec / 1_000_000
      { "at" => stamp.positive? ? stamp : at, "received" => at, "level" => level_name(m.level), "severity" => m.level,
        "name" => text(m.name), "msg" => text(m.msg), "file" => text(m.file), "line" => m.line,
        "function" => text(m.function), "source" => "ros", "domain" => key.split("/").first }
    end

    def self.asterism_line(key, bytes, at)
      require "msgpack"
      v = MessagePack.unpack(bytes)
      v = { "msg" => v.to_s } unless v.is_a?(Hash)
      v = v.transform_keys(&:to_s)
      parts = key.split("/")
      sev = severity(v["level"])
      time = v["time"].is_a?(Numeric) && v["time"].positive? ? (v["time"] * 1000).round : at
      { "at" => time, "received" => at, "level" => level_name(sev), "severity" => sev,
        "name" => text(v["name"] || "#{parts[1]}/#{parts[2]}"), "msg" => text(v["msg"]),
        "file" => text(v["file"]), "line" => v["line"].is_a?(Integer) ? v["line"] : nil,
        "function" => text(v["function"]), "source" => "asterism" }
    end

    # A level as a ROS severity: 10..50, a name ("warn"), else INFO.
    def self.severity(level)
      case level
      when Integer then level
      when String, Symbol then NAMES.fetch(level.to_s.downcase, 20)
      else 20
      end
    end

    def self.level_name(sev)
      LEVELS.fetch(sev) { "L#{sev}" }
    end

    def self.text(v)
      return "" if v.nil?
      s = v.to_s.dup.force_encoding(Encoding::UTF_8)
      s = s.scrub("?") unless s.valid_encoding?
      s.length > MAX_TEXT ? "#{s[0, MAX_TEXT]}..." : s
    end
  end
end
