require "test_helper"
require "asterism"
require "socket"
require "rbconfig"

# Protocol 2 against a CRuby program in another process, through a router
# that program opens (zenoh-c in router mode): the bridge asks an
# application's own profile (status, topics, types) with one get, follows
# its puts on @status and @pubs (a new type of its own asks again), and
# records its topics with their encoding, sequence numbers, sender's time
# and declared types (Bridge::Recorder); a recorded topic plays back with
# its attachment. The program holds two connections of one node, as a game
# host does (asterism-games: "game" and "spectate"): the second is an
# application of its own, with its token, profile and topics.
class Bridge::AppProfilesLiveTest < ActiveSupport::TestCase
  APP = <<~'RUBY'
    require "asterism"
    require "json"
    router = Asterism::Zenoh::Session.open(nil, config: { "mode" => "router", "listen/endpoints" => [ ARGV[0] ],
                                                          "scouting/multicast/enabled" => false })
    net = Asterism.connect(ARGV[0], node: "livenode", app: "demo")
    net.status(tables: 1)
    net.define_type("mygame/point", [ [ "x", "int" ], [ "y", "int" ] ], desc: "a point")
    net.define_type("mygame/board.strokes", [ [ "pts", "mygame/point[]" ], [ "color", "str" ] ])
    imu = net.publish("imu", type: :vector3, unit: "m/s2", ts: true)
    strokes = net.publish("board1/strokes", type: "mygame/board.strokes")
    cam = net.publish("camera", type: :image, encoding: "image/jpeg")
    seen = []
    net.subscribe("*/*/played") { |v, info| seen << [ v, info.seq, info.time ] }
    # The second application of the same node (a game host's spectate).
    spec = Asterism.connect(ARGV[0], node: "livenode", app: "spectate")
    spec.define_type("mygame/state", [ [ "turn", "int" ], [ "seats", "str[]" ] ])
    table = spec.publish("t1/state", type: "mygame/state")
    spec.status(watchers: 0)
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll_all
      r, = IO.select([ STDIN ], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      case line.strip
      when "put"
        3.times { |i| imu.put([ 0.1 * i, 0.0, 9.8 ]) }
        strokes.put([ [ [ 1, 2 ], [ 3, 4 ] ], "red" ])
        cam.put("\xFF\xD8\xFF\xE0jpeg".b)
        table.put([ 1, %w[a b] ])
      when "status" then net.status(tables: 2)
      when "extra"
        net.define_type("mygame/extra", [ [ "v", :vector3 ] ])
        net.publish("extra", type: "mygame/extra")
      when "seen"
        STDOUT.puts JSON.generate(seen)
      end
      STDOUT.puts "done"
      STDOUT.flush
    end
    spec.close
    net.close
    router.close
  RUBY

  setup do
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    @loc = "tcp/127.0.0.1:#{port}"
    incs = %w[asterism asterism-zenoh].flat_map { |g| Gem.loaded_specs.fetch(g).full_require_paths.flat_map { [ "-I", _1 ] } }
    @app = IO.popen([ RbConfig.ruby, *incs, "-e", APP, @loc ], "r+")
    assert_equal "ready", @app.gets&.strip
    @z = Asterism::Zenoh.open(@loc)
    @runner = Bridge::Runner.new(locator: @loc, logger: Logger.new(nil))
    @runner.instance_variable_set(:@z, @z)
    @runner.define_singleton_method(:say) { |_t| nil }
    @subs = [ @z.subscribe(Bridge::Runner::STATUSES) { @runner.send(:status_notice, _1) },
              @z.subscribe(Bridge::Runner::PUBS) { @runner.send(:pubs_notice, _1) } ]
    @z.start
    # The tokens the bridge follows (asterism/**): the two applications.
    @z.liveliness_get("asterism/livenode/*", timeout: 2.0).each { @runner.instance_variable_get(:@asterism_keys)[_1] = true }
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

  test "the second connection of the node is an application of its own: token, profile, topics, in the graph" do
    keys = @runner.instance_variable_get(:@asterism_keys).keys
    assert_equal %w[asterism/livenode/demo asterism/livenode/spectate], keys.sort, "an application token each"
    assert_equal %w[livenode/demo livenode/spectate], @runner.send(:asterism_apps).sort
    @runner.send(:sync_app_profiles)
    work
    got = profiles.to_graph["livenode/spectate"]
    assert_equal({ "watchers" => 0 }, got["status"])
    assert_equal({ "t1/state" => { "t" => "mygame/state" } }, got["pubs"])
    assert_equal %w[mygame/state], got["types"].keys, "its own types, not the other connection's"
    refute profiles.to_graph.dig("livenode/demo", "pubs", "t1/state"), "the other application does not declare it"
    decl, defs = profiles.topic("asterism/livenode/spectate/t1/state")
    assert_equal [ "mygame/state", %w[mygame/state] ], [ decl["t"], defs.keys ], "what a recording of it takes"
    g = Bridge::Graph.build(asterism: keys, app_profiles: profiles.to_graph).to_h
    app = g["nodes"].find { _1["id"] == "a_app:livenode/spectate" } || flunk("no spectate application")
    assert_equal "a_node:livenode", app["parent"]
    assert_equal [ "t1/state" ], app["data"]["pubs"].map { _1["name"] }
    assert_equal({ "watchers" => 0 }, app["data"]["status"])
    assert_equal 2, g["nodes"].count { _1["kind"] == "a_app" && _1["parent"] == "a_node:livenode" }
  end

  test "the node's profile, asked on the bridge's connection" do
    net = Asterism.connect(@loc, node: "console", app: "console")
    @runner.instance_variable_set(:@net, net)
    @runner.send(:fetch_profile, "livenode", nil)
    assert_equal "cruby", @runner.instance_variable_get(:@profiles).to_graph.dig("livenode", "kind")
  ensure
    net&.close
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
