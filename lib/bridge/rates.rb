# Message rates of ROS 2 topics, like rqt_topic: per topic the rate (Hz)
# and bandwidth over a sliding window, the number of messages, and the time,
# size and a short preview of the last one.
#
# The bridge feeds it every sample of the ROS 2 data keys it subscribes to
# (rmw_zenoh: <domain>/<topic name>/<type>/<type hash>); record runs on the
# receiving thread and only counts and keeps the first PREVIEW_BYTES of the
# last message. The preview is decoded in snapshot, on the main thread,
# and only when a new message came. Memory is bounded: at most MAX_TOPICS
# topics, WINDOW + 1 one-second buckets each, PREVIEW_BYTES per topic.
module Bridge
  class Rates
    WINDOW = 5 # seconds
    MAX_TOPICS = 300
    PREVIEW_BYTES = 4096

    Entry = Struct.new(:tid, :type, :since, :buckets, :count, :at, :size, :last, :fresh, :shown, :preview)

    # The topic of a data key: [topic id, ROS type ("std_msgs/msg/String")],
    # or nil when the key is not one of rmw_zenoh's data keys.
    #   0/chatter/std_msgs::msg::dds_::String_/RIHS01_df66...
    def self.topic_of(key)
      parts = key.to_s.split("/")
      return nil unless parts.size >= 4 && parts[0].match?(/\A\d+\z/) && parts[-2].include?("::")
      [ "r_topic:#{parts[0]}/#{parts[1..-3].join('/')}", Graph.ros_type(parts[-2]) ]
    end

    # Whether a topic id is under one of the key expressions measured
    # (<domain>/** or <domain>/<name>/**).
    def self.covered?(tid, exprs)
      key = tid.delete_prefix("r_topic:")
      exprs.include?("#{key}/**") || exprs.include?("#{key.split('/').first}/**")
    end

    attr_reader :dropped

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   wall: -> { (Time.now.to_f * 1000).round })
      @clock = clock
      @wall = wall
      @lock = Mutex.new
      @topics = {}
      @keys = {} # data key => [topic id, type]
      @dropped = 0 # samples of topics beyond MAX_TOPICS
    end

    def size
      @lock.synchronize { @topics.size }
    end

    def clear
      @lock.synchronize { @topics.clear }
    end

    # Keeps the topics the block says yes to (by topic id).
    def keep_if(&)
      @lock.synchronize { @topics.select! { |tid, _| yield(tid) } }
    end

    # One sample (any thread).
    def record(key, bytes)
      now = @clock.call
      n = bytes.bytesize
      @lock.synchronize do
        # The same few keys come again and again: parsed once each.
        @keys.clear if @keys.size > MAX_TOPICS * 4
        tid, type = (@keys[key] ||= self.class.topic_of(key) || [])
        return false unless tid
        e = @topics[tid]
        unless e
          if @topics.size >= MAX_TOPICS
            @dropped += 1
            return false
          end
          e = @topics[tid] = Entry.new(tid, type, now, Array.new(WINDOW + 1) { [ -1, 0, 0 ] }, 0)
        end
        sec = now.floor
        b = e.buckets[sec % e.buckets.size]
        b[0], b[1], b[2] = sec, 0, 0 unless b[0] == sec
        b[1] += 1
        b[2] += n
        e.count += 1
        e.at = @wall.call
        e.size = n
        e.last = n > PREVIEW_BYTES ? bytes.byteslice(0, PREVIEW_BYTES) : bytes
        e.fresh = true
      end
      true
    end

    # Messages and bytes per second over the window: the last WINDOW
    # one-second buckets, the current one partly (or since the topic was
    # first seen, when that is later). nil until 0.5 s have been seen.
    def self.rate(entry, now)
      sec = now.floor
      first = sec - WINDOW + 1
      span = now - [ first, entry.since ].max
      return [ nil, nil ] if span < 0.5
      msgs = bytes = 0
      entry.buckets.each do |s, c, b|
        next unless s >= first && s <= sec
        msgs += c
        bytes += b
      end
      [ (msgs / span).round(2), (bytes / span).round ]
    end

    # What changed since the last snapshot (all topics with full: true):
    # { topic id => { "hz", "bps", "count", "size", "at", "type", "format", "text" } }.
    def snapshot(full: false)
      now = @clock.call
      out = {}
      @lock.synchronize do
        @topics.each_value do |e|
          hz, bps = self.class.rate(e, now)
          if e.fresh
            e.preview = Payload.describe(e.last.to_s, type: e.type).slice("format", "text")
            e.fresh = false
          end
          row = { "hz" => hz, "bps" => bps, "count" => e.count, "size" => e.size, "at" => e.at,
                  "type" => e.type }.merge(e.preview || {})
          next if !full && row == e.shown
          e.shown = row
          out[e.tid] = row
        end
      end
      out
    end

    # Bytes per second of all topics together (to stop measuring when the
    # bridge would take in too much).
    def total_bps
      now = @clock.call
      @lock.synchronize { @topics.values.sum { self.class.rate(_1, now)[1].to_i } }
    end
  end
end
