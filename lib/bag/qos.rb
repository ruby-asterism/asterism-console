# The QoS of a ROS 2 publisher, from the QoS part of its rmw_zenoh
# liveliness token, written as rosbag2 writes it in a channel's
# "offered_qos_profiles" (YAML, one list entry per publisher).
#
# The token's part (rmw_zenoh 0.2, Jazzy) is
#   <reliability>:<durability>:<history>,<depth>:<deadline s>,<ns>:<lifespan s>,<ns>:<liveliness>,<lease s>,<ns>
# with an empty field for the default (reliable, volatile, keep last 10,
# infinite durations, automatic liveliness), e.g. "::,7:,:,:,," for depth 7.
module Bag
  module Qos
    INFINITE = [ 9_223_372_036, 854_775_807 ].freeze
    RELIABILITY = { "1" => "reliable", "2" => "best_effort" }.freeze
    DURABILITY = { "1" => "transient_local", "2" => "volatile" }.freeze
    HISTORY = { "1" => "keep_last", "2" => "keep_all" }.freeze
    LIVELINESS = { "1" => "automatic", "3" => "manual_by_topic" }.freeze

    module_function

    # A Hash with rosbag2's fields, from a token's QoS part (nil: defaults).
    def parse(text)
      f = text.to_s.split(":", -1)
      hist = f[2].to_s.split(",", -1)
      live = f[5].to_s.split(",", -1)
      {
        "history" => HISTORY.fetch(hist[0].to_s, "keep_last"),
        "depth" => (Integer(hist[1], exception: false) || 10),
        "reliability" => RELIABILITY.fetch(f[0].to_s, "reliable"),
        "durability" => DURABILITY.fetch(f[1].to_s, "volatile"),
        "deadline" => duration(f[3]),
        "lifespan" => duration(f[4]),
        "liveliness" => LIVELINESS.fetch(live[0].to_s, "automatic"),
        "liveliness_lease_duration" => duration(live[1..].to_a.join(","))
      }
    end

    def duration(text)
      sec, nsec = text.to_s.split(",", -1)
      s = Integer(sec.to_s, exception: false)
      n = Integer(nsec.to_s, exception: false)
      return INFINITE if s.nil? && n.nil?
      [ s || 0, n || 0 ]
    end

    # rosbag2's YAML for a list of profiles (Hashes from parse).
    def yaml(profiles, indent = "")
      profiles.map do |p|
        lines = [ "history: #{p['history']}", "depth: #{p['depth']}", "reliability: #{p['reliability']}",
                  "durability: #{p['durability']}", *dur("deadline", p["deadline"]), *dur("lifespan", p["lifespan"]),
                  "liveliness: #{p['liveliness']}", *dur("liveliness_lease_duration", p["liveliness_lease_duration"]),
                  "avoid_ros_namespace_conventions: false" ]
        "#{indent}- " + lines.join("\n#{indent}  ")
      end.join("\n")
    end

    def dur(name, (sec, nsec))
      [ "#{name}:", "  sec: #{sec}", "  nsec: #{nsec}" ]
    end

    # The rmw_zenoh QoS part of a profile (for the playback's publishers):
    # empty fields where the value is the default.
    def token(p)
      rel = p["reliability"] == "best_effort" ? "2" : ""
      dur = p["durability"] == "transient_local" ? "1" : ""
      hist = p["history"] == "keep_all" ? "2" : ""
      "#{rel}:#{dur}:#{hist},#{p['depth'] || 10}:,:,:,,"
    end

    # Profiles back from rosbag2's YAML (only the fields playback needs:
    # history, depth, reliability, durability).
    def from_yaml(text)
      out = []
      text.to_s.each_line do |line|
        if line =~ /\A\s*-\s+(\w+):\s*(\S*)/
          out << {}
          out.last[$1] = $2
        elsif out.any? && line =~ /\A\s+(history|depth|reliability|durability):\s*(\S+)/
          out.last[$1] = $2
        end
      end
      out.each { _1["depth"] = Integer(_1["depth"], exception: false) || 10 }
    end
  end
end
