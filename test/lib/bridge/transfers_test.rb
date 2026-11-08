require "test_helper"
require "asterism"
require "asterism/transfer"

# The bridge's side of files (Bridge::Transfers): the inbox at
# console/transfer/inbox and its rows, the senders and theirs. No Zenoh:
# the calls go through a stand-in connection, encoded as on the wire.
class Bridge::TransfersTest < ActiveSupport::TestCase
  # An answer already there, or an error; or never (pending).
  class Answer
    def initialize(value = nil, error = nil, done: true)
      @value = value
      @error = error
      @done = done
    end

    def done? = @done

    def value
      raise @error if @error
      @value
    end
  end

  class Query
    attr_reader :key, :payload, :replies

    def initialize(key, payload = nil)
      @key = key
      @payload = payload
      @replies = []
    end

    def reply(key, bytes) = @replies << [ key, bytes ]
  end

  # Tokens and queryables, and calls into them as a remote node makes them.
  class Conn
    Item = Struct.new(:key, :block, :closed) do
      def close = (self.closed = true)
    end

    attr_reader :tokens, :queryables

    def initialize
      @tokens = []
      @queryables = []
    end

    def liveliness(key) = (@tokens << Item.new(key, nil, false)).last
    def queryable(key, depth: 16, &blk) = (@queryables << Item.new(key, blk, false)).last

    def call(path, from, method, args)
      q = Query.new("asterism/#{path}/call/#{from}", Asterism::Codec.pack(Asterism.request(method, args, nil)))
      qa = @queryables.find { !_1.closed && q.key.start_with?(_1.key.delete_suffix("**")) }
      return Answer.new(nil, Asterism::TimeoutError.new("nobody answers")) unless qa
      qa.block.call(q)
      r = Asterism::Codec.unpack(q.replies[0][1])
      return Answer.new(r["value"]) if r.key?("value")
      Answer.new(nil, Asterism::RemoteError.new(r["error"]["class"], r["error"]["message"], r["error"]["kind"]))
    end
  end

  # A Sender whose calls go to a stand-in connection as the node from.
  def self.sender_through(conn, from, hang: false)
    Class.new(Asterism::Transfer::Sender) do
      define_method(:proxy) do
        to = @to
        Struct.new(:x) do
          define_method(:async) { self }
          define_method(:asterism_call) do |method, *args|
            next Answer.new(done: false) if hang && method.to_s != "cancel"
            conn.call(to, from, method.to_s, args)
          end
        end.new(nil)
      end
    end
  end

  setup do
    FileUtils.rm_rf(FileTransfer.dir)
    @said = []
    @conn = Conn.new
    @t = Bridge::Transfers.new(conn: @conn, node: "console", say: ->(text) { @said << text }, from: [ "fmruby-*" ])
    @t.start
    @src = Rails.root.join("tmp", "transfer-src-#{Process.pid}.bin").to_s
    @bytes = Random.new(3).bytes(200_000)
    File.binwrite(@src, @bytes)
  end

  teardown do
    @t.close
    FileUtils.rm_rf(FileTransfer.dir)
    FileUtils.rm_f(@src)
  end

  def run_sender(s)
    n = 0
    until s.done?
      s.step
      @t.send(:sync) if (n += 1) % 5 == 0
      flunk "not done" if n > 100_000
    end
    @t.sync
    s
  end

  def machine_sends(from, name: "photo.bin", **opts)
    s = self.class.sender_through(@conn, from).new("console/transfer/inbox", "file", @src, name: name, **opts)
    s.logger = nil
    run_sender(s)
  end

  def wait_for(row, *statuses)
    t0 = Time.now
    loop do
      @t.sync
      return row.reload if statuses.include?(row.reload.status)
      flunk "#{row.status}: not #{statuses.join('/')} (#{row.reason})" if Time.now - t0 > 10
      sleep 0.01
    end
  end

  test "the console answers at console/transfer/inbox and records what it receives" do
    assert_equal [ "asterism/console/transfer", "asterism/console/transfer/inbox" ], @conn.tokens.map(&:key)
    s = machine_sends("fmruby-abcdef")
    assert s.ok?, s.reason
    assert_equal @bytes, File.binread(FileTransfer.inbox.join("photo.bin"))
    r = FileTransfer.receives.last
    assert_equal [ "done", "fmruby-abcdef", "photo.bin", "photo.bin", 200_000, Digest::SHA256.hexdigest(@bytes), nil ],
                 [ r.status, r.node, r.name, r.placed_name, r.size, r.sha256, r.user ]
    # the same name again goes beside it
    assert_equal "photo(1).bin", machine_sends("fmruby-abcdef").answer["name"]
    assert_equal "photo(1).bin", FileTransfer.receives.last.placed_name
    assert_equal %w[photo(1).bin photo.bin], FileTransfer.received_files.map { _1["name"] }.sort
  end

  test "a node the setting does not allow is refused at begin, recorded once a minute" do
    s = machine_sends("linux-1")
    assert_equal "console takes no file from linux-1", s.reason
    assert_difference("FileTransfer.count", 0) { machine_sends("linux-1") }
    r = FileTransfer.receives.last
    assert_equal [ "refused", "linux-1", "console takes no file from linux-1" ], [ r.status, r.node, r.reason ]
    refute File.exist?(FileTransfer.inbox.join("photo.bin"))
    assert_equal "console has no SD card to write to", machine_sends("fmruby-a", meta: { "inbox" => "sd" }).reason
  end

  test "a pending send goes to the machine's inbox; the row gets the placed name and the upload goes" do
    machine = Conn.new
    inbox = Asterism::Transfer::FileInbox.new(Rails.root.join("tmp/transfer-machine-#{Process.pid}").to_s,
                                              from: [ "console" ], label: "fmruby-a")
    inbox.logger = nil
    Asterism::Transfer::Endpoint.new(machine, inbox, node: "fmruby-a").start
    @t.sender_class = self.class.sender_through(machine, "console")
    CallPermission.create!(kind: "file", node: "fmruby-*")
    FileUtils.mkdir_p(FileTransfer.outbox)
    row = FileTransfer.create!(direction: "send", status: "pending", node: "fmruby-a", name: "notes.bin", size: @bytes.bytesize,
                               sha256: Digest::SHA256.hexdigest(@bytes), stored: SecureRandom.hex(12), user: users(:user))
    FileUtils.cp(@src, row.outbox_path)
    wait_for(row, "done", "failed")
    assert_equal [ "done", "notes.bin", 200_000 ], [ row.status, row.placed_name, row.done_bytes ], row.reason
    assert_equal @bytes, File.binread("#{inbox.inbox_dir}notes.bin")
    assert row.piece.positive? && row.window.positive? && row.took_ms
    refute File.exist?(row.outbox_path)
    # again with overwrite
    row2 = FileTransfer.create!(direction: "send", status: "pending", node: "fmruby-a", name: "notes.bin", size: @bytes.bytesize,
                                sha256: Digest::SHA256.hexdigest(@bytes), stored: SecureRandom.hex(12), overwrite: true)
    FileUtils.cp(@src, row2.outbox_path)
    assert_equal "notes.bin", wait_for(row2, "done", "failed").placed_name
    # the permission removed: the bridge checks again
    CallPermission.files.delete_all
    row3 = FileTransfer.create!(direction: "send", status: "pending", node: "fmruby-a", name: "x.bin", size: 1, stored: SecureRandom.hex(12))
    assert_equal "denied", wait_for(row3, "denied", "failed").status
  ensure
    FileUtils.rm_rf(Rails.root.join("tmp/transfer-machine-#{Process.pid}"))
  end

  test "cancel: the sender stops and tells the machine" do
    machine = Conn.new
    @t.sender_class = self.class.sender_through(machine, "console", hang: true)
    CallPermission.create!(kind: "file", node: "*")
    FileUtils.mkdir_p(FileTransfer.outbox)
    row = FileTransfer.create!(direction: "send", status: "pending", node: "fmruby-a", name: "x.bin", size: @bytes.bytesize,
                               sha256: Digest::SHA256.hexdigest(@bytes), stored: SecureRandom.hex(12))
    FileUtils.cp(@src, row.outbox_path)
    wait_for(row, "sending")
    row.cancel!
    assert_equal "cancelled", wait_for(row, "cancelled", "failed").status
    refute File.exist?(row.outbox_path)
  end
end
