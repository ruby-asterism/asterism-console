# A recording as the timeline page reads it (like rqt_bag): its channels,
# the message ticks of each, the message of a channel at a time, a numeric
# field over the whole recording, and the network structure at a time.
#
# Opening reads the summary and the message index (MCAP::Reader#index:
# times and offsets only, from the message index records, or one scan of a
# file without them); messages are read one by one when asked for. The
# views of the last few files are kept (CACHE_SIZE), keyed by path, size
# and modification time, so a page's requests do not read the index again.
#
# Times are nanoseconds since the epoch (the log time), as in the file.
module Bag
  class View
    CACHE_SIZE = 4
    MAX_BUCKETS = 2000
    MAX_POINTS = 5000 # per series (evenly spaced messages when there are more)
    @cache = {}
    @lock = Mutex.new

    class << self
      def open(path)
        path = path.to_s
        st = File.stat(path)
        key = [ path, st.size, st.mtime.to_f ]
        @lock.synchronize do
          v = @cache.delete(key) || new(path)
          @cache[key] = v
          @cache.delete(@cache.keys.first)&.close while @cache.size > CACHE_SIZE
          v
        end
      end

      def forget(path)
        @lock.synchronize do
          @cache.keys.select { _1[0] == path.to_s }.each { @cache.delete(_1)&.close }
        end
      end
    end

    attr_reader :reader

    def initialize(path)
      @path = path
      @reader = MCAP::Reader.new(path)
      @lock = Mutex.new # one IO, several Puma threads
    end

    def close
      @reader.close
    end

    def sync(&) = @lock.synchronize(&)

    def info
      @info ||= sync { @reader.info }
    end

    # The channels with what kind each is: "ros" (cdr), "key" (msgpack),
    # "graph" (the network structure), "other".
    def channels
      @channels ||= info["channels"].map do |c|
        kind = if Channels.graph?(c) then "graph"
        elsif Channels.ros?(c) then "ros"
        elsif Channels.msgpack?(c) then "key"
        else "other"
        end
        c.merge("kind" => kind, "type" => kind == "ros" ? c["schema"] : nil)
      end
    end

    def channel(id) = channels.find { _1["id"] == id.to_i }

    def index
      @index ||= sync { @reader.index }
    end

    def start_ns = info["start"]
    def end_ns = info["end"]

    # Message counts per time bucket of every channel:
    #   { "start", "end", "buckets", "channels" => { id => [count, ...] } }
    def ticks(buckets = 600)
      n = buckets.to_i.clamp(10, MAX_BUCKETS)
      t0 = start_ns || 0
      span = [ (end_ns || t0) - t0, 1 ].max
      out = index.to_h do |cid, list|
        counts = Array.new(n, 0)
        list.each { |t, _| counts[[ ((t - t0) * n / span), n - 1 ].min] += 1 }
        [ cid, counts ]
      end
      { "start" => start_ns, "end" => end_ns, "buckets" => n, "channels" => out }
    end

    # The last message of a channel at or before t (the first one when t is
    # before it), decoded:
    #   { "channel", "index" (its number), "count", "log_time", "publish_time",
    #     "sequence", "prev" / "next" (times of its neighbours), and Decode.message's fields }
    def message(channel_id, t)
      list = index[channel_id.to_i] || []
      return nil if list.empty?
      i = position(list, t.to_i)
      at, ref = list[i]
      c = channel(channel_id)
      base = { "channel" => channel_id.to_i, "index" => i, "count" => list.size, "log_time" => at,
               "prev" => i.positive? ? list[i - 1][0] : nil, "next" => list[i + 1]&.first }
      m = begin
        sync { @reader.message_at(ref) }
      rescue MCAP::UnsupportedCompression => e
        return base.merge("error" => e.message)
      end
      base.merge("publish_time" => m.publish_time, "sequence" => m.sequence)
          .merge(Decode.message(c, c["schema"], m.data, at / 1_000_000))
    end

    # The message of every channel at t (one line each, for the list beside
    # the timeline).
    def at(t)
      channels.reject { _1["kind"] == "graph" }.to_h do |c|
        m = message(c["id"], t)
        [ c["id"], m && m.slice("log_time", "index", "count", "text", "error", "format", "log") ]
      end
    end

    # The numeric paths of a channel: from its type (ROS 2) and from its
    # first messages.
    def fields(channel_id)
      c = channel(channel_id) or return []
      out = []
      if c["kind"] == "ros"
        begin
          out.concat(Bridge::Types.fields(Bridge::Types.ros(c["schema"])))
        rescue Bridge::Types::Unknown
          nil
        end
      end
      dec = decoder(c)
      (index[c["id"]] || []).first(3).each do |_, ref|
        v = dec.call(sync { @reader.message_at(ref) }.data)
        Bridge::Fields.paths(v).each { |p| out << p unless out.any? { _1["path"] == p["path"] } }
      rescue StandardError
        next
      end
      out
    end

    # A field over the recording: { "t" => [ms, ...], "v" => { path => [...] },
    # "messages", "used", "errors" }. At most max_points messages are read
    # (evenly spaced).
    def series(channel_id, paths, max_points: MAX_POINTS)
      c = channel(channel_id) or raise ArgumentError, "no channel #{channel_id}"
      steps = paths.map { Bridge::Fields.parse(_1) }
      raise ArgumentError, "not a path: #{paths[steps.index(nil)]}" if steps.include?(nil)
      dec = decoder(c) or raise ArgumentError, "#{c['message_encoding']} messages have no fields"
      list = index[c["id"]] || []
      stride = [ (list.size.to_f / max_points).ceil, 1 ].max
      t = []
      v = paths.to_h { [ _1, [] ] }
      errors = 0
      list.each_slice(stride) do |(at, ref), *|
        value = dec.call(sync { @reader.message_at(ref) }.data)
        t << at / 1_000_000.0
        paths.each_with_index { |p, i| v[p] << Bridge::Fields.extract(value, steps[i]) }
      rescue MCAP::UnsupportedCompression
        raise
      rescue StandardError
        errors += 1
      end
      { "t" => t, "v" => v, "messages" => list.size, "used" => t.size, "errors" => errors }
    end

    # The network structure: the channel and the times of its messages (each
    # a change), or nil when the recording has none.
    def graph_channel = channels.find { _1["kind"] == "graph" }

    def graph_times
      c = graph_channel or return []
      (index[c["id"]] || []).map(&:first)
    end

    # Every change of the network structure, in order, described:
    #   [{ "at", "kind" ("snapshot" / "diff"), "added" => [labels], "removed" => [labels], "changed" => n,
    #      "nodes" => n }]
    # Labels are "<kind> <label>" ("r_node /listener"); a snapshot after the
    # first is compared with the graph before it, so it lists what changed too.
    def graph_changes(limit: 2000)
      c = graph_channel or return []
      graph = nil
      label = ->(n) { "#{n['kind']} #{n['label']}" }
      (index[c["id"]] || []).first(limit).map do |at, ref|
        m = JSON.parse(sync { @reader.message_at(ref) }.data)
        before = graph
        graph = m["kind"] == "snapshot" ? m["graph"] : (graph && self.class.apply(graph, m["diff"] || {}))
        old = (before || {})["nodes"].to_a.to_h { [ _1["id"], _1 ] }
        now = (graph || {})["nodes"].to_a.to_h { [ _1["id"], _1 ] }
        { "at" => at, "kind" => m["kind"], "version" => m["version"],
          "added" => before ? (now.keys - old.keys).map { label.(now[_1]) } : [],
          "removed" => (old.keys - now.keys).map { label.(old[_1]) },
          "changed" => now.count { |id, n| old[id] && old[id] != n }, "nodes" => now.size }
      rescue JSON::ParserError
        { "at" => at, "kind" => "unreadable" }
      end
    end

    # The graph as it was at t: the last snapshot at or before t with the
    # diffs after it applied. { "graph", "version", "at" (the change it
    # shows), "index", "count", "prev", "next" }, or nil.
    def graph_at(t)
      c = graph_channel or return nil
      list = index[c["id"]] || []
      return nil if list.empty?
      i = position(list, t.to_i)
      msgs = sync do
        j = i
        out = []
        loop do
          m = JSON.parse(@reader.message_at(list[j][1]).data)
          out.unshift(m)
          break if m["kind"] == "snapshot" || j.zero?
          j -= 1
        end
        out
      end
      graph = nil
      version = nil
      msgs.each do |m|
        if m["kind"] == "snapshot"
          graph = m["graph"]
        elsif graph
          graph = self.class.apply(graph, m["diff"] || {})
        end
        version = m["version"]
      end
      return nil unless graph
      { "graph" => graph, "version" => version, "at" => list[i][0], "index" => i, "count" => list.size,
        "prev" => i.positive? ? list[i - 1][0] : nil, "next" => list[i + 1]&.first }
    end

    # Bridge::Graph.diff applied to a graph (to_h form).
    def self.apply(graph, diff)
      out = {}
      %w[nodes edges].each do |part|
        h = graph[part].to_a.to_h { [ _1["id"], _1 ] }
        diff["remove_#{part}"].to_a.each { h.delete(_1) }
        (diff["add_#{part}"].to_a + diff["change_#{part}"].to_a).each { h[_1["id"]] = _1 }
        out[part] = h.keys.sort.map { h[_1] }
      end
      out
    end

    private

    def decoder(c)
      Decode.decoder(c, c["schema"])
    rescue Bridge::Types::Unknown
      nil
    end

    # The index of the last entry at or before t (0 when t is before all).
    def position(list, t)
      i = list.bsearch_index { |at, _| at > t }
      i.nil? ? list.size - 1 : [ i - 1, 0 ].max
    end
  end
end
