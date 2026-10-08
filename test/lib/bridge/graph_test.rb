require "test_helper"

# Bridge::Graph from inputs shaped like what zenohd 1.10.1 and rmw_zenoh
# 0.2.11 actually give (the IDs are made up).
class Bridge::GraphTest < ActiveSupport::TestCase
  ROUTER = "c1df5ae4175c56de269da5532ff80c51"
  BOARD = "172c3662b323eeb866864f759dad074d"   # client: an Asterism board
  CONSOLE = "9fd8e2c3751738c83869543407a78303" # client: the bridge's object layer
  READER = "05b7aa4274bb226aea1dbd76825220ef"  # client: the bridge's reader (leading zero)
  ROS = "a085c6bfd204b2bf9ddeb5c81bfbd7b3"     # peer: a ROS 2 node

  STRING = "std_msgs::msg::dds_::String_/RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18"
  QOS = "::,10:,:,:,,"

  def session(zid, whatami, port)
    { "links" => [ { "dst" => "tcp/[::ffff:192.0.2.10]:#{port}", "src" => "tcp/[::ffff:192.0.2.2]:7447" } ],
      "peer" => zid, "region" => "south:0:#{whatami}", "shm" => false, "weight" => nil, "whatami" => whatami }
  end

  def admin
    {
      ROUTER => {
        "router" => {
          "locators" => [ "tcp/192.0.2.2:7447" ], "metadata" => nil,
          "plugins" => { "rest" => {}, "storage_manager" => {} },
          "sessions" => [ session(BOARD, "client", 1), session(CONSOLE, "client", 2),
                         session(READER.sub(/\A0+/, ""), "client", 3), session(ROS, "peer", 4) ],
          "version" => "v1.10.1-1211779c built with rustc 1.97.1", "zid" => ROUTER
        },
        "linkstate" => { "north" => "graph {\n    0 [ label = \"#{ROUTER}\" ]\n}\n" },
        "tokens" => {
          "asterism/fmruby-aaaaaa" => { "routers" => [ ROUTER ], "peers" => [], "clients" => [ BOARD ] },
          "asterism/fmruby-aaaaaa/demo/screen" => { "routers" => [ ROUTER ], "peers" => [], "clients" => [ BOARD ] },
          "asterism/console" => { "routers" => [ ROUTER ], "peers" => [], "clients" => [ CONSOLE ] }
        }
      }
    }
  end

  def asterism
    %w[asterism/fmruby-aaaaaa asterism/fmruby-aaaaaa/demo/screen asterism/fmruby-aaaaaa/demo/info
       asterism/console asterism/a/b asterism/x//y]
  end

  def ros
    [ "@ros2_lv/0/#{ROS}/0/0/NN/%/%/talker",
     "@ros2_lv/0/#{ROS}/0/1/MP/%/%/talker/%chatter/#{STRING}/#{QOS}",
     "@ros2_lv/0/#{ROS}/0/2/MS/%/%/talker/%chatter_back/#{STRING}/#{QOS}",
     "@ros2_lv/0/#{ROS}/0/3/SS/%/%/talker/%talker%get_parameters/rcl_interfaces::srv::dds_::GetParameters_/RIHS01_ab/#{QOS}",
     "@ros2_lv/0/#{ROS}/0/4/XX/%/%/talker",
     "not/a/token" ]
  end

  def graph
    Bridge::Graph.build(admin: admin, asterism: asterism, ros: ros, self_node: "console", self_zids: [ READER ]).to_h
  end

  def node(g, id)
    g["nodes"].find { _1["id"] == id } || flunk("no node #{id}: #{g['nodes'].map { _1['id'] }}")
  end

  def edge?(g, kind, source, target)
    g["edges"].any? { _1["kind"] == kind && _1["source"] == source && _1["target"] == target }
  end

  test "the router and its sessions" do
    g = graph
    r = node(g, "router:#{ROUTER}")
    assert_equal "infra", r["layer"]
    assert_equal [ "tcp/192.0.2.2:7447" ], r["data"]["locators"]
    assert_equal "v1.10.1-1211779c", r["data"]["version"]
    assert_equal %w[rest storage_manager], r["data"]["plugins"]
    s = node(g, "session:#{BOARD}")
    assert_equal "client", s["data"]["whatami"]
    assert_equal "tcp/[::ffff:192.0.2.10]:1", s["data"]["address"]
    assert edge?(g, "session", "router:#{ROUTER}", "session:#{BOARD}")
    assert_equal "peer", node(g, "session:#{ROS}")["data"]["whatami"]
  end

  test "Asterism nodes, apps and objects, and the session that carries them" do
    g = graph
    node(g, "a_node:fmruby-aaaaaa")
    node(g, "a_app:fmruby-aaaaaa/demo")
    o = node(g, "a_object:fmruby-aaaaaa/demo/screen")
    assert_equal "fmruby-aaaaaa/demo/screen", o["data"]["path"]
    assert edge?(g, "has_app", "a_node:fmruby-aaaaaa", "a_app:fmruby-aaaaaa/demo")
    assert edge?(g, "exposes", "a_app:fmruby-aaaaaa/demo", "a_object:fmruby-aaaaaa/demo/info")
    assert edge?(g, "carries", "session:#{BOARD}", "a_node:fmruby-aaaaaa")
    assert_equal "cross", g["edges"].find { _1["kind"] == "carries" }["layer"]
    # Keys of other shapes are not Asterism's objects.
    assert_nil g["nodes"].find { _1["id"] == "a_node:a" }
    assert_nil g["nodes"].find { _1["id"].include?("//") }
  end

  test "the console marks itself, its sessions too" do
    g = graph
    assert node(g, "a_node:console")["data"]["self"]
    assert node(g, "session:#{CONSOLE}")["data"]["self"], "the session carrying the console's node"
    assert node(g, "session:#{READER.sub(/\A0+/, '')}")["data"]["self"], "the reader, matched without the leading zero"
    refute node(g, "session:#{BOARD}")["data"]["self"]
  end

  test "ROS 2 nodes, topics with their types, and services" do
    g = graph
    n = node(g, "r_node:#{ROS}/0")
    assert_equal "/talker", n["data"]["name"]
    t = node(g, "r_topic:0/chatter")
    assert_equal "/chatter", t["label"]
    assert_equal "std_msgs/msg/String", t["data"]["type"]
    assert edge?(g, "publishes", "r_node:#{ROS}/0", "r_topic:0/chatter")
    assert edge?(g, "subscribes", "r_topic:0/chatter_back", "r_node:#{ROS}/0")
    svc = node(g, "r_service:0/talker/get_parameters")
    assert_equal "rcl_interfaces/srv/GetParameters", svc["data"]["type"]
    assert edge?(g, "serves", "r_service:0/talker/get_parameters", "r_node:#{ROS}/0")
    assert edge?(g, "carries", "session:#{ROS}", "r_node:#{ROS}/0")
    assert_equal 1, g["nodes"].count { _1["kind"] == "r_node" }
  end

  test "parse_ros_token" do
    t = Bridge::Graph.parse_ros_token("@ros2_lv/0/#{ROS}/0/1/MP/%/%ns/talker/%ns%chatter/#{STRING}/#{QOS}")
    assert_equal :publisher, t[:kind]
    assert_equal "/ns", t[:namespace]
    assert_equal "/ns/chatter", t[:name]
    assert_nil Bridge::Graph.parse_ros_token("@ros2_lv/0/#{ROS}/0/1/MP/%/%/talker")
    assert_nil Bridge::Graph.parse_ros_token("asterism/x")
  end

  test "router links from the linkstate and from router sessions" do
    other = "d00dfeed00000000000000000000beef"
    a = admin
    a[ROUTER]["linkstate"]["north"] = "graph {\n 0 [ label = \"#{ROUTER}\" ]\n 1 [ label = \"#{other}\" ]\n 0 -> 1 [ label = \"1\" ]\n}\n"
    g = Bridge::Graph.build(admin: a).to_h
    node(g, "router:#{other}")
    assert edge?(g, "router_link", "router:#{ROUTER}", "router:#{other}")

    a = admin
    a[ROUTER]["router"]["sessions"] << session(other, "router", 5)
    g = Bridge::Graph.build(admin: a).to_h
    assert edge?(g, "router_link", "router:#{ROUTER}", "router:#{other}")
    assert_nil g["nodes"].find { _1["id"] == "session:#{other}" }
  end

  test "the same network gives the same graph, and the diff names what changed" do
    a = graph
    assert_equal a, graph
    assert Bridge::Graph.empty_diff?(Bridge::Graph.diff(a, graph))

    b = Bridge::Graph.build(admin: admin, asterism: asterism - [ "asterism/fmruby-aaaaaa/demo/info" ], ros: ros,
                            self_node: "console", self_zids: [ READER ]).to_h
    d = Bridge::Graph.diff(a, b)
    assert_equal [ "a_object:fmruby-aaaaaa/demo/info" ], d["remove_nodes"]
    assert_equal [ "exposes:a_app:fmruby-aaaaaa/demo->a_object:fmruby-aaaaaa/demo/info" ], d["remove_edges"]
    assert_empty d["add_nodes"]

    d = Bridge::Graph.diff(b, a)
    assert_equal [ "a_object:fmruby-aaaaaa/demo/info" ], d["add_nodes"].map { _1["id"] }

    d = Bridge::Graph.diff({ "nodes" => [], "edges" => [] }, a)
    assert_equal a["nodes"].size, d["add_nodes"].size
  end

  test "a change of a node's data is a change, not a remove and an add" do
    a = graph
    adm = admin
    adm[ROUTER]["router"]["sessions"].pop
    b = Bridge::Graph.build(admin: adm, asterism: asterism, ros: ros, self_node: "console", self_zids: [ READER ]).to_h
    d = Bridge::Graph.diff(a, b)
    assert_includes d["remove_nodes"], "session:#{ROS}"
    assert_equal [ "router:#{ROUTER}" ], d["change_nodes"].map { _1["id"] }
  end

  # Two routers joined by mutual TLS, as zenohd 1.10.1 tells it from each
  # side (the home router connects out to the cloud one).
  HOME = "cc08bfcde72b91280a1274d1cd78dc7e"
  CLOUD = "d5e0deae1c2513eb274afb6f7b4d1de1"

  def relay_admin
    home_link = { "dst" => "tls/192.0.2.20:7448", "src" => "tls/192.0.2.30:60652" }
    {
      HOME => {
        "router" => { "locators" => [ "tcp/192.0.2.30:7447" ], "metadata" => { "name" => "zenohd-home" },
                      "sessions" => [ { "links" => [ home_link ], "peer" => CLOUD, "region" => "north", "whatami" => "router" },
                                      session(BOARD, "client", 1) ],
                      "version" => "v1.10.1-1211779c", "zid" => HOME },
        "linkstate" => { "north" => "graph {\n    0 [ label = \"#{HOME}\" ]\n    1 [ label = \"#{CLOUD}\" ]\n    1 -- 0 [ label = \"100\" ]\n}\n" },
        "tokens" => {}
      },
      CLOUD => {
        "router" => { "locators" => [ "tls/192.0.2.20:7448" ], "metadata" => { "name" => "zenohd-cloud" },
                      "sessions" => [ { "links" => [ { "dst" => home_link["src"], "src" => home_link["dst"] } ],
                                        "peer" => HOME, "region" => "north", "whatami" => "router" },
                                      { "links" => [ { "dst" => "tls/192.0.2.1:39968", "src" => "tls/192.0.2.20:7448" } ],
                                        "peer" => READER, "region" => "south:0:client", "whatami" => "client" } ],
                      "version" => "v1.10.1-1211779c", "zid" => CLOUD },
        "linkstate" => { "north" => "graph {\n    0 [ label = \"#{CLOUD}\" ]\n    1 [ label = \"#{HOME}\" ]\n    0 -- 1 [ label = \"100\" ]\n}\n" },
        "tokens" => {}
      }
    }
  end

  test "two routers: one router_link with its protocol, names, links and certificate names" do
    g = Bridge::Graph.build(admin: relay_admin, self_zids: [ READER ],
                            own_links: { CLOUD => { "protocol" => "tls", "cert_name" => "zenohd-cloud" } },
                            self_cert: "console").to_h
    links = g["edges"].select { _1["kind"] == "router_link" }
    assert_equal 1, links.size
    assert_equal [ "router:#{HOME}", "router:#{CLOUD}" ].sort, [ links[0]["source"], links[0]["target"] ].sort
    assert_equal "tls", links[0]["label"]

    home = node(g, "router:#{HOME}")
    cloud = node(g, "router:#{CLOUD}")
    assert_equal "router zenohd-home", home["label"]
    assert_equal "router zenohd-cloud", cloud["label"]
    assert_equal [ CLOUD ], home["data"]["router_links"].map { _1["peer"] }
    assert_equal "tls", home["data"]["router_links"][0]["protocol"]
    assert_equal "zenohd-cloud", cloud["data"]["cert_name"]
    assert_nil home["data"]["cert_name"]

    reader = node(g, "session:#{READER.sub(/\A0+/, '')}")
    assert_equal "tls", reader["data"]["protocol"]
    assert_equal "console", reader["data"]["cert_name"]
    board = node(g, "session:#{BOARD}")
    assert_equal "tcp", board["data"]["protocol"]
    assert_nil board["data"]["cert_name"]
    assert edge?(g, "session", "router:#{HOME}", "session:#{BOARD}")
  end
end
