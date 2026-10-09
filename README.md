# Asterism Console

A Rails app that shows a Zenoh network as a live graph in the browser and
calls the methods that Asterism nodes expose.

- **Routers and sessions** from the router's admin space (`@/<zid>/router`,
  its linkstate and token table).
- **Asterism** nodes from their liveliness tokens (`asterism/**`), each a
  box holding its apps, each app a box holding its exposed objects.
- **ROS 2** nodes from rmw_zenoh's liveliness tokens (`@ros2_lv/**`), like
  rqt_graph's nodes-only view: a topic is an edge from the node that
  publishes it to the node that subscribes to it, labelled with its name
  (and rate). A node's services, and its topics nobody is at the other end
  of, are its attributes: a badge (services in red, unmatched topics in
  orange) and the details. "Topics as nodes" draws the topics as nodes
  between their ends instead; "Hide /rosout, /parameter_events" (on by
  default) leaves out the topics every rclcpp node has.
- **Topic rates** like rqt_topic: rate (Hz), bandwidth, the number of
  messages and the last one (time, size, a short preview: strings,
  numbers, `geometry_msgs` vectors and twists, `/rosout` lines, the header
  of stamped messages, the picture of a JPEG or PNG
  `sensor_msgs/CompressedImage`), on the edges and in the details (below).
- **Plots** like rqt_plot (`/plots`): numeric fields of ROS 2 topics
  (decoded with the real message types) and of Asterism keys (MessagePack)
  over time, several fields per plot and several plots, a 10 / 30 / 60 s
  window, pause.
- **Logs** like rqt_console (`/logs`): `/rosout` and the Asterism log keys,
  filtered by level, node and text, with pause and clear.
