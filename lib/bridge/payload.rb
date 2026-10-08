# How a value seen on a key is shown in the page: text when it is
# printable UTF-8, MessagePack (the object layer's encoding) when it
# decodes, ROS 2's CDR as hex, anything else as hex.
module Bridge
  module Payload
    MAX_TEXT = 2000
    MAX_HEX = 96
    CDR_HEADER = "\x00\x01\x00\x00".b

    module_function

    def describe(bytes)
      b = bytes.to_s.b
      if b.start_with?(CDR_HEADER)
        { "format" => "cdr", "text" => cdr_text(b), "size" => b.bytesize }
      elsif (t = text(b))
        { "format" => "text", "text" => t[0, MAX_TEXT], "size" => b.bytesize }
      elsif (m = msgpack(b))
        { "format" => "msgpack", "text" => m[0, MAX_TEXT], "size" => b.bytesize }
      else
        { "format" => "hex", "text" => hex(b), "size" => b.bytesize }
      end
    end

    def text(b)
      s = b.dup.force_encoding(Encoding::UTF_8)
      return nil unless s.valid_encoding?
      return nil if s.match?(/[\x00-\x08\x0e-\x1f\x7f]/)
      s
    end

    def msgpack(b)
      return nil if b.empty?
      require "msgpack"
      v = MessagePack.unpack(b)
      JSON.generate(v)
    rescue StandardError
      nil
    end

    def hex(b)
      h = b.byteslice(0, MAX_HEX).unpack1("H*").scan(/../).join(" ")
      b.bytesize > MAX_HEX ? "#{h} ..." : h
    end

    # A CDR string message (std_msgs/String and friends): the text after the
    # length; otherwise hex.
    def cdr_text(b)
      if b.bytesize >= 9
        len = b.byteslice(4, 4).unpack1("V")
        if len.positive? && 8 + len <= b.bytesize
          s = text(b.byteslice(8, len - 1))
          return "\"#{s}\" (CDR string)" if s && b.getbyte(8 + len - 1).zero?
        end
      end
      "CDR #{hex(b)}"
    end
  end
end
