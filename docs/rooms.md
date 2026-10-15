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
| Keys | what the roles allow | the room's key space only: `room/<slot>/**` |
| Made by | an admin | an admin (Admin > Rooms) |

## The parts

```
 browser (room link) --wss:///room?t=<key>--> nginx --> door (7452) --mutual TLS as room-<slot>--> zenohd tls/7448
                                                         |  reads /rooms/rooms.json, /rooms/certs/
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
  room. In a room the page is a node under its own ID (`wasm-<6 hex>`):
  there are no accounts in a room.
- **The door** (`lib/relay/room_door.rb`, in `bin/ws_door`) reads the
  request, checks the key (signature with the public keys in
  `rooms.json`, its end, that its room still holds its slot and is not
  revoked) and the limits, and only then connects to zenohd: nothing
  reaches zenohd before that, not a connection and not a byte. It answers
  101 itself and moves the batches: one WebSocket Binary message is one
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
  read: a room's ACL (`room/<slot>/**`) does not reach `@` chunks, so the
  pages cannot put one anyway. The tests check this with an evaluator of
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

A process that holds a room's state (a mahjong table, say) can join from
inside the server with the slot's certificate, without the door:
`/rooms/certs/room-<slot>.tar` (the format of the console's "Save all
(.tar)") and, with the asterism gem,
`Asterism.connect(credentials: "room-01.tar", config: { "namespace" => "room/01" }, node: "table", app: ...)`.
The namespace makes its keys the room's (`asterism/...` inside, as the
browsers see them).

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

## What a room does not protect

Everyone in a room has the same key, so inside the room nobody is told
apart by the router: one page can write where another page writes, or
claim another's node ID. That is fine for games among people you invited;
keep anything that matters (driving a robot, say) on the certificates'
side. What the router does guarantee: a room's connections touch only
`room/<slot>/**`, and nothing of the registered side, or of other rooms,
reaches them.
