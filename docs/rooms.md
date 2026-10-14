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

## A room's host (later)

A process that holds a room's state (a mahjong table, say) can join from
inside the server with the slot's certificate, without the door:
`/rooms/certs/room-<slot>.tar` (the format of the console's "Save all
(.tar)") and, with the asterism gem,
`Asterism.connect(credentials: "room-01.tar", config: { "namespace" => "room/01" }, node: "table", app: ...)`.
The namespace makes its keys the room's (`asterism/...` inside, as the
browsers see them).

## What a room does not protect

Everyone in a room has the same key, so inside the room nobody is told
apart by the router: one page can write where another page writes, or
claim another's node ID. That is fine for games among people you invited;
keep anything that matters (driving a robot, say) on the certificates'
side. What the router does guarantee: a room's connections touch only
`room/<slot>/**`, and nothing of the registered side, or of other rooms,
reaches them.
