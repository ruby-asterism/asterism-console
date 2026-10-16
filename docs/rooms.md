# Rooms (G2)

A room is a key space of its own on the cloud router that anyone with the
room's link joins from a browser, without an account, for a few hours. It
is for people you invite: a game evening, an event, friends for a day. The
devices you registered (home routers, boards, CRuby with certificates) keep
using certificates and roles as before; rooms come on top and do not mix
with them.

| | Registered (certificates) | Rooms |
|---|---|---|
| Who | your routers, boards, robots, long-running things | people you invite for a while |
| Getting in | a certificate from the console's CA (mutual TLS, port 7448) | the room's link (a signed key), through the door (`wss://.../room`) |
| How long | the certificate's days | the room's hours (3 unless said, at most 24) |
| Keys | what the roles allow | the room's key space only: `room/<slot>/**`; inside it each page writes and calls only under its seat's node ID (0.3.0) |
| Made by | an admin | an admin (Admin > Rooms) |

## The parts

```
 browser (room link) --POST /room/seat {t, s}--> nginx --> door (7452): a seat for the page's secret
                     --wss:///room?t=<key>, first message {s}--> door --mutual TLS as room-<slot>-s<seat>--> zenohd tls/7448
                                                         |  reads /rooms/rooms.json, /rooms/certs/; writes /seats/seats.json
 console --(signs keys)--> signer (the rooms' signing key, like the CA's key)
         --(writes)------> /rooms/rooms.json (the signer's public keys, the open rooms, the closed ones)
```

- **Room slots.** zenohd 1.10.1 reads its ACL once, when it starts, so a
  room cannot get an ACL of its own when it is made. Instead there are
  `ASTERISM_ROOM_SLOTS` (8) slots, `room-01` ... `room-08`, each a row of the
  registry with a certificate (its key made on the server by `bin/asterism
  setup`, like the router's and the bridge's) whose ACL is the slot's key
  space only: `room/<slot>/**`, and `room/<slot>/**/@adv/**`, since `**`
  never matches a chunk that starts with `@` and zenoh-ext's advanced
  publishers and subscribers (history, recovery) use such keys. A room
  takes a free slot; making or closing a room restarts nothing.
- **The room's key** (`lib/relay/room_token.rb`): `base64url(claims) "."
  base64url(Ed25519 signature)`, with the room's ID, its slot, its end, its
  connection limit, a random ID and the signing key's ID (kid). No role is
  in it: a key lets one into the room; what one may do inside is the app's
  business. About 280 bytes. The signer signs it (`POST /room-token`, at
  most 24 hours ahead) with a key that stays in the signer's volume; the
  console asks for a key when it shows a link and keeps no copy.
- **The link** is `ASTERISM_ROOM_PAGE` with the key in its fragment
  (`#room=<key>&app=<app>`): a fragment is never sent to the page's server.
  The browser build reads the slot from the key (without checking it), puts
  the key on its WebSocket URL (`wss://<router>/room?t=<key>`, never over
  plain ws) and gives every Zenoh key it uses the prefix `room/<slot>`
  (picoruby-asterism-zenoh's namespace), so the apps run unchanged in the
  room. In a room the page is a node under its seat's ID (`wasm-0103`,
  0.3.0, "Seats" below; before 0.3.0 an ID of its own, `wasm-<6 hex>`):
  there are no accounts in a room.
- **The door** (`lib/relay/room_door.rb`, in `bin/ws_door`) reads the
  request, checks the key (signature with the public keys in
  `rooms.json`, its end, that its room still holds its slot and is not
  revoked) and the limits, and (in a room with seats) the page's secret
  in the WebSocket's first message, and only then connects to zenohd,
  with the seat's certificate: nothing reaches zenohd before that, not a
  connection and not a byte. It answers 101 itself and moves the batches: one WebSocket Binary message is one
  Zenoh batch, on TLS a batch is a 2-byte length and the batch; it lowers
  the first InitAck's batch size by 2 for the length. It cuts a room's
  connections when the key ends, when the room is closed, and when the
  room's slot goes to another room (before the new room's first connection
  is let in).
