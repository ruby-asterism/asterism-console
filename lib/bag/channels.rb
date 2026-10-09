# How the console's recordings name and describe their channels, shared by
# the recorder (bridge), the timeline (pages) and the playback:
#
#   ROS 2 topic      topic "/cmd_vel", message encoding "cdr", schema
#                    <type> / "ros2msg" (Bag::MsgDefs), metadata as rosbag2
#                    writes it (offered_qos_profiles, topic_type_hash) plus
#                    ros_domain
#   Asterism key     topic = the key ("demo-node/sensors/imu"), message
#                    encoding "msgpack", schema "asterism/msgpack" with
#                    encoding "" (none: MessagePack carries no schema),
#                    metadata asterism_key_expr (what was subscribed)
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
  end
end
