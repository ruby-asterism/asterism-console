# One recording in the bridge: an MCAP file (MCAP::Writer, profile "ros2")
# that the subscriptions of the recording write into (Bag::Channels says
# what each channel looks like).
#
#   ros(sample)    a sample of a ROS 2 data key (<domain>/<name>/<type>/<hash>):
#                  the CDR payload as it came; publish_time and sequence from
#                  the rmw_zenoh attachment
#   key(expr, sample)  a sample of an Asterism key: the payload as it came;
#                  publish_time from the sample's Zenoh timestamp, when it has one
#   graph(...)     the network structure: a snapshot when the recording starts
#                  and every SNAPSHOT_EVERY seconds of changes, a diff on
#                  every change in between
#
# ros and key run on the receiving thread, graph on the main one; a mutex
# keeps the writer to one at a time. log_time is the time the bridge got the
# message (wall clock, ns). Writing stops at the size limit (the message
# that would pass it is not written) and the main thread stops the
# recording at the time limit (Runner#sync_recordings), so a recording is
# never bigger than max_bytes plus the summary.
module Bridge
  class Recorder
    SNAPSHOT_EVERY = 30.0 # seconds
    FLUSH_EVERY = 1.0 # a chunk at least this often, so a crash loses at most this much

    attr_reader :id, :path, :stop_reason, :dropped
    # How many samples the subscriptions dropped before the recorder saw
    # them (their queues were full): set by the runner.
    attr_writer :lost

    # qos: a block that gives the QoS profiles (Bag::Qos.parse Hashes) of a
    # topic id's publishers, for the channel's offered_qos_profiles.
    def initialize(id:, path:, max_bytes:, max_seconds:, structure: false, clock: nil, wall_ns: nil, &qos)
      @id = id
      @path = path.to_s
      @max_bytes = max_bytes
      @max_seconds = max_seconds
      @structure = structure
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_ns = wall_ns || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) }
      @qos = qos || ->(_tid) { [] }
      @lock = Mutex.new
      @channels = {} # key => channel id
      @dropped = 0
      @stop_reason = nil
      @graph_snapshot_at = nil
      @lost = -> { 0 }
    end

    def open
      FileUtils.mkdir_p(File.dirname(@path))
      @file = File.open(@path, "wb")
      @writer = MCAP::Writer.new(@file, profile: "ros2", library: "asterism-console #{MCAP::VERSION}")
      @started = @clock.call
      @last_flush = @started
      self
    end

    def structure? = @structure

    def elapsed = @clock.call - @started

    # The reason the recording has to stop, or nil.
    def limit_reached
      return @stop_reason if @stop_reason
      @lock.synchronize { @stop_reason ||= "time limit (#{@max_seconds} s) reached" } if elapsed >= @max_seconds
      @stop_reason
    end

    # A ROS 2 data sample (receiving thread).
    def ros(sample)
      key = sample.key.to_s
      tid, type = Rates.topic_of(key)
      return false unless tid
      write(key, sample.payload, sample_time(sample)) do
        att = ::Asterism::ROS::Attachment.decode(sample.attachment) if sample.attachment
        domain, name = tid.delete_prefix("r_topic:").split("/", 2)
        [ -> { ros_channel_args(tid, "/#{name}", domain, type, key.split("/").last) }, att&.stamp_ns, att&.sequence ]
      end
    end

    # A sample of an Asterism key (receiving thread).
    def key(expr, sample)
      write("key:#{sample.key}", sample.payload, sample_time(sample)) do
        args = -> { { topic: sample.key.to_s, message_encoding: "msgpack",
                      schema: [ Bag::Channels::MSGPACK_SCHEMA, "", "" ], metadata: { "asterism_key_expr" => expr } } }
        [ args, nil, nil ]
      end
    end

    # The network structure (main thread): the whole graph when there is no
    # snapshot yet or the last is SNAPSHOT_EVERY old, else the diff.
    def graph(version, graph, diff = nil)
      return false unless @structure
      now = @clock.call
      snap = diff.nil? || @graph_snapshot_at.nil? || now - @graph_snapshot_at >= SNAPSHOT_EVERY
      body = if snap
        @graph_snapshot_at = now
        { "kind" => "snapshot", "version" => version, "graph" => graph }
      else
        { "kind" => "diff", "version" => version, "diff" => diff }
      end
      write("graph", JSON.generate(body), nil) do
        args = -> { { topic: Bag::Channels::GRAPH_TOPIC, message_encoding: "json",
                      schema: [ Bag::Channels::GRAPH_SCHEMA, "jsonschema", Bag::Channels::GRAPH_JSON_SCHEMA ], metadata: {} } }
        [ args, nil, nil ]
      end
    end

    # Writes the open chunk now and then (main thread).
    def tick
      now = @clock.call
      return if now - @last_flush < FLUSH_EVERY
      @last_flush = now
      @lock.synchronize { @writer&.flush }
    end

    # { "messages", "bytes", "duration_s", "channel_counts" => { topic => n },
    #   "dropped" (not written: errors), "lost" (dropped by the subscriptions) }
    def progress
      lost = begin
        @lost.call.to_i
      rescue StandardError
        0
      end
      @lock.synchronize do
        return { "messages" => 0, "bytes" => 0, "duration_s" => 0, "channel_counts" => {}, "dropped" => @dropped, "lost" => lost } unless @writer
        counts = @writer.channel_counts.to_h { |cid, n| [ @writer.channel(cid).topic, n ] }
        { "messages" => @writer.message_count, "bytes" => @writer.size, "duration_s" => elapsed.round(2),
          "channel_counts" => counts, "dropped" => @dropped, "lost" => lost }
      end
    end

    # Ends the file (summary and footer) and closes it. Returns the progress.
    def finish(reason = nil)
      @lock.synchronize do
        @stop_reason ||= reason
        if @writer && !@writer.finished?
          @writer.finish
          @file.close
        end
      end
      progress
    end

    def finished? = @writer.nil? || @writer.finished?

    private

    def sample_time(sample)
      ts = sample.respond_to?(:timestamp) ? sample.timestamp : nil
      return nil unless ts
      t = ts.to_time
      t.to_i * 1_000_000_000 + t.nsec
    rescue StandardError
      nil
    end

    # Writes one message; the block gives [a lambda for the channel's args
    # (called once per channel), publish_time, sequence].
    def write(chan_key, payload, zenoh_time)
      log_time = @wall_ns.call
      data = payload.to_s.b
      @lock.synchronize do
        return false if @writer.nil? || @writer.finished? || @stop_reason
        if @clock.call - @started >= @max_seconds
          @stop_reason = "time limit (#{@max_seconds} s) reached"
          return false
        end
        # A message and its record: 31 bytes, the message index 16.
        if @writer.size + data.bytesize + 64 > @max_bytes
          @stop_reason = "size limit (#{@max_bytes / Recording::MB} MB) reached"
          return false
        end
        args, pub_time, seq = yield
        cid = (@channels[chan_key] ||= add_channel(args.call))
        @writer.add_message(channel_id: cid, log_time: log_time, publish_time: pub_time || zenoh_time || log_time,
                            sequence: seq.to_i, data: data)
      end
      true
    rescue StandardError => e
      @dropped += 1
      Rails.logger.warn("recorder #{@id}: #{e.class}: #{e.message}")
      false
    end

    def add_channel(args)
      name, enc, data = args[:schema]
      sid = @writer.add_schema(name: name, encoding: enc, data: data)
      @writer.add_channel(topic: args[:topic], message_encoding: args[:message_encoding], schema_id: sid,
                          metadata: args[:metadata])
    end

    def ros_channel_args(tid, name, domain, type, hash)
      enc, text = Bag::MsgDefs.schema(type)
      profiles = @qos.call(tid)
      profiles = [ Bag::Qos.parse(nil) ] if profiles.empty?
      { topic: name, message_encoding: "cdr", schema: [ type, enc, text ],
        metadata: { "offered_qos_profiles" => Bag::Qos.yaml(profiles), "topic_type_hash" => hash, "ros_domain" => domain } }
    end
  end
end
