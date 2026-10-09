# Numeric fields of a decoded message, by path (for the plots, like
# rqt_plot's "/imu/linear_acceleration/z"):
#
#   linear.x                    a field of a nested message (or Hash key)
#   orientation_covariance[4]   an element of an array or sequence
#   poses[0].pose.position.x    both
#   ""                          the whole value (a payload that is a number)
#
# A value is a decoded ROS 2 message as a Hash (Message#to_h: nested
# messages are Hashes, arrays are Arrays) or a MessagePack value (an
# Asterism key). Numbers are Integers and Floats; true / false count as 1 / 0.
module Bridge
  module Fields
    # How many paths `paths` lists at most, and how many elements of an
    # array it names (a 1000-element sequence is not 1000 choices).
    MAX_PATHS = 200
    MAX_INDEX = 16
    MAX_PATH = 120
    # One path step: a name (anything but . [ ] and blanks) or [index].
    SEGMENT = /\A[^.\[\]\s]+\z/

    module_function

    # The steps of a path ["linear", "x"], ["covariance", 4]; nil when the
    # path is not one.
    def parse(path)
      path = path.to_s
      return [] if path.empty?
      return nil if path.bytesize > MAX_PATH
      steps = []
      path.split(".", -1).each do |part|
        name, *idx = part.split("[")
        return nil if name.nil? || (name.empty? && steps.empty? && idx.empty?)
        unless name.empty?
          return nil unless SEGMENT.match?(name)
          steps << name
        end
        idx.each do |i|
          return nil unless i.match?(/\A\d{1,6}\]\z/)
          steps << i.to_i
        end
      end
      steps.empty? ? nil : steps
    end

    def valid?(path)
      !parse(path).nil?
    end

    # The number at path in value, or nil (missing, not a number, a NaN or
    # infinity, which a chart cannot draw).
    def extract(value, path)
      steps = path.is_a?(Array) ? path : parse(path)
      return nil unless steps
      v = value
      steps.each do |s|
        v = step(v, s)
        return nil if v.nil?
      end
      number(v)
    end

    def step(v, s)
      return (v.is_a?(Array) ? v[s] : nil) if s.is_a?(Integer)
      return nil unless v.is_a?(Hash)
      v.key?(s) ? v[s] : v[s.to_sym]
    end

    def number(v)
      case v
      when true then 1
      when false then 0
      when Integer then v
      when Float then v.finite? ? v : nil
      end
    end

    # The numeric paths of a value, in field order:
    #   { "path" => "linear.x", "kind" => "float" }
    # kind: "int", "float", "bool"; an empty array is a sequence whose
    # elements are not known yet: { "path" => "position[0]", "kind" => "sequence" }.
    def paths(value, prefix = "", out = [])
      return out if out.size >= MAX_PATHS
      case value
      when Hash
        value.each do |k, v|
          name = k.to_s
          next unless SEGMENT.match?(name)
          paths(v, prefix.empty? ? name : "#{prefix}.#{name}", out)
        end
      when Array
        if value.empty?
          out << { "path" => "#{prefix}[0]", "kind" => "sequence" } unless prefix.empty?
        else
          value.first(MAX_INDEX).each_with_index { |v, i| paths(v, "#{prefix}[#{i}]", out) }
        end
      when true, false then out << { "path" => prefix, "kind" => "bool" }
      when Integer then out << { "path" => prefix, "kind" => "int" }
      when Float then out << { "path" => prefix, "kind" => "float" }
      end
      out
    end
  end
end
