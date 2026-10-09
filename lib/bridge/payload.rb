# How a value seen on a key is shown in the page: text when it is
# printable UTF-8, MessagePack (the object layer's encoding) when it
# decodes, ROS 2's CDR (a few common message types decoded, a string
# message, else hex), anything else as hex. A sensor_msgs/CompressedImage
# in JPEG or PNG also comes with the picture ("image"), which the browser
# shows as it is.
module Bridge
  module Payload
    MAX_TEXT = 2000
    MAX_HEX = 96
    CDR_HEADER = "\x00\x01\x00\x00".b
    IMAGE_TYPE = "sensor_msgs/msg/CompressedImage"
    MAX_IMAGE = 256 * 1024 # bytes of picture sent to the page (larger ones: no picture)

    module_function

    # type: the ROS type ("std_msgs/msg/String"), when known. key: a ROS 2
    # data key, to take the type from (<domain>/<name>/<type>/<hash>).
    def describe(bytes, type: nil, key: nil)
      b = bytes.to_s.b
      type ||= Rates.topic_of(key)&.last if key
      if b.start_with?(CDR_HEADER)
        out = { "format" => "cdr", "text" => cdr_text(b, type), "size" => b.bytesize }
        img = image(b, type)
        out["image"] = img if img
        out
      elsif (t = text(b))
        { "format" => "text", "text" => t[0, MAX_TEXT], "size" => b.bytesize }
      elsif (m = msgpack(b))
        { "format" => "msgpack", "text" => m[0, MAX_TEXT], "size" => b.bytesize }
      else
        { "format" => "hex", "text" => hex(b), "size" => b.bytesize }
      end
    end

    # The picture of a sensor_msgs/CompressedImage (CDR):
    # { "mime", "data" (base64), "bytes", "width", "height" } or nil (another
    # type, a format other than JPEG / PNG, larger than MAX_IMAGE, cut off).
    # The bytes are checked by their magic numbers, not by the format field.
    def image(b, type)
      return nil unless type == IMAGE_TYPE
      r = Cdr::Reader.new(b)
      r.header
      r.string # format ("jpeg", "rgb8; jpeg compressed bgr8", "png", ...)
      n = r.u32
      at = r.pos
      return nil if n.zero? || n > MAX_IMAGE || at + n > b.bytesize
      data = b.byteslice(at, n)
      mime, w, h =
        if data.start_with?("\xFF\xD8".b) then [ "image/jpeg", *jpeg_size(data) ]
        elsif data.start_with?("\x89PNG".b) then [ "image/png", *png_size(data) ]
        end
      return nil unless mime
      { "mime" => mime, "data" => [ data ].pack("m0"), "bytes" => n, "width" => w, "height" => h }
    rescue ArgumentError, RangeError
      nil
    end

    # [width, height] from a JPEG's start-of-frame segment, or [nil, nil].
    def jpeg_size(d)
      i = 2
      while i + 9 <= d.bytesize
        return [ nil, nil ] unless d.getbyte(i) == 0xFF
        marker = d.getbyte(i + 1)
        len = d.byteslice(i + 2, 2).unpack1("n")
        if (0xC0..0xCF).cover?(marker) && ![ 0xC4, 0xC8, 0xCC ].include?(marker)
          h, w = d.byteslice(i + 5, 4).unpack("nn")
          return [ w, h ]
        end
        i += 2 + len
      end
      [ nil, nil ]
    end

    # [width, height] from a PNG's IHDR.
    def png_size(d)
      return [ nil, nil ] if d.bytesize < 24
      d.byteslice(16, 8).unpack("NN")
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

    # A CDR message: decoded when its type is one Cdr knows; else a string
    # message (std_msgs/String and friends) when it reads as one; else hex.
    def cdr_text(b, type = nil)
      if type && (t = Cdr.describe(b, type))
        return t[0, MAX_TEXT]
      end
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
