# One recording in the bridge: an MCAP file (MCAP::Writer, profile "ros2")
# that the subscriptions of the recording write into (Bag::Channels says
# what each channel looks like).
#
#   ros(sample)    a sample of a ROS 2 data key (<domain>/<name>/<type>/<hash>):
#                  the CDR payload as it came; publish_time and sequence from
#                  the rmw_zenoh attachment
#   key(expr, sample)  a sample of an Asterism key (protocol 2, docs/protocol.md
#                  9-12 of the asterism gem): the payload as it came; the
#                  channel's message encoding is the sample's encoding
#                  ("msgpack" when it has none), its schema the topic's
#                  declared type (and the definitions of an application's
#                  own type, Bag::Channels); sequence the attachment's
#                  number, publish_time the sender's time of the attachment,
#                  else the router's timestamp; a channel per run id of the
#                  attachment (a sender that connects again starts a new
#                  channel). The numbers are followed as a reader does
#                  (Asterism::Sequences, per key expression subscribed, per
#                  key and, on a shared place, sender): a gap in a run is
#                  counted as lost, a new run is not; forget drops what is
#                  kept of an application that left
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
    # Values missing from the senders' numbering (lost on the way, or by
    # the sender's own queue), and the new runs seen (a sender connected
    # again, or numbered from an unexpected place).
    attr_reader :gaps, :restarts

    # qos: a block that gives the QoS profiles (Bag::Qos.parse Hashes) of a
    # topic id's publishers, for the channel's offered_qos_profiles.
    # declarations: (key, sender) -> [declaration, {type name => definition}]
    # or nil (Bridge::AppProfiles#topic): what the application declared for
    # the topic on that key (on a shared place's key: what the sender
    # declared, nil sender: none), read when its channel is made.
    def initialize(id:, path:, max_bytes:, max_seconds:, structure: false, clock: nil, wall_ns: nil,
                   declarations: nil, &qos)
      @id = id
      @path = path.to_s
      @max_bytes = max_bytes
      @max_seconds = max_seconds
      @structure = structure
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_ns = wall_ns || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) }
      @qos = qos || ->(_tid) { [] }
      @declarations = declarations || ->(_key, _from) { nil }
      @lock = Mutex.new
      @channels = {} # key => channel id
      @dropped = 0
      @stop_reason = nil
      @graph_snapshot_at = nil
      @lost = -> { 0 }
      @seq_lock = Mutex.new
      @seqs = {} # key expression => Asterism::Sequences
      @gaps = 0
      @restarts = 0
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

    # A sample of an Asterism key (receiving thread). A key whose values
    # change encoding gets a channel per encoding; a shared place's key a
    # channel per sender too (its numbers are the sender's).
    def key(expr, sample)
      key = sample.key.to_s
      enc = Bag::Channels.message_encoding(sample.respond_to?(:encoding) ? sample.encoding : nil)
      seq, run, ms, from = Bag::Channels.attachment(key, sample.attachment)
      count(expr, key, seq, run, from) if seq
      write("key:#{key} #{enc}#{" #{from}" if from}#{" run #{run}" if run}", sample.payload, sample_time(sample)) do
        args = -> { key_channel_args(expr, key, enc, from, run) }
        [ args, ms && ms * 1_000_000, seq ]
      end
    end

    # The application app ("<node>/<app>") left the network: the numbers
    # kept of its values are forgotten (its next value is a first one).
    def forget(app)
      @seq_lock.synchronize { @seqs.each_value { _1.forget(app) } }
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
                      schema: [ Bag::Channels::GRAPH_SCHEMA, "jsonschema", Bag::Channels::GRAPH_JSON_SCHEMA ],
                      metadata: { Bag::Channels::PROTOCOL_KEY => ::Asterism::PROTOCOL.to_s } } }
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
    #   "dropped" (not written: errors), "lost" (dropped by the subscriptions,
    #   and missing from the senders' numbering), "gaps" (the latter alone),
    #   "restarts" (new runs) }
    def progress
      lost = begin
        @lost.call.to_i
      rescue StandardError
        0
      end
      gaps, restarts = @seq_lock.synchronize { [ @gaps, @restarts ] }
      lost += gaps
      @lock.synchronize do
        return { "messages" => 0, "bytes" => 0, "duration_s" => 0, "channel_counts" => {}, "dropped" => @dropped, "lost" => lost, "gaps" => gaps, "restarts" => restarts } unless @writer
        # Summed by topic: a shared place's key has a channel per sender.
        counts = Hash.new(0)
        @writer.channel_counts.each { |cid, n| counts[@writer.channel(cid).topic] += n }
        { "messages" => @writer.message_count, "bytes" => @writer.size, "duration_s" => elapsed.round(2),
          "channel_counts" => counts.to_h, "dropped" => @dropped, "lost" => lost, "gaps" => gaps, "restarts" => restarts }
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

    # Follows the number seq of run id run on a key (from: its sender on a
    # shared place) as a reader of expr does.
    def count(expr, key, seq, run, from)
      app = from
      if app.nil? && !Shared.key?(key)
        parts = key.split("/")
        app = "#{parts[1]}/#{parts[2]}" if parts.size >= 4
      end
      @seq_lock.synchronize do
        lost, restarted = (@seqs[expr] ||= ::Asterism::Sequences.new).see(from ? "#{key}\n#{from}" : key, run, seq, app)
        @gaps += lost
        @restarts += 1 if restarted
      end
    end

    def key_channel_args(expr, key, enc, from = nil, run = nil)
      decl, types = begin
        @declarations.call(key, from)
      rescue StandardError
        nil # not known: an untyped channel
      end
      meta = { "asterism_key_expr" => expr, Bag::Channels::PROTOCOL_KEY => ::Asterism::PROTOCOL.to_s }
      meta[Bag::Channels::FROM_KEY] = from if from
      meta[Bag::Channels::RUN_KEY] = run.to_s if run
      meta[Bag::Channels::DECLARATION_KEY] = JSON.generate(decl) if decl
      { topic: key, message_encoding: enc, schema: Bag::Channels.key_schema(enc, decl, types), metadata: meta }
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