- **Limits.** The door: `WS_DOOR_ROOM_TOTAL` (48) room connections at once,
  `WS_DOOR_ROOM_PER_ROOM` (16) per room (a room's own limit may be lower),
  one message up to 65535 bytes, a request head within 5 s, 64 requests
  being checked at once. Keys that do not check are counted per address: past
  30 a minute the address is answered 429 for a minute (a key that checks
  is always let in, since many people at one event share an address).
  nginx limits tries per address (`asterism_room`, 60 a minute) and room
  connections per address (`asterism_room_conn`, 32: two full rooms). The
  router's `max_sessions` is 96. A connection costs the door about 0.3 MB
  idle, 0.6 MB busy (two threads, a 128 KB thread stack; 48 connections in
  a rehearsal: the door 16 MB empty, 29 MB idle, 45 MB busy).
- **Closing.** Closing a room (Admin > Rooms) writes `rooms.json` again: the
  room leaves its slot and is listed as revoked until its keys would have
  ended. The door reads the file again within half a second, cuts the
  room's connections and refuses its keys; a page trying again is refused
  too. The console being down stops nobody who has a link: the door needs
  only the file.

## Rooms in the graph (0.2.1)

An admin sees the rooms on the graph ("Rooms", next to "Relay registry",
on by default); a user who is not an admin never receives them.

- **What the console may do in a room.** When there are room slots, the
  cloud router's ACL gives the console's own certificate (`console`, the
  bridge's) one more pair of rules: from it only the liveliness watch and
  liveliness queries on `room/*/asterism/**`, to it only the liveliness
  tokens and the replies to those queries. No put, no subscription, no
  queryable, no query (an Asterism call is a query), no token: the console
  cannot write into a room or call an object in one, and nothing it does
  reaches the rooms' sessions. The `@profile` of a room's nodes is not
  read (from 0.3.0 a seat may put its own, "Seats" below; the console's
  rules do not reach `@` chunks). The tests check this with an evaluator of
  the rules (`test/lib/relay/cloud_config_test.rb`); a run against zenohd
  1.10.1 with two room slots showed the watch and the liveliness query
  answering the rooms' tokens, and a put, a call and a token of the console
  in a room not arriving.
- **The bridge** watches `room/*/asterism/**` next to `asterism/**` and reads
  the open rooms (name, slot, end) with the registry. The graph has one
  frame per open room (`room:<slot>`, label "name · room 01 · until
  2026-10-14 22:00 JST", the end in the console's time zone,
  `CONSOLE_TIME_ZONE`), holding the room's nodes, their apps and objects
  (ids `a_node:room/<slot>/<node>`, so a room's `wasm-abc123` is not a
  registered `wasm-abc123`). Each page in a room is a client session of
  the cloud router (the door connects one TLS session per WebSocket), so
  its node is joined to the router like any other client. A room with
  nobody in it has an empty frame; tokens on a slot with no open room (a
  room that just ended, before the door cut it) get a frame "room 03 (no
  open room)".
- **No calls.** An object in a room has no call form: its details say that
  the console only watches who is there. The registry's marks are not
  given to a room's nodes.
- **Who sees it.** The graph's diffs go on two streams: with the rooms to
  admins who may use the admin pages from where they are (`CONSOLE_ADMIN_NETS`,
  and the second factor when it is required), without them (no frame, no
  node, no session of a room) to everyone else; the same for the whole
  graph the page asks for. Recordings (admins only) keep the rooms.

## A room's host (0.2.2)

A process that holds a room's state (a mahjong table, say) joins from
inside the server, without the door, with the room's namespace:
`Asterism.connect(credentials: "games.tar", config: { "namespace" => "room/01" }, app: ...)`.
The namespace makes its keys the room's (`asterism/...` inside, as the
browsers see them). From 0.3.0 a game host joins with **its own
certificate** (a registry row named in `ASTERISM_ROOM_HOSTS`, "games"; the
same row as its permanent tables), and the rooms' tables under its name
are its alone ("Seats" below). Before 0.3.0 it joined with the slot's
certificate, `/rooms/certs/room-<slot>.tar`, which every page of the room
held too; that file is still made (an admin's tests, CRuby).

- **Which rooms a host serves.** `rooms.json` says for each open room what
  its link opens (`"app"`; the door does not use it). A host reads the file
  (the `rooms` volume, read-only) and serves the rooms that open its app.
  asterism-games does so for the mahjong table: the admin chooses "Opens:
  Mahjong" when making the room (`ASTERISM_ROOM_APPS` lists the choices) and
  the room has a table a second later, with nothing else to do.
- **A slot used again.** A host must drop what it kept for a room when the
  room is over: the room is in `revoked`, its end has passed, or its slot
  holds another room's ID. asterism-games removes the room's saved tables
  then, so the next room on the slot starts from nothing.
- **Watching it.** `docker-compose.games.yml` gives the console the host's
  `GET /status` (`ASTERISM_GAMES_STATUS_URL`): the rooms' page says whether
  the host answers, and each room's tables (state and counts only). In the
  graph the host's node and its objects show in the room's frame like any
  node in a room. The same file puts the host's saved tables into the daily
  backup (`ASTERISM_BACKUP_EXTRA`).

## A game host's permanent tables (0.2.3)

A game host can also keep tables outside the rooms, on the registered side
of the router, for the boards that connect with their own certificates and
for the browsers with a pass (asterism-games 0.4.0, its README "Permanent
tables"). It is one more process of the host with a certificate of its
own, a row of the registry like any other node, and nothing in the
console's code is particular to it: two roles and a row.

- **The host's role** (Admin > Relay > Roles, "New role"), `games-host`:

  ```
  Read and write   asterism/${node}
                   asterism/${node}/games/**
                   asterism/${node}/@profile
  Watch            asterism/**
  Browsers have this role: no
  ```

  The host's place and nothing more: it puts its tables' states
  (`asterism/games/games/<table>/state`) and answers the calls on them, as
  its own node only. It reads nobody's keys and calls nobody.
- **The players' role**, `games` (the boards and the browsers that may sit
  at the tables):

  ```
  Read             asterism/*/games/**
  Ask              asterism/*/games/*/call/${node}
                   asterism/*/games/*/meta
  Browsers have this role: yes
  Opens in a browser page: /app/game/mahjong/mahjong.app.rb
  ```

  The tables' states and presence to read, the tables to call in its own
  name only. It writes nothing: a board's own presence comes from the role
  it has already ("match", the app `game` the table's screen runs as).
  Give it to the rows of the boards (Edit, tick `games` next to `match`);
  "Opens in a browser page" puts the table's screen among the apps of "Open
  the browser build".
- **The host's row**: Register, kind `client`, name `games` (the
  certificate's name is the host's node ID), role `games-host`. Open it,
  "Issue a certificate", "Save all (.tar)": `games.tar` goes to the game
  host (asterism-games docs/install.md, "Permanent tables").
- **Apply** (the banner "Review and apply"): the router takes the new rows
  and roles when it restarts. Everyone connected comes back within seconds;
  "When nobody is connected" waits instead.

What these roles keep closed (`test/lib/relay/game_host_roles_test.rb`):

- A board sees the tables and calls them, but only in its own name: it
  cannot call as another board or a browser, answer a table's calls, write
  a table's state, or make a table of its own (its node's `games` keys are
  not its to write). A board's seat is held by its node ID, which only that
  board's certificate can call under, so no one else gets its token, and
  with it its hand.