- **Recordings** like rosbag and rqt_bag (`/recordings`): ROS 2 topics,
  Asterism keys and the network structure into one MCAP file (CDR,
  MessagePack and JSON), which `ros2 bag info` and Foxglove open; upload a
  file from `ros2 bag record -s mcap`; a timeline with the messages at a
  cursor and plots; the graph as it was at any time; playback in the page
  or, for admins, to the network (see [Recordings](#recordings)).

Nodes appear and disappear without reloading, and what is on the screen
stays where it is: only new nodes are placed, next to their neighbours
("Lay out again" lays out everything; fcose, compound-aware). Click an
Asterism object to see its exposed methods and call them with JSON
arguments (the return value, `RemoteError` or `TimeoutError`, and the time it
took). Click a ROS 2 node for its topics and services (the parameter ones
folded), a topic edge or a topic for its type, ends, rate and last value.
The watch panel shows the values arriving on any key (a camera's
`sensor_msgs/CompressedImage` also as its latest picture). A topic's details
have "Plot this topic", a ROS 2 node's "Show its logs" (see
[Plots and logs](#plots-and-logs)).

Everything needs a signed-in user: the graph, the values, the calls and
the WebSocket. What the page may call is limited to the combinations an
admin allowed, and every call is logged (see [Security](#security)).

## Running it

Needs Ruby 3.2+, a zenohd router (1.x; the admin space is readable with
the default configuration) and the two Asterism gems.

```
bundle install
bin/rails db:prepare
bin/rails console:user EMAIL=me@example.org ADMIN=1   # asks for a password (12+ characters)
bin/rails server            # http://127.0.0.1:3000
bin/bridge                  # in another terminal: the one process on the network
```

`bin/dev` starts both. Sign in, then allow what the page may call under
"Call permissions" (nothing can be called until then).

| Variable | Default | |
|---|---|---|
| `ASTERISM_ROUTER` | `tcp/127.0.0.1:7447` | the router the bridge connects to |
| `ASTERISM_TLS_CA` | | TLS: the CA of the router's certificate |
| `ASTERISM_TLS_CERT`, `ASTERISM_TLS_KEY` | | mutual TLS: the bridge's certificate and key |
| `ASTERISM_ZENOH_CONFIG` | | a zenoh configuration file (JSON5) for both sessions, instead of the three above |
| `ASTERISM_CONSOLE_NODE` | `console` | the bridge's Asterism node ID (app `console`) |
| `ASTERISM_RATES_MAX_BPS` | `8000000` | measuring all topics pauses above this many bytes per second (see Topic rates) |
| `CONSOLE_BIND` | `127.0.0.1` | the address the server listens on (see Security) |
| `CONSOLE_EXTRA_HOST` | | one more host name the development server answers to (e.g. `host.docker.internal` for a browser in a container) |
| `ASTERISM_DIR`, `ASTERISM_ZENOH_DIR` | `../asterism`, `../asterism-zenoh` | the gem checkouts |

The bridge reconnects by itself when the router goes away; stop it with
Ctrl-C (or TERM). Run exactly one: a second bridge cannot join as the same
node.

### The Asterism gems

The console needs asterism and asterism-zenoh 0.4.0 or later (the versions
in `Gemfile.lock`; V4 was checked with the asterism 0.4.1 checkout). The Gemfile takes them from the checkouts next to this
repository (`path:`, or `ASTERISM_DIR` / `ASTERISM_ZENOH_DIR`; build
asterism-zenoh's C extension there with `rake compile`, or let Bundler
build it). To use the gems from rubygems.org instead, replace the two
`path:` lines of the Gemfile with

```ruby
gem "asterism", "~> 0.4.0", require: false   # asterism-zenoh comes with it
```

and run `bundle install`. Installing asterism-zenoh compiles a C extension
against the prebuilt zenoh-c release it pins (a C compiler is all it
needs; see asterism-zenoh's README for using a zenoh-c of your own).

The console uses no call that 0.4.0 deprecates. To check after a change,
run the tests and the bridge with deprecated calls raising:

```
ASTERISM_DEPRECATIONS=raise bin/rails test
ASTERISM_DEPRECATIONS=raise bin/bridge
```

## Plots and logs

- **Plots** (`/plots`): pick a ROS 2 topic or type an Asterism key, tick
  fields (the list comes from the topic's type, and from the values seen) or
  type a path (`linear.x`, `position[2]`, `poses[0].pose.position.x`), and
  add them to a plot (at most 8 series each). ROS 2 messages are decoded by
  the bridge with the generated types of the asterism gem (its `data/msgs`)
  and the console's `vendor/msgs` (`rcl_interfaces/msg/Log`); a topic whose
  type is not among them says "type ... is not bundled". An Asterism key's
  payload is MessagePack (a Hash: paths into it; a number: path `""`).
- **Logs** (`/logs`): time, level, node (logger name), message, file:line
  and function; filters for the level (at least), the node and a text; the
  last 2000 lines. Asterism nodes can log on `asterism/<node>/<app>/log`
  as a MessagePack Hash `{"level", "msg", "time"}` (a proposal; docs/v3.md).
- **Cost**: the bridge subscribes only while such a page is open
  (`StreamLease`, renewed every 10 s, 30 s, released when the page is left)
  and keeps at most 30 messages a second of each plotted topic, so a fast
  topic costs its traffic and a counter per message, not its decoding. At
  most 16 plotted topics, 200 log lines a second. Details, bounds and the
  live check: docs/v3.md.

## Recordings

`/recordings` (V4, the roles of rosbag and rqt_bag; details in docs/v4.md):

- **Record**: tick ROS 2 topics (those on the network now), type Asterism
  key expressions, tick "the network structure", set the limits (MB,
  seconds) and start. The bridge subscribes and writes
  `storage/recordings/<time>-<random>.mcap` (gitignored) until you stop it
  or a limit is reached; the page shows messages, bytes, the duration, the
  count per channel and any messages lost on the way. At most 2 at once,
  512 MB and an hour each, `ASTERISM_RECORDINGS_MAX_BYTES` (4 GB) for all.
- **The file**: one MCAP file. ROS 2 topics as rosbag2 writes them (CDR,
  schema `ros2msg` with the concatenated .msg definitions, the topic's QoS
  and type hash in the channel), Asterism keys as MessagePack, the network
  structure as JSON on `/asterism/graph` (a snapshot, then the changes).
  `ros2 bag info file.mcap` lists all of it; `ros2 bag play` refuses a file
  whose channels are not all CDR, so "ROS 2 topics only" downloads the
  copy it plays.
- **Upload** an `.mcap` (for example from `ros2 bag record -s mcap`; up to
  256 MB). Uncompressed chunks (rosbag2's default) are read; zstd or lz4
  chunks (`--storage-preset-profile zstd_fast`, `--compression-mode`) list
  their channels and message times but not the messages.
- **Timeline**: a row per channel with its message ticks, a cursor (click,
  drag, or step to the previous / next message), the selected channel's
  message at the cursor decoded (V3's decoders: the bundled ROS 2 types,
  MessagePack, `/rosout` and the Asterism log key as log lines), every
  channel's message at the cursor (pictures of compressed images too), and
  plots of numeric fields over the whole recording (the cursor follows a
  click on the plot).
- **The network at the cursor**: the graph page, read-only, as it was at
  a time; step from one change to the next (what appeared, what left).
- **Playback**: "in the page only" moves the cursor at 0.25x / 1x / 4x and
  sends nothing. "To the network" (admins, after a confirmation)
  republishes from the cursor: ROS 2 topics through a ROS 2 node of the
  console's own (`/asterism_console_playback`: its liveliness tokens, GID,
  new sequence numbers and times, so `ros2 topic echo` sees it), Asterism
  keys as they were recorded; never the network structure. Each playback
  is a row of the audit log ("Call log" page).

**MCAP in Ruby** (`lib/mcap.rb`, `lib/mcap/writer.rb`, `lib/mcap/reader.rb`):
a writer and a reader of the MCAP format (version 0, https://mcap.dev)
with the standard library only, kept apart from the console (no Rails, no
Asterism) so it can become a gem. The writer makes chunked, indexed files
(chunks uncompressed, with message indexes, chunk indexes, statistics,
summary offsets and every CRC); the reader uses the summary when there is
one and scans otherwise (a file cut off mid-record reads up to the last
whole record), and gives the message index without reading the messages.
zstd and lz4 are not in Ruby's standard library: compressed chunks raise
`MCAP::UnsupportedCompression` (the summary and index still read). Its
tests: `test/lib/mcap/` (round trips, CRCs, files without a summary, cut-off
files, unknown records, a file written by rosbag2, a zstd one).

## Two routers: a relay with mutual TLS and an ACL

The bridge can watch a network of several routers: it reads every router's
`@/<zid>/router` (one query, `@/*/router`, reaches all of them), draws each
router and one `router_link` edge per pair of routers (labelled with the
link's protocol), and the sessions on both sides. The details of a router
list its links to other routers (protocol and both ends); a session shows
its link's protocol. Certificate names: zenohd keeps them per link in the
session part of its admin space (`@/<zid>/session/transport/unicast/<peer>/link/<id>`,
`auth_identifier`), which answers queries from inside the router only (its
REST plugin), not from the network. So the console shows the certificate
of the router it is connected to (from its own link) and its own; the
others show as not known.

`script/relay_certs` makes a CA and certificates for such a relay
(`lib/relay/cert_authority.rb`, Ruby's OpenSSL; ECDSA P-256 keys, the
common name is what zenohd's ACL matches). They go to
`storage/relay/certs/`, which git ignores. Never commit them.

```
script/relay_certs                       # CA + zenohd-cloud, zenohd-home, console, cruby, ros2-cloud
script/relay_certs --rogue               # also a second CA (to see the cloud router refuse it)
script/relay_certs mybot                 # one more name from the same CA
```

The family-mruby repository has the routers (`docker-compose.relay.yml`,
`docker/zenoh-relay/`): a home router for the boards (plain TCP 7447) that
connects out to a cloud router over mutual TLS (7448). The cloud router's
ACL lets the console, and only it, read the admin space (`@/**`). The bridge
then connects to the cloud router:

```
C=storage/relay/certs
ASTERISM_ROUTER=tls/localhost:7448 ASTERISM_TLS_CA=$C/ca.pem \
  ASTERISM_TLS_CERT=$C/console.pem ASTERISM_TLS_KEY=$C/console.key bin/bridge
```

The name in the locator must be one the router's certificate is valid for
(`localhost` here). A Ruby node connects the same way (`config:`, see the
asterism README).

`script/relay_certs` is the quick start: its CA key sits next to the
certificates. Once the console issues certificates, the CA moves into the
signer (next section) and `script/relay_certs` refuses to run on that
directory.

## The relay registry: certificates, ACL, apply

Under "Relay" the console keeps the registry of the routers and clients
the cloud router lets in, issues their certificates through a separate
signer, makes the cloud router's configuration from the registry and
applies it.

```
 browser --> Rails (registry, ledger, apply) --HTTP 127.0.0.1 + token--> bin/signer (the CA's key)
                 |  writes storage/relay/generated/cloud.json5
                 +--> docker compose restart zenohd-cloud (reads /generated/cloud.json5)
```

- **One name for everything.** A peer's name is its certificate's common
  name, its subject in the cloud router's ACL and, by convention, its
  Asterism node ID (a client) or its router name (`metadata/name`). The
  graph matches nodes to the registry by it.
- **Registry** (admins edit, everyone signed in reads): kind (router /
  client), description, keys it may read and write, keys it may only read
  (one key expression per line), whether it reads the admin space (a
  client) or has its admin space read through (a router), enabled,
  certificate lifetime, extra DNS names / IPs for a router that listens.
  Reading a key also lets it query it, and an Asterism call is a query.
- **The signer** (`bin/signer`, plain Ruby) is the only process that holds
  the CA's private key. Rails makes the peer's key and a certificate request,
  the signer checks the request and signs it for the peer's name (at most
  825 days) and logs it in its own `issued.log`; Rails records the
  certificate in its ledger (serial, dates, fingerprint, who) and answers
  with a tar of the key, the certificate, the CA and an example
  configuration. **The key is in that download only**; it is not stored.
  Run the signer where Rails cannot read its directory: its own user, or a
  container with the CA in a docker volume:

  ```
  script/signer_docker import storage/relay/certs/ca.pem storage/relay/certs/ca.key
  rm storage/relay/certs/ca.key            # the signer has its own copy now
  script/signer_docker up                  # 127.0.0.1:7450; token in storage/relay/signer.token
  ```

  (`script/signer_docker init` makes a new CA instead.) Rails finds it
  with `ASTERISM_SIGNER_URL` and the token file (or `ASTERISM_SIGNER_TOKEN`).
  `bin/rails relay:import` records certificates made before (by
  `script/relay_certs`) in the ledger.
- **Configuration** (`lib/relay/cloud_config.rb`): the TLS part as in W1 and
  the ACL, one subject per peer that is enabled and has a valid certificate
  (default deny; read-write keys get every message type both ways,
  read-only keys only subscribing and querying from the peer). The file
  starts with a line saying it is generated; the database is the source.
  `bin/rails relay:show` prints it, `relay:generate` writes it.
- **Apply** ("Relay" > "Apply"): shows who joins and leaves the ACL, the
  sessions and router links on the cloud router that the restart will cut,
  and the file; then writes `storage/relay/generated/cloud.json5` and runs
  `docker compose -f docker-compose.yml -f docker-compose.relay.yml restart
  zenohd-cloud` in the family-mruby directory (`ASTERISM_RELAY_GENERATED_DIR`,
  `ASTERISM_RELAY_COMPOSE_DIR`, `ASTERISM_RELAY_RESTART`), and reports what
  came back. The cloud router must have been created reading that file:

  ```
  ASTERISM_RELAY_GENERATED=./asterism-console/storage/relay/generated \
  ASTERISM_RELAY_CLOUD_CONFIG=/generated/cloud.json5 \
    docker compose -f docker-compose.yml -f docker-compose.relay.yml up -d zenohd zenohd-cloud
  ```

  What a restart does to the others: the home router and the bridge connect
  again by themselves; Asterism nodes on the cloud router (CRuby) lose their
  connection and must be restarted; ROS 2 peers (rmw_zenoh's default peer
  mode) keep their data flowing but their liveliness tokens are not taken
  back by zenohd 1.10.1, so their nodes leave the graph until they restart
  (in client mode they come back).
- **Shutting someone out**: disable it (or revoke its only certificate) and
  apply. Its TLS link still opens (zenohd 1.10.1 has no revocation list; the
  certificate is good until it expires, and `close_link_on_expiration` then
  closes it), but the ACL denies it everything. A second valid certificate
  with the same name is not told apart: the ACL matches the name. Keep
  lifetimes short.
- **The graph**: the "Relay registry" layer puts a halo on Asterism nodes and
  routers: green (registered), orange (here but disabled), red (not in the
  registry), and adds a grey node for each registered name that is not here.
  Names that are neither node IDs nor router names (a ROS 2 peer's
  certificate) cannot be matched and show as not here.

## Security

The console calls methods on the boards of a network, so it is guarded
even on a LAN. What it does, and what it assumes:

- **Sign-in for everything.** Rails 8's authentication (`has_secure_password`,
  bcrypt). Every controller requires a signed-in user except the sign-in
  pages; JSON requests without one get 401. Action Cable takes the same
  signed cookie and refuses the connection without it, so graph diffs,
  answers and watched values reach signed-in browsers only. There is no
  setting that turns sign-in off. A session lasts 12 hours; sign-in is
  rate limited (10 tries in 3 minutes).
- **Accounts** are made on the command line (there is no sign-up page). The
  password is read from the terminal or `CONSOLE_PASSWORD`, never from the
  command line:

  ```
  bin/rails console:user EMAIL=me@example.org ADMIN=1    # make (or set a new password)
  bin/rails console:users                                # list
  bin/rails console:otp_off EMAIL=me@example.org         # a user who lost the device
  ```

- **Two-factor sign-in (TOTP, optional per user).** On the account page,
  "Turn on" shows a secret (and its `otpauth://` URI) to add to an
  authenticator app; a code confirms it. From then on signing in asks for a
  code after the password. Each code is taken once (the `rotp` gem).
- **Call permissions.** The page can read an object's methods and call one
  only when a row under "Call permissions" allows the object's path
  (`<node>/<app>/<object>`) and the method; `*` matches any run of
  characters within one part. No rows (the default): nothing can be called.
  Only admins add or remove rows. Rails checks before a request reaches
  the bridge, and the bridge checks again before it calls.
- **Call log.** Every request is kept: who, when, the path, method and
  arguments, and the answer (`ok`, `remote_error`, `timeout`, ...), refused
  ones as `denied`. "Call log" shows the last 200.
- **Listening.** The server listens on 127.0.0.1 (in every environment).
  `CONSOLE_BIND=0.0.0.0` (or `-b`) opens it to other machines; it then
  refuses to start while there are no users. Sign-in sends a password and
  the cookie in the clear over plain HTTP: beyond this machine, put a TLS
  proxy in front (and set `config.assume_ssl` / `force_ssl` in production).
- **The CA's key** is the signer's only (above). In this repository's
  setup the console's user can still run docker, and so could reach the
  signer's volume; on a server, run Rails as a user without docker rights
  and give `ASTERISM_RELAY_RESTART` a narrow helper (a sudo rule for the one
  restart) instead.
- **What it does not do**: no roles beyond admin / user, no limit on who may
  watch which keys, no lockout beyond the rate limit, no password reset by
  mail (an admin sets a new password with `console:user`).

## How it is built

```
 browser  <-- Action Cable (solid_cable) --  bin/bridge  <-- Zenoh -->  zenohd
    |                                          |   ^
    +-- HTTP: page, requests, watches --> Puma  |   |  (SQLite: graph, requests,
                                          +-----+---+   watches, cable messages)
```

- **Puma never talks to Zenoh.** Only `bin/bridge` (lib/bridge/runner.rb)
  loads Asterism, so however many Puma workers or threads run, the network
  sees one node. (The recording pages decode messages in Puma with the
  asterism gem's pure-Ruby type layer alone, its `mrblib/` files, without
  asterism-zenoh: `Bridge::Types.setup`.) The bridge loads the Rails environment for the database
  and Action Cable.
- **Delivery across processes**: Action Cable uses solid_cable in
  development too (config/cable.yml), so a broadcast from the bridge
  reaches the browsers connected to Puma. Everything goes on one stream
  (`ConsoleChannel`): `graph_diff` (versioned; the page asks for the whole
  graph, `GET /graph`, when it missed one), `bridge` (a heartbeat),
  `request` (an answer), `sample` (a watched value), `watch` / `unwatch`.
- **The graph**: `Bridge::Graph` (lib/bridge/graph.rb, pure Ruby) builds
  typed nodes and edges from the admin space and the two sets of tokens;
  the bridge keeps the latest in `GraphState` and broadcasts the diff.
  The admin space is read every 2 s, tokens follow liveliness at once.
- **Calls from the page** go through the database: the page creates a
  `BridgeRequest` (meta or call, with a timeout up to 30 s), the bridge
  picks it up, runs it through an Asterism proxy (`Bridge::Objects`) and writes
  the answer back. Methods that are not exposed are refused by the node
  that owns the object (`RemoteError NoMethodError ... (not exposed)`).
- **Plots and logs** (`Bridge::Plots`, `Bridge::Logs`, `Bridge::Fields`,
  `Bridge::Types`): `StreamLease` rows, read every 0.5 s like the rate
  leases; the points and lines go every 0.2 s on streams of their own
  (`ConsoleChannel` with `stream: "plots"` / `"logs"`). The bridge alone
  loads the message types (Puma still never loads Asterism). The charts are
  uPlot (vendored by `bin/importmap pin`, its CSS in `vendor/assets`).
- **Watches** are rows too; the bridge subscribes to each key and sends at
  most 10 values per key and second (text, MessagePack, ROS 2 CDR decoded
  as for the rates, or hex).
- **Topic rates** (`Bridge::Rates`) are measured only while a page asks:
  "Measure all topics" (the page renews a `RateLease` "*" every 10 s; it
  lasts 30 s) subscribes to `<domain>/**` once per ROS 2 domain, and the
  details of a topic or topic edge lease just those topics
  (`<domain>/<name>/**`). Per topic the bridge counts messages and bytes in
  one-second buckets over a 5 s window and keeps the first 4 KB of the last
  message; it decodes the preview only when a new one came, and broadcasts
  what changed once a second (`rates`). At most 300 topics. **The cost**:
  every message of every measured topic reaches the bridge (over a relay,
  across it), so "all topics" with a camera on the network is that
  camera's bandwidth. When the measured topics together bring in more than
  `ASTERISM_RATES_MAX_BPS` (default 8000000 bytes/s) the bridge drops the
  wildcards for 60 s (single topics go on) and the page says so.
- **Recordings and playbacks** are rows too (`Recording`, `Playback`): the
  bridge starts what is pending, writes with `Bridge::Recorder` (on the
  receiving thread, under a lock) and plays with `Bridge::Player` (a thread
  of its own); the pages read the files with `Bag::View` (lib/bag/).

## Tests

```
bin/rails test
```

`test/lib/bridge/` covers the graph (from inputs shaped like zenohd 1.10.1
and rmw_zenoh 0.2.11 give them, and the busy fixture: services as
attributes, topic edges, unmatched topics, nesting), the diff, payloads and
CDR previews, the rates (window, aggregation, bounds), what the bridge
subscribes to for the rate leases, and how it writes answers back, the
plots and logs (field paths, decimation, bounds, /rosout with the generated
Log type, the Asterism log key, the stream leases), recording and playback
(the recorder's files, its limits, the player's wire output, the bridge's
rows); `test/lib/mcap/` and `test/lib/bag/` the MCAP format and the timeline's
reading; `test/controllers/` the page, the graph JSON,
requests, watches, sign-in (with TOTP), that every route needs it, the call
permissions and the call log; `test/channels/` that the WebSocket needs it.

**Fixture mode** (development only): `CONSOLE_FIXTURE=1 bin/rails server`
shows a recorded network instead of the bridge's
(`test/fixtures/files/busy_network.json`: two routers, Asterism boards,
a sim, CRuby and a dozen ROS 2 nodes; or `CONSOLE_FIXTURE=<file>`). The file
holds the inputs of `Bridge::Graph.build`, so the page shows them through
the current code. It uses its own databases (`storage/fixture*.sqlite3`;
`CONSOLE_FIXTURE=1 bin/rails db:prepare` and `console:user` once), and
`bin/bridge` refuses to run in it.

`script/headless/run out.png` takes a screenshot with a headless Chromium
in a container (Playwright's image; nothing installed on the host);
`CONSOLE_EMAIL` / `CONSOLE_PASSWORD` make it sign in first.

## License

MIT (LICENSE). Third-party code included in this repository is listed in NOTICE
(Cytoscape.js and the fcose layout, uPlot: MIT; a ROS 2 message type
generated from its Apache-2.0 definition; ROS 2 .msg definitions, Apache-2.0,
in `vendor/msgdefs`).
