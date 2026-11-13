require "test_helper"
require "asterism"
require "socket"
require "rbconfig"

# Protocol 2 against a CRuby application in another process, over a peer
# link (no router): the bridge asks its own profile (status, topics, types)
# with one get, follows its puts on @status and @pubs (a new type of its
# own asks again), and records its topics with their encoding, sequence
# numbers, sender's time and declared types (Bridge::Recorder); a recorded
# topic plays back with its attachment.
class Bridge::AppProfilesLiveTest < ActiveSupport::TestCase
  APP = <<~'RUBY'
    require "asterism"
    require "json"
    Asterism.status(tables: 1)
    Asterism.define_type("mygame/point", [ [ "x", "int" ], [ "y", "int" ] ], desc: "a point")
    Asterism.define_type("mygame/board.strokes", [ [ "pts", "mygame/point[]" ], [ "color", "str" ] ])
    Asterism.connect(nil, node: "livenode", app: "demo", mode: :peer, listen: ARGV[0])
    imu = Asterism.publish("imu", type: :vector3, unit: "m/s2", ts: true)
    strokes = Asterism.publish("board1/strokes", type: "mygame/board.strokes")
    cam = Asterism.publish("camera", type: :image, encoding: "image/jpeg")
    seen = []
    Asterism.subscribe("*/*/played") { |v, info| seen << [ v, info.seq, info.time ] }
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      r, = IO.select([ STDIN ], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      case line.strip
      when "put"
        3.times { |i| imu.put([ 0.1 * i, 0.0, 9.8 ]) }
        strokes.put([ [ [ 1, 2 ], [ 3, 4 ] ], "red" ])
        cam.put("\xFF\xD8\xFF\xE0jpeg".b)
      when "status" then Asterism.status(tables: 2)
      when "extra"
        Asterism.define_type("mygame/extra", [ [ "v", :vector3 ] ])
        Asterism.publish("extra", type: "mygame/extra")
      when "seen"
        STDOUT.puts JSON.generate(seen)
      end
      STDOUT.puts "done"
      STDOUT.flush
    end
    Asterism.close
  RUBY

  setup do
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    @loc = "tcp/127.0.0.1:#{port}"
    incs = %w[asterism asterism-zenoh].flat_map { |g| Gem.loaded_specs.fetch(g).full_require_paths.flat_map { [ "-I", _1 ] } }
    @app = IO.popen([ RbConfig.ruby, *incs, "-e", APP, @loc ], "r+")
    assert_equal "ready", @app.gets&.strip
    @z = Asterism::Zenoh.open(@loc, mode: :peer)
    @runner = Bridge::Runner.new(locator: @loc, logger: Logger.new(nil))
    @runner.instance_variable_set(:@z, @z)
    @runner.define_singleton_method(:say) { |_t| nil }
    @subs = [ @z.subscribe(Bridge::Runner::STATUSES) { @runner.send(:status_notice, _1) },
              @z.subscribe(Bridge::Runner::PUBS) { @runner.send(:pubs_notice, _1) } ]
    @z.start
    @runner.instance_variable_get(:@asterism_keys)["asterism/livenode/demo"] = true
    @dir = Rails.root.join("tmp", "app-profiles-live-#{Process.pid}")
    FileUtils.mkdir_p(@dir)
  end

  teardown do
    @subs&.each { _1.close rescue nil }
    @z&.close
    if @app
      @app.close_write rescue nil
      @app.read rescue nil
      @app.close rescue nil
    end
    FileUtils.rm_rf(@dir)
  end

  def tell(line)
    @app.puts(line)
    @app.flush
    out = []
    while (l = @app.gets&.strip) && l != "done"
      out << l
    end
    out
  end

  def profiles = @runner.instance_variable_get(:@app_profiles)
  def queue = @runner.instance_variable_get(:@profile_queue)

  # Runs what the profile worker would, until the queue is empty.
  def work
    until queue.empty?
      kind, app = queue.pop
      assert_equal :app, kind
      @runner.send(:fetch_app_profile, app)
    end
  end

  def eventually(timeout = 5)
    t = Time.now
    until yield
      flunk "timed out" if Time.now - t > timeout
      sleep 0.05
    end
  end

  test "one get brings the status, the topics and the types; the puts follow" do
    @runner.send(:sync_app_profiles)
    work
    got = profiles.to_graph["livenode/demo"]
    assert_equal({ "tables" => 1 }, got["status"])
    assert_equal({ "imu" => { "t" => 2, "u" => "m/s2", "ts" => true }, "board1/strokes" => { "t" => "mygame/board.strokes" },
                   "camera" => { "t" => 4, "e" => 17 } }, got["pubs"])
    assert_equal %w[mygame/board.strokes mygame/point], got["types"].keys.sort
    tell("status")
    eventually { profiles.to_graph.dig("livenode/demo", "status", "tables") == 2 }
    tell("extra")
    eventually { profiles.to_graph.dig("livenode/demo", "pubs", "extra") }
    assert_equal [ :app, "livenode/demo" ], queue.pop(true), "a type not known: asked again"
    @runner.send(:fetch_app_profile, "livenode/demo")
    assert_equal [ [ "v", "vector3" ] ], profiles.to_graph.dig("livenode/demo", "types", "mygame/extra", "f")
    g = Bridge::Graph.build(asterism: %w[asterism/livenode/demo], app_profiles: profiles.to_graph).to_h
    app = g["nodes"].find { _1["id"] == "a_app:livenode/demo" }["data"]
    assert_equal %w[board1/strokes camera extra imu], app["pubs"].map { _1["name"] }
  end

  test "a recording of the topics: encoding, sequence, sender's time, schema; and its playback" do
    @runner.send(:sync_app_profiles)
    work
    path = @dir.join("live.mcap")
    rec = Bridge::Recorder.new(id: 1, path: path, max_bytes: 1024 * 1024, max_seconds: 60,
                               declarations: ->(key) { profiles.topic(key) }).open
    sub = @z.subscribe("asterism/livenode/demo/**", depth: 64) { rec.key("asterism/livenode/demo/**", _1) }
    sleep 0.5 # the publishers learn of the subscriber
    tell("put")
    eventually { rec.progress["messages"] >= 5 }
    sub.close
    rec.finish
    r = MCAP::Reader.new(path.to_s)
    by = r.info["channels"].to_h { [ _1["topic"], _1 ] }
    assert_equal [ "msgpack", "asterism/vector3" ], by["asterism/livenode/demo/imu"].values_at("message_encoding", "schema")
    assert_equal [ "msgpack", "mygame/board.strokes", "asterism/types" ],
                 by["asterism/livenode/demo/board1/strokes"].values_at("message_encoding", "schema", "schema_encoding")
    assert_equal [ "image/jpeg", "asterism/image" ], by["asterism/livenode/demo/camera"].values_at("message_encoding", "schema")
    msgs = r.each_message.map { |m, ch, _| [ ch.topic, m ] }
    imu = msgs.select { _1[0] == "asterism/livenode/demo/imu" }.map(&:last)
    seqs = imu.map(&:sequence)
    assert_equal (seqs.first...seqs.first + seqs.size).to_a, seqs, "numbered one by one"
    now_ns = Time.now.to_r * 1_000_000_000
    assert imu.all? { (now_ns - _1.publish_time).abs < 60 * 1_000_000_000 }, "the sender's time"
    assert(imu.all? { _1.publish_time % 1_000_000 == 0 }, "in ms")
    assert_equal "\xFF\xD8\xFF\xE0jpeg".b, msgs.find { _1[0] == "asterism/livenode/demo/camera" }[1].data
    r.close

    # Played back onto another key (the recording's topic renamed), the
    # app reads the number and the sender's time from the attachment.
    played = @dir.join("played.mcap")
    File.open(played, "wb") do |f|
      w = MCAP::Writer.new(f, profile: "ros2")
      c = w.add_channel(topic: "asterism/console/x/played", message_encoding: "msgpack",
                        schema_id: w.add_schema(name: "asterism/vector3", encoding: "", data: ""),
                        metadata: by["asterism/livenode/demo/imu"]["metadata"])
      imu.each { w.add_message(channel_id: c, log_time: _1.log_time, publish_time: _1.publish_time, sequence: _1.sequence, data: _1.data) }
      w.finish
    end
    pl = Bridge::Player.new(playback_id: 1, path: played.to_s, speed: 10.0, session: @z.session,
                            put: ->(key, bytes, **opts) { @z.put(key, bytes, **opts) })
    pl.run
    assert_nil pl.error
    eventually { tell("seen").first.to_s.include?(seqs.last.to_s) }
    seen = JSON.parse(tell("seen").first)
    assert_equal seqs, seen.map { _1[1] }
    assert_equal imu.map { _1.publish_time / 1_000_000 }, seen.map { _1[2] }
  end
end