- The browsers are one subject at the router (section "Browsers" of
  docs/g1_5.md): a browser calls under the browsers' node IDs
  (`wasm-$*`), never a board's. One browser can still call under another
  browser's node ID, and a table gives a node its seat's token back when it
  joins again, so a browser player's hand is as safe as the other pass
  holders are trusted. The boards' seats are not affected.
- The rooms: a room's slot and seats reach only `room/<slot>/**`, and the
  players' rows reach nothing of a room. The host's row reaches the rooms
  from 0.3.0, as a room's host does ("Seats" below): its own names in
  every room (`room/*/asterism/games$*`) to write, the rooms to read and
  receive, calls only under its own names.

The rooms' page shows the permanent tables under the game host's line
(state and counts, the same as a room's tables), and the graph shows the
host's node `games` and its tables on the registered side.

## Seats (0.3.0)

Before 0.3.0 every page of a room came through the door with the slot's
one certificate, so the router saw the whole room as one client: a page
could write where another page writes, answer calls for another page or
for the room's table, and call under another page's node ID. zenohd
1.10.1 cannot put a name from the connection into a rule (its subjects and
rules are fixed when it starts, and a rule's key is a plain string), so
the names a room may use are made beforehand: **seats**.

- **Certificates.** Each slot has `ASTERISM_ROOM_SEATS` (16) seats,
  `room-01-s01` ... `room-01-s16`, each a registry row (marked room slot,
  hidden from the registry's list, one line under it) with a certificate
  whose key `bin/asterism setup` makes on the server, like the slot's. The
  files go to `/rooms/certs/` for the door only (no `.tar`). A seat's node
  ID is the browsers' prefix, the slot and the seat: `wasm-0103` is seat 03
  of slot 01.
- **The ACL** (`Relay::CloudConfig`, `test/lib/relay/room_seats_acl_test.rb`).
  A seat reads its whole room (subscriptions, liveliness, gets on
  `room/<slot>/**`, its `@adv` part, the nodes' `@profile`) and receives
  everything there; it writes (put, delete, queryable, liveliness token,
  reply) only under `room/<slot>/asterism/<its node>` (with its `@profile`
  and `@adv` keys); it calls (a get on `.../call/<caller>`) only as
  itself. zenohd lets a deny win over an allow inside one subject, and an
  allow of any subject win over the other subjects, so each seat has two
  subjects for its one certificate: the common name alone, with "no calls"
  (a deny on `room/<slot>/asterism/*/*/*/call/**`), and the common name
  with `link_protocols: ["tls"]`, with "calls as itself" (an allow on
  `.../call/<its node>`). Meta and profile gets need no caller and stay
  open. A get with a wildcard (`**`, `.../call/*`) reaches the callee only
  as a wildcard key, which Asterism answers with nothing. Declared key
  expressions, fragmented messages and the like are solved by zenohd
  before the ACL looks: the ACL judges the whole key.
- **The slot's certificate** keeps its key space, with denies on what
  belongs to others: the seats' nodes and the game hosts' names, for
  writes and as the caller of a call. The door no longer uses it (unless
  `WS_DOOR_ROOM_LEGACY=1`, below); an admin can test with
  `room-01.tar`.
- **Game hosts** (`ASTERISM_ROOM_HOSTS`, `games` unless set; `-` for none):
  the row of that name (the host's own certificate) gets, next to its
  roles, the rooms' tables: writes under `room/*/asterism/games$*` (the
  host in each room's namespace, and its bots named `games-...`), the rooms
  to read and receive, calls under its own names only, meta and profiles.
  Nobody else in a room can write there or call as the host.
- **Taking a seat.** The page keeps a secret of its own for the room (16
  random bytes, hex) and, before it starts, posts it with the room's key:
  `POST https://<router>/room/seat`, body `{"t": "<key>", "s": "<secret>"}`
  (`Content-Type: text/plain` keeps the request simple for CORS; the door
  answers the preflight anyway). The door checks the key as for the
  WebSocket and answers `{"node": "wasm-0103", "seat": "03"}`: the same
  seat for the same secret until the room is over, a free seat for a new
  secret, and when none is free a seat nobody has been connected on for
  `WS_DOOR_SEAT_IDLE` seconds (1800), else `409 {"error": "full"}`. `404
  {"error": "no seats"}`: the room's slot has no seats in the router's
  configuration (a console before 0.3.0, `ASTERISM_ROOM_SEATS=0`, or not
  applied yet); the page then runs as before 0.3.0. 403 / 410 / 429 as for
  the WebSocket.
- **The WebSocket.** As before, `wss://<router>/room?t=<key>`. In a room
  with seats the door answers 101 and waits (5 s) for the first message, a
  Text `{"s": "<secret>"}`, looks the seat up, and only then connects to
  zenohd with the seat's certificate. A page has up to 4 sessions on one
  seat. The door closes the WebSocket with 4403 (no seat for this secret:
  take one first), 4408 (no secret in time), 4426 (a Binary message first:
  a page from before 0.3.0), 1013 (zenohd is not there; try again). The
  room's connection limits are as before.
- **The seats' table** is the door's own file (`WS_DOOR_SEATS_FILE`,
  `/seats/seats.json` on the `seats` volume, 0600): per room the SHA-256 of
  "<room ID>:<secret>" and the seat, never a secret. It survives a restart
  of the door. A room that is over (closed, ended, its slot given to
  another room) loses its seats within a second.
- **Nothing of the secret in a log.** It is never in a URL or a header:
  the POST's body and the WebSocket's first message only, and nginx logs
  neither. The door logs "room ... slot 01 seat 03 (new): for a page from
  <address>". (The room's key, as before, is in the WebSocket's URL; nginx
  writes the request line into its error log when the door itself is not
  running, e.g. while it restarts.)
- **The pages from before 0.3.0** send no secret. `WS_DOOR_ROOM_LEGACY=1`
  lets them in with the slot's certificate while the new browser build is
  not published yet (they cannot write as a seat or a host then; among
  themselves they are as unprotected as before). Set it back to 0 once the
  page that takes seats is out.
- **A game host trusts the router** (asterism-games 0.5.0): `rooms.json`
  says, per open room, how many seats its slot has in the router's
  configuration (`"seats"`), the seats' node prefix and the hosts. A host
  takes a call from a seat's node ID, or from its own names, as it comes,
  and checks the others (the old pages' `wasm-<6 hex>`) with their secret
  until it is told not to. A seat given to a new page after its idle time:
  the table drops the old member (its hand goes to a CPU) when the seat's
  node has not called for as long.
- **Measured** (zenohd 1.10.1, 8 slots of 16 seats, the rehearsal of
  deploy/local): the configuration 197 KB (19 KB without seats), 338 rules,
  269 subjects; zenohd from its first log line to listening 24-26 ms (5-7
  ms without seats), resident 17.5 MB (12.0 MB without seats). A subject
  is matched once when a session opens, so a message costs the same.

## What a room does not protect

What the router guarantees: a room's connections touch only
`room/<slot>/**`, and nothing of the registered side, or of other rooms,
reaches them; from 0.3.0, inside the room each page writes only under its
seat's node ID and calls only as itself, and the tables of a game host
are the host's alone. What is left:

- Anyone with the room's link gets in (a seat each, up to the seats).
  Keep anything that matters (driving a robot, say) on the certificates'
  side.
- Inside a room, reading is free: every page can subscribe to and get
  everything in the room (a table keeps its players' hands to itself by
  answering each player's own calls, not through the router).
- A page from before 0.3.0, let in with `WS_DOOR_ROOM_LEGACY=1`, is as
  before among the other old pages.
