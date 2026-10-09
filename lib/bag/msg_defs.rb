# The schema of a ROS 2 topic in an MCAP file: the type's .msg text and
# the .msg texts of every type it uses, concatenated as rosbag2 does
# (schema encoding "ros2msg"):
#
#   <the type's .msg>
#   ================================================================================
#   MSG: geometry_msgs/Vector3
#   <its .msg>
#   ...
#
# Each type's dependencies are taken in sorted order, depth first, every
# type once (rosbag2_cpp's LocalMessageDefinitionSource), so the bytes match
# what `ros2 bag record` writes for the same type.
#
# The .msg files come from vendor/msgdefs (the Jazzy definitions of the
# common packages, see its NOTICE), then from the share directories of a
# ROS 2 install (AMENT_PREFIX_PATH), when there is one. A type that is not
# found gets encoding "unknown" and no text, as rosbag2 writes it.
module Bag
  module MsgDefs
    DIR = File.expand_path("../../vendor/msgdefs", __dir__)
    DELIMITER = "=" * 80
    PRIMITIVES = %w[bool byte char float32 float64 int8 uint8 int16 uint16 int32 uint32 int64 uint64
                    string wstring].freeze
    # pkg/msg/Name or pkg/Name; the name becomes a file path.
    TYPE = %r{\A([a-z][a-z0-9_]*)/(?:msg/)?([A-Z][A-Za-z0-9_]*)\z}

    class NotFound < StandardError; end

    module_function

    def dirs
      ament = ENV["AMENT_PREFIX_PATH"].to_s.split(":").reject(&:empty?).map { File.join(_1, "share") }
      [ DIR, *ament ]
    end

    # [encoding, text] of a type ("geometry_msgs/msg/Twist").
    def schema(type)
      [ "ros2msg", full_text(type) ]
    rescue NotFound
      [ "unknown", "" ]
    end

    def full_text(type)
      root = short(type)
      seen = { root => true }
      append(root, seen)
    end

    def append(name, seen)
      text = msg_text(name)
      out = text.dup
      dependencies(text, name.split("/").first).each do |dep|
        next if seen[dep]
        seen[dep] = true
        out << "\n" << DELIMITER << "\nMSG: " << dep << "\n" << append(dep, seen)
      end
      out
    end

    # "geometry_msgs/msg/Twist" -> "geometry_msgs/Twist"
    def short(type)
      m = TYPE.match(type.to_s) or raise NotFound, "#{type.to_s[0, 80].inspect} is not a message type name"
      "#{m[1]}/#{m[2]}"
    end

    def msg_text(name)
      pkg, base = name.split("/")
      dirs.each do |d|
        path = File.join(d, pkg, "msg", "#{base}.msg")
        return File.read(path, mode: "rb").force_encoding(Encoding::UTF_8) if File.file?(path)
      end
      raise NotFound, "no definition of #{name}"
    end

    # The message types a .msg uses (sorted, each once), as pkg/Name.
    def dependencies(text, pkg)
      deps = {}
      text.each_line do |line|
        line = line.sub(/#.*/, "").strip
        next if line.empty?
        type, rest = line.split(/\s+/, 2)
        next if rest.nil? || rest.match?(/\A[A-Za-z0-9_]+\s*=/) # a constant
        type = type.sub(/\[.*\]\z/, "").sub(/<=\d+\z/, "")
        next if PRIMITIVES.include?(type)
        parts = type.split("/")
        dep = case parts.size
        when 1 then type == "Header" ? "std_msgs/Header" : "#{pkg}/#{type}"
        when 2 then type
        when 3 then "#{parts[0]}/#{parts[2]}"
        end
        deps[dep] = true if dep
      end
      deps.keys.sort
    end
  end
end
