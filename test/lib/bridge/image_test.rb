require "test_helper"

# Pictures of sensor_msgs/CompressedImage (Bridge::Payload.image) in the
# watch panel, the topic details (rates) and the timeline (Bag::Decode).
class Bridge::ImageTest < ActiveSupport::TestCase
  LE = "\x00\x01\x00\x00".b
  TYPE = "sensor_msgs/msg/CompressedImage"
  # A frame of the MuJoCo rover's camera (160x120 JPEG, family-mruby S1).
  JPEG = File.binread(File.expand_path("../../fixtures/files/camera_160x120.jpg", __dir__))
  # The smallest PNG header: signature, IHDR of 3x2.
  PNG = "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR".b + [ 3, 2 ].pack("NN") + "\x08\x02\x00\x00\x00".b

  def str(s, pos)
    pad = (4 - (pos % 4)) % 4
    ("\x00".b * pad) + [ s.bytesize + 1 ].pack("V") + s.b + "\x00".b
  end

  # CDR of a CompressedImage: header (stamp, frame_id), format, data.
  def cdr_image(fmt, data, frame: "camera_optical_frame")
    b = LE + [ 12, 500_000_000 ].pack("l<V")
    b += str(frame, b.bytesize - 4)
    b += str(fmt, b.bytesize - 4)
    b += ("\x00".b * ((4 - ((b.bytesize - 4) % 4)) % 4)) + [ data.bytesize ].pack("V") + data
    b
  end

  test "a JPEG frame comes with its picture, size and a one-line preview" do
    d = Bridge::Payload.describe(cdr_image("rgb8; jpeg compressed bgr8", JPEG), type: TYPE)
    assert_equal "cdr", d["format"]
    img = d["image"]
    assert_equal "image/jpeg", img["mime"]
    assert_equal [ 160, 120 ], [ img["width"], img["height"] ]
    assert_equal JPEG.bytesize, img["bytes"]
    assert_equal JPEG, img["data"].unpack1("m0")
    assert_equal "stamp 12.500, frame_id \"camera_optical_frame\", \"rgb8; jpeg compressed bgr8\", #{JPEG.bytesize} bytes", d["text"]
  end

  test "PNG, by its magic number" do
    img = Bridge::Payload.image(cdr_image("png", PNG, frame: ""), TYPE)
    assert_equal [ "image/png", 3, 2 ], img.values_at("mime", "width", "height")
  end

  test "no picture: another type, another format, too large, cut off" do
    assert_nil Bridge::Payload.describe(cdr_image("jpeg", JPEG), type: "sensor_msgs/msg/Image")["image"]
    assert_nil Bridge::Payload.image(cdr_image("rgb8", "\x01\x02\x03".b * 10), TYPE)
    big = "\xFF\xD8".b + ("\x00".b * Bridge::Payload::MAX_IMAGE)
    assert_nil Bridge::Payload.image(cdr_image("jpeg", big), TYPE)
    whole = cdr_image("jpeg", JPEG)
    assert_nil Bridge::Payload.image(whole.byteslice(0, whole.bytesize - 10), TYPE)
    assert_nil Bridge::Payload.image(LE + "\x01".b, TYPE)
  end

  test "the topic details keep the whole last frame of an image topic" do
    rates = Bridge::Rates.new
    key = "0/camera/image/compressed/sensor_msgs::msg::dds_::CompressedImage_/RIHS01_x"
    big_jpeg = JPEG + ("\x00".b * 6000) # larger than PREVIEW_BYTES, still a JPEG
    rates.record(key, cdr_image("jpeg", big_jpeg))
    row = rates.snapshot(full: true).values.first
    assert_equal "image/jpeg", row["image"]["mime"]
    assert_equal big_jpeg.bytesize, row["image"]["bytes"]
  end

  test "the timeline shows the picture and leaves its bytes out of the value" do
    channel = { "message_encoding" => "cdr", "topic" => "/camera/image/compressed", "metadata" => {} }
    out = Bag::Decode.message(channel, TYPE, cdr_image("jpeg", JPEG))
    assert_equal "image/jpeg", out["image"]["mime"]
    assert_equal "(#{JPEG.bytesize} bytes, image/jpeg)", out["value"]["data"]
    assert_equal "jpeg", out["value"]["format"]
  end
end
