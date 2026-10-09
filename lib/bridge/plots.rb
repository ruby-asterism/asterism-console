# Numeric fields of messages over time, for the plot page (like rqt_plot).
#
# The bridge subscribes to each plotted target (a ROS 2 topic or an
# Asterism key) while a page has a lease on it (StreamLease) and feeds
# every message to record, on the receiving thread. record only decimates:
# at most RATE messages per target and second are kept (the first of each
# 1/RATE s slot), and at most PENDING wait for the main thread. drain, on
# the main thread, decodes the kept ones once each (the decoder of the
# target: a generated ROS 2 type, or MessagePack) and takes the wanted
# fields out of them. So a 1 kHz topic costs a counter per message and at
# most RATE decodes a second; every field of a target gets at most RATE
# points a second.
#
# Memory: MAX_TARGETS targets, PENDING raw messages each (the bridge
# subscribes to no more), and the points of one drain.
module Bridge
  class Plots
    RATE = 30 # points per second and field, at most
    MAX_TARGETS = 16
    MAX_FIELDS = 32 # per target, from all pages together
    PENDING = 64
    MAX_BYTES = 256 * 1024 # a bigger message is not decoded (counted as too big)
    OBSERVE_EVERY = 2.0 # seconds between looks at the fields a message has

    Target = Struct.new(:id, :decoder, :fields, :steps, :slot, :pending, :received, :kept, :skipped,
                        :errors, :observed, :observed_at, :last_value)

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   wall: -> { (Time.now.to_f * 1000).round })
      @clock = clock
      @wall = wall
      @lock = Mutex.new
      @targets = {}
    end

    def ids
      @lock.synchronize { @targets.keys }
    end

    def size
      @lock.synchronize { @targets.size }
    end

    # Starts (or updates) a target. decoder: bytes -> value (a Hash, a
    # number, ...); it may raise. fields: the paths wanted.
    def set(id, decoder:, fields:)
      @lock.synchronize do
        t = @targets[id]
        if t.nil?
          return false if @targets.size >= MAX_TARGETS
          t = @targets[id] = Target.new(id, decoder, [], [], -1, [], 0, 0, 0, 0, nil, -OBSERVE_EVERY, nil)
        end
        t.decoder = decoder
        take_fields(t, fields)
      end
      true
    end

    # Changes the fields wanted of a target.
    def wanted(id, fields)
      @lock.synchronize { (t = @targets[id]) && take_fields(t, fields) }
    end

    def fields(id)
      @lock.synchronize { @targets[id]&.fields || [] }
    end

    def remove(id)
      @lock.synchronize { @targets.delete(id) }
    end

    def clear
      @lock.synchronize { @targets.clear }
    end

    # One message of a target (any thread). Kept when it is the first of its
    # 1/RATE s slot and there is room; returns whether it was.
    def record(id, bytes)
      now = @clock.call
      @lock.synchronize do
        t = @targets[id]
        return false unless t
        t.received += 1
        slot = (now * RATE).floor
        if slot == t.slot || t.pending.size >= PENDING
          t.skipped += 1
          return false
        end
        t.slot = slot
        t.pending << [ @wall.call, bytes ]
        t.kept += 1
      end
      true
    end

    # Decodes what was kept (main thread) and returns the points:
    #   { id => { "t" => [ms, ...], "v" => { path => [number or nil, ...] },
    #             "received" =>, "kept" =>, "errors" => } }
    # and the targets whose fields (as seen in a message) changed:
    #   { id => [{ "path", "kind" }, ...] }.
    def drain
      work = @lock.synchronize do
        @targets.values.filter_map do |t|
          next if t.pending.empty?
          batch = t.pending
          t.pending = []
          [ t, batch, t.fields, t.steps ]
        end
      end
      points = {}
      observed = {}
      now = @clock.call
      work.each do |t, batch, fields, steps|
        times = []
        values = fields.to_h { [ _1, [] ] }
        batch.each do |at, bytes|
          value = decode(t, bytes)
          next if value.equal?(FAILED)
          t.last_value = value
          times << at
          fields.each_with_index { |f, i| values[f] << Fields.extract(value, steps[i]) }
        end
        if t.last_value && now - t.observed_at >= OBSERVE_EVERY
          t.observed_at = now
          seen = Fields.paths(t.last_value)
          if seen != t.observed
            t.observed = seen
            observed[t.id] = seen
          end
        end
        next if times.empty? && t.errors.zero?
        points[t.id] = { "t" => times, "v" => values, "received" => t.received, "kept" => t.kept, "errors" => t.errors }
      end
      [ points, observed ]
    end

    FAILED = Object.new.freeze

    def take_fields(t, fields)
      list = fields.select { Fields.valid?(_1) }.uniq.first(MAX_FIELDS)
      t.steps = list.map { Fields.parse(_1) }
      t.fields = list
    end

    def decode(t, bytes)
      raise ArgumentError, "#{bytes.bytesize} bytes" if bytes.bytesize > MAX_BYTES
      t.decoder.call(bytes)
    rescue StandardError
      t.errors += 1
      FAILED
    end

    # The decoder of an Asterism key: MessagePack (the object layer's
    # encoding), else text that is a number. MessagePack comes first, so a
    # one-byte text "5" reads as the MessagePack integer 53.
    def self.msgpack_decoder
      lambda do |bytes|
        require "msgpack"
        begin
          MessagePack.unpack(bytes)
        rescue StandardError
          text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
          raise ArgumentError, "not MessagePack" unless text.valid_encoding?
          Float(text.strip)
        end
      end
    end
  end
end
