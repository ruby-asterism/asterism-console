# A few ROS 2 message types read from their CDR bytes (XCDR1 as rmw_zenoh
# sends it: a 4-byte encapsulation header, then the fields aligned to their
# size counted from after the header). Enough for a one-line preview of
# the common small messages; anything else (or anything that does not read
# cleanly) gives nil and the caller shows hex.
module Bridge
  module Cdr
    class Reader
      def initialize(bytes)
        @b = bytes
        @le = bytes.getbyte(1) == 1 # CDR_LE (00 01) or CDR_BE (00 00)
        @pos = 4
      end

      attr_reader :pos

      def rest
        @b.bytesize - @pos
      end

      def align(n)
        @pos += (n - ((@pos - 4) % n)) % n
      end

      def take(n, fmt, align_to = n)
        align(align_to)
        raise ArgumentError, "short" if @pos + n > @b.bytesize
        v = @b.byteslice(@pos, n).unpack1(fmt)
        @pos += n
        v
      end

      def bool = take(1, "C") != 0
      def u8 = take(1, "C")
      def i8 = take(1, "c")
      def u16 = take(2, @le ? "v" : "n")
      def i16 = take(2, @le ? "s<" : "s>")
      def u32 = take(4, @le ? "V" : "N")
      def i32 = take(4, @le ? "l<" : "l>")
      def u64 = take(8, @le ? "Q<" : "Q>")
      def i64 = take(8, @le ? "q<" : "q>")
      def f32 = take(4, @le ? "e" : "g")
      def f64 = take(8, @le ? "E" : "G")

      def string
        len = u32
        raise ArgumentError, "bad string" if len.zero? || len > rest
        s = @b.byteslice(@pos, len - 1).dup.force_encoding(Encoding::UTF_8)
        @pos += len
        raise ArgumentError, "not text" unless s.valid_encoding?
        s
      end

      # std_msgs/Header: builtin_interfaces/Time stamp, string frame_id
      def header
        sec = i32
        nsec = u32
        [ sec + nsec / 1e9, string ]
      end
    end

    NUMBERS = {
      "Bool" => :bool, "Byte" => :u8, "Char" => :u8, "Int8" => :i8, "UInt8" => :u8, "Int16" => :i16,
      "UInt16" => :u16, "Int32" => :i32, "UInt32" => :u32, "Int64" => :i64, "UInt64" => :u64,
      "Float32" => :f32, "Float64" => :f64
    }.freeze

    LEVELS = { 10 => "DEBUG", 20 => "INFO", 30 => "WARN", 40 => "ERROR", 50 => "FATAL" }.freeze

    # Messages that start with a std_msgs/Header: shown by it.
    WITH_HEADER = %w[
      sensor_msgs/msg/Image sensor_msgs/msg/CompressedImage sensor_msgs/msg/CameraInfo sensor_msgs/msg/LaserScan
      sensor_msgs/msg/JointState sensor_msgs/msg/Imu sensor_msgs/msg/PointCloud2 sensor_msgs/msg/BatteryState
      sensor_msgs/msg/Range sensor_msgs/msg/NavSatFix nav_msgs/msg/Odometry nav_msgs/msg/Path
      nav_msgs/msg/OccupancyGrid geometry_msgs/msg/PoseStamped geometry_msgs/msg/TwistStamped
      geometry_msgs/msg/PointStamped geometry_msgs/msg/TransformStamped
    ].freeze

    module_function

    def num(v)
      v.is_a?(Float) ? format("%g", v) : v.to_s
    end

    def vec(r, n = 3)
      "(#{Array.new(n) { num(r.f64) }.join(', ')})"
    end

    # A one-line preview of a CDR message of the given ROS type, or nil.
    def describe(bytes, type)
      r = Reader.new(bytes)
      pkg, kind, name = type.to_s.split("/")
      text =
        if pkg == "std_msgs" && kind == "msg" && NUMBERS[name]
          num(r.public_send(NUMBERS[name]))
        elsif type == "std_msgs/msg/String"
          r.string.inspect
        elsif type == "std_msgs/msg/Empty"
          "(empty)"
        elsif %w[geometry_msgs/msg/Vector3 geometry_msgs/msg/Point].include?(type)
          vec(r)
        elsif type == "geometry_msgs/msg/Quaternion"
          vec(r, 4)
        elsif type == "geometry_msgs/msg/Twist"
          "linear #{vec(r)} angular #{vec(r)}"
        elsif type == "geometry_msgs/msg/Pose2D"
          "x #{num(r.f64)} y #{num(r.f64)} theta #{num(r.f64)}"
        elsif type == "rcl_interfaces/msg/Log"
          r.i32
          r.u32
          level = r.u8
          logger = r.string
          "[#{LEVELS.fetch(level, level)}] #{logger}: #{r.string}"
        elsif type == "sensor_msgs/msg/CompressedImage"
          stamp, frame = r.header
          fmt = r.string
          "stamp #{format('%.3f', stamp)}, frame_id #{frame.inspect}, #{fmt.inspect}, #{r.u32} bytes"
        elsif WITH_HEADER.include?(type)
          stamp, frame = r.header
          "stamp #{format('%.3f', stamp)}, frame_id #{frame.inspect}"
        end
      text
    rescue ArgumentError, RangeError
      nil
    end
  end
end
