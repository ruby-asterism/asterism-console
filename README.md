# Asterism Console

A Rails app that shows a Zenoh network as a live graph in the browser and
calls the methods that Asterism nodes expose.

- **Routers and sessions** from the router's admin space (`@/<zid>/router`,
  its linkstate and token table).
- **Asterism** nodes, apps and exposed objects from their liveliness tokens
  (`asterism/**`).
- **ROS 2** nodes, topics (publishers / subscribers, with their types) and
  services from rmw_zenoh's liveliness tokens (`@ros2_lv/**`).

Nodes appear and disappear without reloading. Click an Asterism object to
see its exposed methods and call them with JSON arguments (the return
value, `RemoteError` or `Timeout`, and the time it took). Click a ROS 2
topic for its type, publishers and subscribers. The watch panel shows the
values arriving on any key.

> **No authentication.** The console is for a local network you trust.
> Anyone who can open the page can call every exposed method on the
> network. The bridge connects to a router on 127.0.0.1 and the server
> listens on 127.0.0.1 by default. Do not open either to other machines
> before authentication is added.

## Running it

Needs Ruby 3.2+, a zenohd router (1.x; the admin space is readable with
the default configuration) and the two Asterism gems.

```
bundle install
bin/rails db:prepare
bin/rails server            # http://127.0.0.1:3000 (development)
bin/bridge                  # in another terminal: the one process on the network
```

`bin/dev` starts both.

| Variable | Default | |
|---|---|---|
| `ASTERISM_ROUTER` | `tcp/127.0.0.1:7447` | the router the bridge connects to |
| `ASTERISM_TLS_CA` | | TLS: the CA of the router's certificate |
| `ASTERISM_TLS_CERT`, `ASTERISM_TLS_KEY` | | mutual TLS: the bridge's certificate and key |
| `ASTERISM_ZENOH_CONFIG` | | a zenoh configuration file (JSON5) for both sessions, instead of the three above |
| `ASTERISM_CONSOLE_NODE` | `console` | the bridge's Asterism node ID (app `console`) |
| `CONSOLE_EXTRA_HOST` | | one more host name the development server answers to (e.g. `host.docker.internal` for a browser in a container) |
| `ASTERISM_DIR`, `ASTERISM_ZENOH_DIR` | `../asterism`, `../asterism-zenoh` | the gem checkouts |

The bridge reconnects by itself when the router goes away; stop it with
Ctrl-C (or TERM). Run exactly one: a second bridge cannot join as the same
node.

### The Asterism gems

Until 0.3.0 is on rubygems.org, the Gemfile takes them from the checkouts
next to this repository (`path:`; build asterism-zenoh's C extension there
with `rake compile`, or let Bundler build it). Once they are published,
replace the two `path:` lines with

```ruby
gem "asterism", "~> 0.3.0", require: false   # asterism-zenoh comes with it
```

and run `bundle install`.

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

Keep the CA's key (`ca.key`) away from a server that faces the network once
certificates are issued from the page (planned).

## How it is built

```
 browser  <-- Action Cable (solid_cable) --  bin/bridge  <-- Zenoh -->  zenohd
    |                                          |   ^
    +-- HTTP: page, requests, watches --> Puma  |   |  (SQLite: graph, requests,
                                          +-----+---+   watches, cable messages)
```

- **Puma never talks to Zenoh.** Only `bin/bridge` (lib/bridge/runner.rb)
  loads Asterism, so however many Puma workers or threads run, the network
  sees one node. The bridge loads the Rails environment for the database
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
  picks it up, runs it with `Asterism.meta` / `Asterism.call` and writes
  the answer back. Methods that are not exposed are refused by the node
  that owns the object (`RemoteError NoMethodError ... (not exposed)`).
- **Watches** are rows too; the bridge subscribes to each key and sends at
  most 10 values per key and second (text, MessagePack, ROS 2 CDR strings
  or hex).

## Tests

```
bin/rails test
```

`test/lib/bridge/` covers the graph (from inputs shaped like zenohd 1.10.1
and rmw_zenoh 0.2.11 give them), the diff, payloads and how the bridge
writes answers back; `test/controllers/` the page, the graph JSON,
requests and watches.

`script/headless/run out.png` takes a screenshot with a headless Chromium
in a container (Playwright's image; nothing installed on the host).

## License

MIT (LICENSE). Third-party code included in this repository is listed in NOTICE
(Cytoscape.js, MIT).
