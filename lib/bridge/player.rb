# Plays a recording back onto the network (a Playback row), on a thread of
# its own: the messages in log-time order, each at its recorded time from
# the start divided by speed.
#
#   ROS 2 channels (cdr): through an Asterism::ROS::Node of the console
#     ("asterism_console_playback", one per domain), with a publisher per
#     topic. It declares the node's and the publishers' liveliness tokens
#     (so `ros2 topic list` / `ros2 topic echo` see them), and each message
#     goes out with a new rmw_zenoh attachment: the publisher's sequence
#     number, the time it is sent and the console's GID (from its token).
#     The type name and hash come from the channel: its schema name and its
#     topic_type_hash (rosbag2 writes it too), else the bundled type's hash.
#   Asterism keys (msgpack): put on the recorded key as they are.
#   The network structure (and anything else): not sent.
#
# The payloads are sent as recorded (the CDR bytes are not decoded), so a
# topic of any type plays, bundled or not. Stopping (stop) ends it between
# two messages.
module Bridge
  class Player
    NODE_NAME = "asterism_console_playback"
    # Time for the subscribers to see the new publishers before the first message.
    DISCOVERY_WAIT = 1.0
    STEP = 0.05

    # A type for Asterism::ROS::Publisher that passes the recorded bytes through.
    def self.raw_type(type_name, type_hash)
      Module.new do
        const_set(:TYPE_NAME, type_name)
        const_set(:TYPE_HASH, type_hash)
        const_set(:ROS_NAME, type_name)
        def self.encode(bytes) = bytes
      end
    end

    attr_reader :sent, :skipped, :error

    # session: an Asterism::Zenoh::Session (the bridge's), put: how an
    # Asterism key's payload is put (key, bytes).
    def initialize(playback_id:, path:, speed:, channel_ids: [], start_ns: nil, session:, put:, logger: nil)
      @id = playback_id
      @path = path.to_s
      @speed = speed.to_f
      @want = channel_ids.map(&:to_i)
      @start_ns = start_ns
      @session = session
      @put = put
      @log = logger
      @sent = 0
      @skipped = {} # channel topic => why
      @error = nil
      @stop = false
      @nodes = {}
      @publishers = {}
    end

    def start
      @thread = Thread.new { run }
      self
    end

    def stop
      @stop = true
    end

    def alive? = @thread&.alive?
    def stopped? = @stop

    def join(limit = nil)
      @thread&.join(limit)
    end

    # The whole playback (the thread's body; the tests call it directly).
    def run
      reader = MCAP::Reader.new(@path)
      events = plan(reader)
      prepare(reader)
      wait(DISCOVERY_WAIT) unless @publishers.empty?
      play(reader, events)
    rescue StandardError => e
      @error = "#{e.class}: #{e.message}"
      @log&.call("bridge: playback #{@id}: #{@error}")
    ensure
      reader&.close
      close
    end

    private

    # [[log_time, channel id, ref], ...] in time order, of the channels to send.
    def plan(reader)
      chosen = reader.channels.values.select { |c| @want.empty? || @want.include?(c.id) }
      chosen.each do |c|
        @skipped[c.topic] = "the network structure is not sent" if c.message_encoding == "json" && c.topic == Bag::Channels::GRAPH_TOPIC
        @skipped[c.topic] ||= "#{c.message_encoding} messages are not sent" unless %w[cdr msgpack].include?(c.message_encoding)
      end
      ids = chosen.map(&:id).reject { |id| @skipped.key?(reader.channels[id].topic) }
      idx = reader.index
      events = ids.flat_map { |cid| (idx[cid] || []).map { |t, ref| [ t, cid, ref ] } }
      events.select! { _1[0] >= @start_ns } if @start_ns
      events.sort_by! { _1[0] }
      events
    end

    def prepare(reader)
      reader.channels.each_value do |c|
        next unless c.message_encoding == "cdr" && !@skipped.key?(c.topic)
        next if @want.any? && !@want.include?(c.id)
        schema = reader.schemas[c.schema_id]
        type = schema&.name.to_s
        hash = c.metadata["topic_type_hash"].to_s
        hash = bundled_hash(type) if hash.empty?
        dds = Bag::Channels.dds_type(type)
        if dds.nil? || hash.to_s.empty?
          @skipped[c.topic] = "type #{type.inspect} has no type hash (the channel has no topic_type_hash and the type is not bundled)"
          next
        end
        domain = Integer(c.metadata["ros_domain"] || 0, exception: false) || 0
        qos = Bag::Qos.from_yaml(c.metadata["offered_qos_profiles"]).first || Bag::Qos.parse(nil)
        node = (@nodes[domain] ||= ::Asterism::ROS::Node.new(@session, NODE_NAME, domain: domain))
        @publishers[c.id] = node.publisher(c.topic, self.class.raw_type(dds, hash), qos: Bag::Qos.token(qos))
      end
    end

    def bundled_hash(type)
      Types.ros(type)::TYPE_HASH
    rescue Types::Unknown
      nil
    end

    def play(reader, events)
      return if events.empty?
      t0 = mono
      first = events[0][0]
      events.each do |t, cid, ref|
        break if @stop
        due = t0 + (t - first) / 1e9 / @speed
        wait(due - mono)
        break if @stop
        next if @skipped.key?(reader.channels[cid].topic)
        m = reader.message_at(ref)
        if (pub = @publishers[cid])
          pub.publish(m.data)
        else
          @put.call(reader.channels[cid].topic, m.data)
        end
        @sent += 1
      end
    end

    def wait(seconds)
      t = mono + seconds
      while !@stop && (left = t - mono) > 0
        sleep [ left, STEP ].min
      end
    end

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def close
      @publishers.each_value { _1.close rescue nil }
      @nodes.each_value { _1.close rescue nil }
      @publishers.clear
      @nodes.clear
    end
  end
end
