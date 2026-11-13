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
# host does with a room (asterism-games: "games" and "room01"): the second
# is an application of its own, with its token, profile and topics. Both
# put on one key of the node's shared place (protocol 2), each with its own
# definition of one type name: the graph draws the place with a line from
# each, a recording gets a channel per sender with that sender's schema,
# and a sender that leaves takes its declarations with it.
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
    net.define_type("mygame/state", [ [ "turn", "int" ] ])
    mine = net.publish("spectate/t1/state", shared: :node, type: "mygame/state")
    quick = nil
    seen = []
    net.subscribe("*/*/played") { |v, info| seen << [ v, info.seq, info.time ] }
    net.subscribe("*/@shared/replayed/**") { |v, info| seen << [ v, info.seq, info.time, info.from ] }
    # The second application of the same node (a game host's room).
    spec = Asterism.connect(ARGV[0], node: "livenode", app: "room01")
    spec.define_type("mygame/state", [ [ "turn", "int" ], [ "seats", "str[]" ] ])
    table = spec.publish("spectate/t1/state", shared: :node, type: "mygame/state")
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
        mine.put([ 7 ])
        table.put([ 2, %w[a b] ])
      when "status" then net.status(tables: 2)
      when "extra"
        net.define_type("mygame/extra", [ [ "v", :vector3 ] ])
        net.publish("extra", type: "mygame/extra")
      when "leave"
        spec.close
        spec = nil
      when "restart"
        # A sender that connects again at once: a new run id, numbers from 0.
        2.times do |run|
          quick&.close
          quick = Asterism.connect(ARGV[0], node: "livenode", app: "quick")
          n = quick.publish("n", type: :number)
          t = Time.now
          Asterism.poll_all while Time.now - t < 0.3 # the publisher learns of the subscriber
          (run == 0 ? 3 : 4).times { |i| n.put(i) }
        end
      when "seen"
        STDOUT.puts JSON.generate(seen)
      end
      STDOUT.puts "done"
      STDOUT.flush
    end
    spec&.close
    quick&.close
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
    @z.liveliness_get("asterism/livenode/*/protocol/2", timeout: 2.0).each { @runner.instance_variable_get(:@asterism_keys)[_1] = true }
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
                   "camera" => { "t" => 4, "e" => 17 }, "livenode/@shared/spectate/t1/state" => { "t" => "mygame/state" } },
                 got["pubs"])
    assert_equal %w[mygame/board.strokes mygame/point mygame/state], got["types"].keys.sort
    tell("status")
    eventually { profiles.to_graph.dig("livenode/demo", "status", "tables") == 2 }
    tell("extra")
    eventually { profiles.to_graph.dig("livenode/demo", "pubs", "extra") }
    assert_equal [ :app, "livenode/demo" ], queue.pop(true), "a type not known: asked again"
    @runner.send(:fetch_app_profile, "livenode/demo")
    assert_equal [ [ "v", "vector3" ] ], profiles.to_graph.dig("livenode/demo", "types", "mygame/extra", "f")
    g = Bridge::Graph.build(asterism: %w[asterism/livenode/demo/protocol/2], app_profiles: profiles.to_graph).to_h
    app = g["nodes"].find { _1["id"] == "a_app:livenode/demo" }["data"]
    assert_equal %w[board1/strokes camera extra imu livenode/@shared/spectate/t1/state], app["pubs"].map { _1["name"] }
  end

  SHARED_KEY = "asterism/livenode/@shared/spectate/t1/state".freeze

  test "the second connection of the node is an application of its own; both declare one shared key, each its own type" do
    keys = @runner.instance_variable_get(:@asterism_keys).keys
    assert_equal %w[asterism/livenode/demo/protocol/2 asterism/livenode/room01/protocol/2], keys.sort, "an application token each"
    assert_equal %w[livenode/demo livenode/room01], @runner.send(:asterism_apps).sort
    @runner.send(:sync_app_profiles)
    work
    got = profiles.to_graph["livenode/room01"]
    assert_equal({ "watchers" => 0 }, got["status"])
    assert_equal({ "livenode/@shared/spectate/t1/state" => { "t" => "mygame/state" } }, got["pubs"])
    assert_equal %w[mygame/state], got["types"].keys, "its own types, not the other connection's"
    room_decl, room_defs = profiles.topic(SHARED_KEY, from: "livenode/room01")
    demo_decl, demo_defs = profiles.topic(SHARED_KEY, from: "livenode/demo")
    assert_equal [ "mygame/state", "mygame/state" ], [ room_decl["t"], demo_decl["t"] ]
    assert_equal [ [ "seats", "str[]" ] ], room_defs["mygame/state"]["f"] - demo_defs["mygame/state"]["f"], "each sender's definition"
    g = Bridge::Graph.build(asterism: keys, app_profiles: profiles.to_graph).to_h
    app = g["nodes"].find { _1["id"] == "a_app:livenode/room01" } || flunk("no room01 application")
    assert_equal "a_node:livenode", app["parent"]
    assert_equal({ "watchers" => 0 }, app["data"]["status"])
    place = g["nodes"].find { _1["id"] == "a_shared:livenode" } || flunk("no shared place")
    assert_equal [ "a_shared", "a_node:livenode" ], place.values_at("kind", "parent")
    assert_equal %w[livenode/demo livenode/room01], place["data"]["keys"][0]["senders"].map { _1["app"] }
    lines = g["edges"].select { _1["kind"] == "shares" }.map { [ _1["source"], _1["target"], _1["label"] ] }.sort
    assert_equal [ [ "a_app:livenode/demo", "a_shared:livenode", "spectate/t1/state" ],
                   [ "a_app:livenode/room01", "a_shared:livenode", "spectate/t1/state" ] ], lines
    refute g["nodes"].any? { _1["kind"] == "a_app" && _1["label"].include?("@shared") }, "a place is not an app"
  end

  test "a sender that leaves: its token goes, its declarations with it (graph and recorder)" do
    @runner.send(:sync_app_profiles)
    work
    refute_nil profiles.topic(SHARED_KEY, from: "livenode/room01")
    tell("leave")
    eventually do
      @z.liveliness_get("asterism/livenode/*/protocol/2", timeout: 1.0).sort == %w[asterism/livenode/demo/protocol/2]
    end
    @runner.instance_variable_get(:@asterism_keys).delete("asterism/livenode/room01/protocol/2") # what the bridge's watch does
    @runner.send(:sync_app_profiles)
    assert_nil profiles.topic(SHARED_KEY, from: "livenode/room01")
    refute_nil profiles.topic(SHARED_KEY, from: "livenode/demo")
    g = Bridge::Graph.build(asterism: @runner.instance_variable_get(:@asterism_keys).keys, app_profiles: profiles.to_graph).to_h
    assert_equal [ "a_app:livenode/demo" ], g["edges"].select { _1["kind"] == "shares" }.map { _1["source"] }
    place = g["nodes"].find { _1["id"] == "a_shared:livenode" }
    assert_equal %w[livenode/demo], place["data"]["keys"][0]["senders"].map { _1["app"] }
  end

  test "a recording of asterism/**: the shared key beside it, a channel per sender; its playback in the sender's form" do
    @runner.send(:sync_app_profiles)
    work
    path = @dir.join("shared.mcap")
    rec = Bridge::Recorder.new(id: 2, path: path, max_bytes: 1024 * 1024, max_seconds: 60,
                               declarations: ->(key, from) { profiles.topic(key, from: from) }).open
    exprs = [ "asterism/**", *Bridge::Shared.companions("asterism/**") ]
    subs = exprs.map { |e| @z.subscribe(e, depth: 64) { rec.key(e, _1) } }
    sleep 0.5
    tell("put")
    eventually { rec.progress["channel_counts"][SHARED_KEY].to_i >= 3 }
    subs.each(&:close)
    rec.finish
    r = MCAP::Reader.new(path.to_s)
    chans = r.info["channels"].select { _1["topic"] == SHARED_KEY }
    assert_equal %w[livenode/demo livenode/room01], chans.map { _1["metadata"]["asterism_from"] }.sort
    assert chans.all? { _1["metadata"]["asterism_key_expr"] == "asterism/*/@shared/**" }
    fields = r.channels.values.select { _1.topic == SHARED_KEY }
              .to_h { |c| [ c.metadata["asterism_from"], JSON.parse(r.schemas[c.schema_id].data)["mygame/state"]["f"] ] }
    assert_equal [ [ "turn", "int" ] ], fields["livenode/demo"]
    assert_equal [ [ "turn", "int" ], [ "seats", "str[]" ] ], fields["livenode/room01"]
    msgs = r.each_message.filter_map { |m, ch, _| [ ch.metadata["asterism_from"], m ] if ch.topic == SHARED_KEY }
    room = msgs.select { _1[0] == "livenode/room01" }.map(&:last)
    assert_equal [ room[0].sequence, room[0].sequence + 1 ], room.map(&:sequence), "room01's own numbers"
    assert_equal 1, msgs.count { _1[0] == "livenode/demo" }
    room_meta = chans.find { _1["metadata"]["asterism_from"] == "livenode/room01" }["metadata"]
    r.close

    # Played back onto another key of the sender's node's place (a sender of another node is none
    # there): the app reads the sender and its numbers.
    played = @dir.join("replayed.mcap")
    File.open(played, "wb") do |f|
      w = MCAP::Writer.new(f, profile: "ros2")
      c = w.add_channel(topic: "asterism/livenode/@shared/replayed/t1", message_encoding: "msgpack",
                        schema_id: w.add_schema(name: "mygame/state", encoding: "", data: ""), metadata: room_meta)
      room.each { w.add_message(channel_id: c, log_time: _1.log_time, publish_time: _1.publish_time, sequence: _1.sequence, data: _1.data) }
      w.finish
    end
    pl = Bridge::Player.new(playback_id: 2, path: played.to_s, speed: 10.0, session: @z.session,
                            put: ->(key, bytes, **opts) { @z.put(key, bytes, **opts) })
    pl.run
    assert_nil pl.error
    eventually { JSON.parse(tell("seen").first).count { _1[3] } >= 2 }
    seen = JSON.parse(tell("seen").first).select { _1[3] }
    assert_equal room.map(&:sequence), seen.map { _1[1] }
    assert_equal %w[livenode/room01 livenode/room01], seen.map { _1[3] }
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
                               declarations: ->(key, from) { profiles.topic(key, from: from) }).open
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

  test "a sender that connects again at once while recording: a new run, a channel of its own, nothing lost" do
    path = @dir.join("restart.mcap")
    rec = Bridge::Recorder.new(id: 3, path: path, max_bytes: 1024 * 1024, max_seconds: 60).open
    sub = @z.subscribe("asterism/livenode/quick/**", depth: 64) { rec.key("asterism/livenode/quick/**", _1) }
    rec.lost = -> { sub.dropped.to_i }
    tell("restart")
    eventually { rec.progress["messages"] >= 7 }
    p = rec.progress
    assert_equal [ 0, 0, 1 ], p.values_at("lost", "gaps", "restarts"), "a new run is not a loss"
    sub.close
    rec.finish
    r = MCAP::Reader.new(path.to_s)
    chans = r.info["channels"].select { _1["topic"] == "asterism/livenode/quick/n" }
    runs = chans.map { _1["metadata"]["asterism_run"] }
    assert_equal 2, runs.uniq.size, "a channel per run"
    assert runs.all? { _1.to_i.between?(0, 0xffff) && _1 == _1.to_i.to_s }
    seqs = r.each_message.filter_map { |m, ch, _| [ ch.metadata["asterism_run"], m.sequence ] if ch.topic == "asterism/livenode/quick/n" }
    assert_equal [ [ 0, 1, 2 ], [ 0, 1, 2, 3 ] ], seqs.chunk_while { _1[0] == _2[0] }.map { |c| c.map(&:last) },
                 "each run numbered from 0, one by one"
  ensure
    r&.close
  end
end
