require "test_helper"
require "msgpack"

class Bridge::PayloadTest < ActiveSupport::TestCase
  test "text" do
    assert_equal({ "format" => "text", "text" => "12", "size" => 2 }, Bridge::Payload.describe("12"))
    assert_equal "text", Bridge::Payload.describe("日本語".b)["format"]
  end

  test "MessagePack" do
    d = Bridge::Payload.describe(MessagePack.pack([ "ok", { "a" => 1 } ]))
    assert_equal "msgpack", d["format"]
    assert_equal '["ok",{"a":1}]', d["text"]
  end

  test "a CDR string" do
    d = Bridge::Payload.describe("\x00\x01\x00\x00\x06\x00\x00\x00hello\x00".b)
    assert_equal "cdr", d["format"]
    assert_equal '"hello" (CDR string)', d["text"]
    assert_match(/\ACDR 00 01 00 00 2a/, Bridge::Payload.describe("\x00\x01\x00\x00\x2a\x00".b)["text"])
  end

  test "anything else is hex" do
    d = Bridge::Payload.describe("\xff\xfe\x00".b)
    assert_equal "hex", d["format"]
    assert_equal "ff fe 00", d["text"]
  end
end
