# How the console's recordings name and describe their channels, shared by
# the recorder (bridge), the timeline (pages) and the playback:
#
#   ROS 2 topic      topic "/cmd_vel", message encoding "cdr", schema
#                    <type> / "ros2msg" (Bag::MsgDefs), metadata as rosbag2
#                    writes it (offered_qos_profiles, topic_type_hash) plus
#                    ros_domain
#   Asterism key     topic = the key ("asterism/demo-node/sensors/imu"),
#                    message encoding the values' Zenoh encoding
#                    ("image/jpeg"), "msgpack" when they have none (protocol
#                    2: MessagePack goes without one); the schema from the
#                    topic's declaration (asterism/<node>/<app>/@pubs, when
#                    the application declared it):
#                      a built-in type   "asterism/<its name>" ("asterism/vector3"),
#                                        encoding "" (the protocol's table)
#                      its own type      the type's name ("asterism-games/board.strokes"),
#                                        encoding "asterism/types", data the JSON
#                                        {name => {"f" => [[field, type], ...], "d"}}
#                                        of it and the types its fields name
#                                        (encoding "" and no data when the
#                                        definition was not told)
#                      no type           "asterism/msgpack" (MessagePack), else
#                                        "asterism/untyped", encoding ""
#                    metadata asterism_key_expr (what was subscribed),
#                    asterism_protocol (the wire protocol the console spoke:
#                    "2"; "1" before; a recording without it was made with
#                    protocol 0, before asterism 0.7.0, and its Asterism
#                    channels are not read) and asterism_declaration (the
#                    topic's declaration as JSON: "t", "e", "u", "d", "ts").
#                    A message's sequence is the number of its attachment,
#                    its publish_time the sender's time of the attachment
#                    (ms; topics declared with "ts"), else the router's
#                    timestamp, else the log time.
#                    A key of a shared place (Bridge::Shared:
#                    asterism/<node>/@shared/..., asterism/@shared/...) may
#                    have several senders, each numbering its own values
#                    (attachment [seq, id, ms or nil, "<node>/<app>"]): it
#                    gets a channel per key and sender, the same topic, the
#                    sender in the metadata asterism_from, the schema and
#                    asterism_declaration from that sender's declaration
#                    and definitions.
#                    Every value's attachment has the run id of its
#                    sender's connection ([seq, id], [seq, id, ms]): a new
#                    id is a new run (the sender connected again), whose
#                    numbers start again from 0. A run gets a channel of
#                    its own (the same topic, the id in the metadata
#                    asterism_run), so a channel's sequence numbers are one
#                    run's and go up one by one: a gap in them is a value
#                    lost, and a restart is a new channel, not a gap
#   the network      topic "/asterism/graph", message encoding "json",
#                    schema "asterism/graph" (a JSON Schema): snapshots and
#                    diffs of the console's graph (Bridge::Graph)
#
# The Asterism channels have a schema record (not schema id 0) because
# rosbag2 refuses a file with a channel it finds no schema for ("Could not
# find schema for topic"); with one, `ros2 bag info` lists them by that name.
module Bag
  module Channels
    GRAPH_TOPIC = "/asterism/graph"
    MSGPACK_SCHEMA = "asterism/msgpack"
    UNTYPED_SCHEMA = "asterism/untyped"
    # The schema encoding of an application's own type (JSON definitions).
    TYPES_ENCODING = "asterism/types"
    # The channel metadata with the topic's declaration (JSON).
    DECLARATION_KEY = "asterism_declaration"
    # The channel metadata with the sender of a shared place's key
    # ("<node>/<app>").
    FROM_KEY = "asterism_from"
    # The channel metadata with the run id of the values (the sender's
    # connection, as a decimal string): a run has a channel of its own.
    RUN_KEY = "asterism_run"
    # The built-in types by number (docs/protocol.md 11 of the asterism gem).
    BUILTIN_TYPES = %w[number vector3 pose image state log text].freeze
    # The highest sequence number (it goes back to 0 after it).
    SEQ_MAX = 2_147_483_647
    # The channel metadata saying which Asterism wire protocol the console
    # recorded with (docs/protocol.md of the asterism gem).
    PROTOCOL_KEY = "asterism_protocol"
    GRAPH_SCHEMA = "asterism/graph"
    GRAPH_JSON_SCHEMA = JSON.generate(
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "title" => "Asterism network structure",
      "description" => "A snapshot of the console's graph, or the diff from the message before",
      "type" => "object",
      "properties" => {
        "kind" => { "enum" => %w[snapshot diff] },
        "version" => { "type" => "integer" },
        "graph" => { "type" => "object", "properties" => { "nodes" => { "type" => "array" }, "edges" => { "type" => "array" } } },
        "diff" => { "type" => "object" }
      },
      "required" => %w[kind]
    )

    module_function

    # rmw_zenoh's DDS type name: geometry_msgs/msg/Twist -> geometry_msgs::msg::dds_::Twist_
    def dds_type(type)
      pkg, kind, name = type.to_s.split("/")
      return nil unless pkg && kind && name
      "#{pkg}::#{kind}::dds_::#{name}_"
    end

    def ros?(channel) = channel["message_encoding"] == "cdr"
    def graph?(channel) = channel["topic"] == GRAPH_TOPIC && channel["message_encoding"] == "json"
    def msgpack?(channel) = channel["message_encoding"] == "msgpack"

    # An Asterism key's channel: MessagePack, or another encoding recorded
    # from a key (protocol 2: a JPEG topic).
    def key?(channel)
      msgpack?(channel) || (!graph?(channel) && channel.dig("metadata", "asterism_key_expr").to_s != "")
    end

    # The message encoding of a sample's Zenoh encoding: "msgpack" for none
    # (Zenoh's default, zenoh/bytes), else the encoding as it is.
    def message_encoding(zenoh_encoding)
      e = zenoh_encoding.to_s
      e.empty? || e == "zenoh/bytes" ? "msgpack" : e
    end

    # [sequence number, run id, sender's time in ms, sender] of an Asterism
    # attachment on key (Asterism.read_attachment: [seq, id], [seq, id, ms]
    # or, on a shared place, [seq, id, ms or nil, "<node>/<app>"] in
    # MessagePack; the sender is read on a shared place's key only), each
    # nil when it is not there; [nil, nil, nil, nil] without a number.
    def attachment(key, bytes)
      none = [ nil, nil, nil, nil ]
      return none if bytes.nil? || bytes.empty?
      require "asterism"
      place, node, = Bridge::Shared.key_place(key)
      ::Asterism.read_attachment(bytes.to_s.b, place, node) || none
    rescue StandardError
      none
    end

    # The sender a key channel was recorded for (a shared place's), or nil.
    def from(channel)
      Bridge::Shared.sender(channel.dig("metadata", FROM_KEY))
    end

    # The run id a key channel was recorded for, or nil (values without
    # one, or a recording made before run ids).
    def run(channel)
      s = channel.dig("metadata", RUN_KEY).to_s
      s.match?(/\A\d{1,10}\z/) ? s.to_i : nil
    end

    # [name, encoding, data] of a key channel's schema (above): enc the
    # message encoding, decl the topic's declaration (or nil), types the
    # definitions of the types it names.
    def key_schema(enc, decl, types)
      t = decl && decl["t"]
      case t
      when Integer
        [ "asterism/#{t.between?(1, BUILTIN_TYPES.size) ? BUILTIN_TYPES[t - 1] : "type-#{t}"}", "", "" ]
      when String
        types.to_h.key?(t) ? [ t, TYPES_ENCODING, JSON.generate(types) ] : [ t, "", "" ]
      else
        [ enc == "msgpack" ? MSGPACK_SCHEMA : UNTYPED_SCHEMA, "", "" ]
      end
    end

    # The declaration a key channel was recorded with ({} when none).
    def declaration(channel)
      text = channel.dig("metadata", DECLARATION_KEY).to_s
      text.empty? ? {} : JSON.parse(text)
    rescue JSON::ParserError
      {}
    end

    # An Asterism channel (a key, or the network structure) recorded before
    # protocol 1: no asterism_protocol in its metadata.
    def protocol0?(channel)
      return false unless msgpack?(channel) || graph?(channel)
      channel.dig("metadata", PROTOCOL_KEY).to_s.empty?
    end

    PROTOCOL0_NOTE = "recorded with Asterism protocol 0 (before asterism 0.7.0): this console reads " \
                     "protocol 1 and 2 recordings only".freeze
  end
end
