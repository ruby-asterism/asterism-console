require "test_helper"

class FileTransferTest < ActiveSupport::TestCase
  setup { FileUtils.rm_rf(FileTransfer.dir) }
  teardown { FileUtils.rm_rf(FileTransfer.dir) }

  test "the names a machine takes" do
    %w[a.txt foo.tar.gz 日本語.txt a-b_c(1).bin].each { assert FileTransfer.file_name?(_1), _1 }
    [ "", ".hidden", "a/b", "../x", "a..b", "a\\\\b", "a\\nb", "x" * 49, nil ].each { refute FileTransfer.file_name?(_1), _1.inspect }
    refute FileTransfer.new(direction: "send", status: "pending", node: "n", name: "../x").valid?
    # a received row keeps what the machine said, whatever it was
    assert FileTransfer.new(direction: "receive", status: "refused", node: "n", name: ".x").valid?
    refute FileTransfer.new(direction: "send", status: "pending", node: "a/b", name: "x").valid?
  end

  test "who may send to the console, from the setting" do
    assert_equal [], FileTransfer.receive_from({})
    assert_equal %w[fmruby-* wasm-1], FileTransfer.receive_from("ASTERISM_TRANSFER_FROM" => "fmruby-*, wasm-1")
  end

  test "the received files, hidden pieces left out" do
    FileUtils.mkdir_p(FileTransfer.inbox)
    File.write(FileTransfer.inbox.join("a.txt"), "aa")
    File.write(FileTransfer.inbox.join(".b.txt.file.part"), "b")
    assert_equal [ "a.txt" ], FileTransfer.received_files.map { _1["name"] }
    assert_equal 2, FileTransfer.received_bytes
    assert FileTransfer.received_path("a.txt")
    assert_nil FileTransfer.received_path(".b.txt.file.part")
    assert_nil FileTransfer.received_path("../a.txt")
    assert_nil FileTransfer.received_path("c.txt")
  end

  test "cancel: a pending row ends at once, a sending one asks the bridge" do
    FileUtils.mkdir_p(FileTransfer.outbox)
    r = FileTransfer.create!(direction: "send", status: "pending", node: "n", name: "x.bin", size: 1, stored: "0" * 24)
    File.write(r.outbox_path, "x")
    r.cancel!
    assert_equal "cancelled", r.status
    refute File.exist?(r.outbox_path)
    r.update!(status: "sending")
    r.cancel!
    assert_equal "cancelling", r.status
  end
end
