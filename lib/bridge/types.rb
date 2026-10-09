# ROS 2 message types for the plots and the log list: the ones asterism
# bundles (its data/msgs) and the console's own (vendor/msgs:
# rcl_interfaces/msg/Log), loaded with Asterism::ROS.require_type. The
# bridge alone loads them (Puma never loads Asterism).
module Bridge
  module Types
    DIR = File.expand_path("../../vendor/msgs", __dir__)
    # pkg/msg/Name only: a type name comes from the network (liveliness
    # tokens, data keys) and becomes a file path in require_type.
    NAME = %r{\A[a-z][a-z0-9_]*/msg/[A-Z][A-Za-z0-9]*\z}

    module_function

    def setup
      require "asterism"
      Asterism::ROS::TYPE_PATH << DIR unless Asterism::ROS::TYPE_PATH.include?(DIR)
    end

    # The generated type, or raises Unknown (with a message for the page).
    def ros(name)
      setup
      raise Unknown, "#{name.to_s[0, 80].inspect} is not a message type name" unless NAME.match?(name.to_s)
      Asterism::ROS.require_type(name)
    rescue Asterism::ROS::UnknownType
      raise Unknown, "type #{name} is not bundled (asterism's data/msgs and the console's vendor/msgs have no generated file for it)"
    end

    # The numeric fields of a type, from a message with every field at its
    # default (sequences are empty: offered as "name[0]").
    def fields(type)
      Fields.paths(type.new.to_h)
    end

    class Unknown < StandardError; end
  end
end
