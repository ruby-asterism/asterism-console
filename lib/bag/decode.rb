# Messages of a recording as the pages show them, with V3's decoders:
#
#   cdr       the generated type of the channel's schema name (asterism's
#             bundled types and the console's vendor/msgs; Bridge::Types):
#             a Hash; /rosout (rcl_interfaces/msg/Log) also as a log line
#             (Bridge::Logs); the one-line preview of V2 (Bridge::Payload);
#             a sensor_msgs/CompressedImage in JPEG / PNG also as its
#             picture ("image", Bridge::Payload.image)
#   msgpack   MessagePack (an Asterism key; its log keys also as log lines)
#   json      JSON (the network structure)
#   anything else, or what does not decode: hex
#
# value: what the page shows as the message (JSON-safe: binary strings as
# hex, NaN and infinities as strings), numbers: what the plots read
# (Bridge::Fields paths into it).
module Bag
  module Decode
    MAX_TEXT = 4000
    MAX_ARRAY = 256 # elements shown of a long array (the rest are counted)

    module_function

    # { "format", "text" (one line), "value" (or nil), "log" (a log line or nil), "error" }
    def message(channel, schema_name, bytes, at_ms = nil)
      enc = channel["message_encoding"]
      out = { "format" => enc, "size" => bytes.bytesize }
      case enc
      when "cdr"
        out["text"] = Bridge::Payload.cdr_text(bytes.b, schema_name)
        img = Bridge::Payload.image(bytes.b, schema_name)
        out["image"] = img if img
        begin
          v = ros_value(schema_name, bytes)
          # The picture is shown as one; its bytes are not repeated as hex.
          v[:data] = "(#{img['bytes']} bytes, #{img['mime']})" if img && v.is_a?(Hash) && v.key?(:data)
          out["value"] = safe(v)
          if schema_name == Bridge::Logs::LOG_TYPE
            out["log"] = Bridge::Logs.ros_line("#{channel.dig('metadata', 'ros_domain') || 0}/rosout", bytes, at_ms)
          end
        rescue Bridge::Types::Unknown => e
          out["error"] = e.message
        rescue StandardError => e
          out["error"] = "does not decode as #{schema_name}: #{e.class}"
        end
      when "msgpack"
        begin
          require "msgpack"
          v = MessagePack.unpack(bytes)
          out["value"] = safe(v)
          out["text"] = JSON.generate(out["value"])[0, 300]
          out["log"] = Bridge::Logs.asterism_line(channel["topic"], bytes, at_ms) if log_key?(channel["topic"])
        rescue StandardError
          out.merge!(Bridge::Payload.describe(bytes).slice("format", "text"))
        end
      when "json"
        begin
          out["value"] = JSON.parse(bytes)
          out["text"] = bytes.byteslice(0, 300).force_encoding(Encoding::UTF_8).scrub
        rescue JSON::ParserError
          out["text"] = Bridge::Payload.hex(bytes.b)
        end
      else
        out.merge!(Bridge::Payload.describe(bytes).slice("format", "text"))
      end
      out
    end

    # The decoded message as a Hash (raises Types::Unknown for a type that
    # is not bundled).
    def ros_value(type, bytes)
      Bridge::Types.ros(type).decode(bytes).to_h
    end

    # A decoder for the plots: bytes -> a value Fields can walk.
    def decoder(channel, schema_name)
      case channel["message_encoding"]
      when "cdr"
        t = Bridge::Types.ros(schema_name)
        ->(b) { t.decode(b).to_h }
      when "msgpack" then Bridge::Plots.msgpack_decoder
      when "json" then ->(b) { JSON.parse(b) }
      end
    end

    def log_key?(topic)
      parts = topic.to_s.split("/")
      parts.size == 4 && parts[0] == "asterism" && parts[3] == "log"
    end

    # JSON-safe: binary Strings as hex, non-finite Floats as text, long
    # arrays cut (with the number left out).
    def safe(v)
      case v
      when Hash then v.to_h { |k, x| [ k.to_s, safe(x) ] }
      when Array
        out = v.first(MAX_ARRAY).map { safe(_1) }
        out << "... #{v.size - MAX_ARRAY} more" if v.size > MAX_ARRAY
        out
      when Float then v.finite? ? v : v.to_s
      when String
        s = v.dup.force_encoding(Encoding::UTF_8)
        s.valid_encoding? ? s[0, MAX_TEXT] : "0x#{v.unpack1('H*')[0, MAX_TEXT]}"
      when Symbol then v.to_s
      when nil, true, false, Integer then v
      else v.to_s
      end
    end
  end
end
