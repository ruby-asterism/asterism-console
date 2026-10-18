# Changelog

The console's versions (`VERSION`; the image
`ghcr.io/ruby-asterism/asterism-console:<version>` carries the same
number). Each version says what an update needs (docs/install.md,
"Updating"). Database migrations run when the console starts; going back
to an older version across a migration means restoring the backup made
before the update (from 0.1.3, `deploy/vps/update.sh` takes it and prints
the command that goes back).

## 0.3.9

What an update needs: `./update.sh 0.3.9`. No migration, no change to
`.env`, nginx or the router's configuration. docs/install.md, "From 0.3.8
to 0.3.9".

- A page that comes back is the same person (docs/rooms.md, "Coming
  back"): the browser build keeps its room secret in the browser, so a tab
  closed and opened again asks for its seat with the same secret and gets
  the same seat (the same node ID) as before. Such a seat request now cuts
  the connections still on that seat (what is left of the closed tab, or
  the other tab of the same browser: the newer page takes the seat), with
  close code 4403, after which the older page reads its seat as gone. A
  page's own sessions and reconnections send no seat request and cut
  nothing. A secret the door does not know gets a free seat as before.
  Neither the secret nor its hash is ever logged.
- Compatible both ways: a page that does not keep its secret is a new
  person as before, and a door before 0.3.9 gives the same seat for the
  same secret without cutting anything.

## 0.3.8

What an update needs: `./update.sh 0.3.8`. One migration (going back
needs the update's backup). No change to `.env`, nginx or the router's
configuration. docs/install.md, "From 0.3.7 to 0.3.8".

- The rooms made through one invite link see each other's game records
  (docs/rooms.md, "Invite links"; with asterism-games 0.16.0): each invite
  link has a group, a random string unrelated to its secret, and
  `rooms.json` gives it to each room made through the link (`"group"`).
  Rooms made by an admin get none. The secret and its hash are never in
  `rooms.json`. Migration: `room_invites.records_group` (the existing
  links get one).
- A game host before 0.16.0 ignores `"group"`; asterism-games 0.16.0 with
  a console before 0.3.8 (no `"group"`) keeps each room's records to the
  room, as before.

## 0.3.7

What an update needs: `./update.sh 0.3.7`. No migration, no change to
`.env`, nginx or the router's configuration.

- A link the console shows only once (an invite link when it is made, a
  room's link on the admin's room page and on the invite link's page) is
  set apart in the warning colours, says that it cannot be shown again,
  and has a "Copy the link" button.

## 0.3.6

What an update needs: `./update.sh 0.3.6`. One migration (going back
needs the update's backup). No change to `.env`, nginx or the router's
configuration. docs/install.md, "From 0.3.5 to 0.3.6".

- The exposure check, `bin/asterism-exposure` (docs/exposure.md): asks a
  server from outside, as a stranger would, and compares the answers with
  a YAML list: an HTTP path's status (optionally a text in the body), an
  asset the page loads (`asset_from`: an `/assets/*.css` or `.js` picked
  from the page), and whether a TCP port is `open` or `closed` (a timeout
  or a refusal). Redirects are not followed. One line per check, exit 1
  when one fails. Plain Ruby (net/http, socket, yaml): no Rails, no
  bundle.
- The hosts come from `ASTERISM_EXPOSURE_HOST` (and
  `ASTERISM_EXPOSURE_HOST_<NAME>` for checks with `host: <name>`) or
  `--host`, never from the file, and the output never names them
  (`<host>`; names and addresses are cut out of messages).
- `deploy/vps/exposure.example.yml`: the checks for the example nginx and
  firewall. docs/exposure.md has a GitHub Actions workflow for a private
  repository of your own (every 6 hours and by hand, the hosts in its
  secrets, a failure as GitHub's email); asterism-console's own Actions
  do not run it.
- A message on each invite link (docs/rooms.md, "Invite links"): an admin
  writes it when making the link (the form starts with the message of the
  link made last) and changes it on the link's page in Admin > Rooms; the
  link's page shows it under its heading, above the form. Plain text, at
  most 4000 characters: HTML is shown as text, line breaks are kept (an
  empty line starts a paragraph), no link is made. Optional; links without
  one look as before. Migration: `room_invites.message`.

## 0.3.5

What an update needs: `./update.sh 0.3.5`. Two migrations (going back
needs the update's backup). No change to `.env` or the router's
configuration. nginx: two locations for the invite links' page (copy
`asterism-console.conf`). docs/install.md, "From 0.3.4 to 0.3.5".

- The admin pages "Relay" are called "Members": the menu, the headings,
  and the URLs, `/admin/members/...` (the peers, roles and applies as
  before). The old URLs under `/admin/relay` redirect to the same page
  under `/admin/members`, the query kept. The code keeps the relay's names
  (`Relay::...`, `RelayPeer`).
- The graph's layer "Relay registry" is called "Members" too (the graph and
  a recording's structure page).
- A display name on each row of the registry (optional, up to 40
  characters), set when registering or editing: "Tab5" for
  `fmruby-aaaaaa`. Members lists it next to the name, the row's page and
  the rooms' page (the permanent tables' node) show `Tab5 (fmruby-aaaaaa)`.
  The name (the certificate's common name, the ACL's subject) is unchanged
  and the display name is not in the router's configuration: changing it
  needs no Apply.
- The graph's label of a registered node or router is
  `<display name> (<ID>)`: the row's display name first, else the name
  the node's profile tells (as before), else the ID alone. A room's seats,
  a room's game host and the browser build keep their labels. The bridge
  passes the display name in the node's data `peer` (`display_name`); the
  label is made by `app/javascript/lib/node_label.js`.
- The graph details' "registry" link goes to `/admin/members/peers` (it
  pointed at `/relay/peers`, which did not exist).
- The page "Browser passes" is called "Make a pass" (the menu, its heading
  and title; the admins' list of every pass is "Every pass"), and the
  button "Open the browser build" is "Launch Web Studio" (the menu, the
  page, docs). The URLs (`/passes`, `/admin/passes`) and the settings'
  names (`ASTERISM_BROWSER_PAGE`, ...) are unchanged.
- Invite links to make rooms (docs/rooms.md, "Invite links"). An admin
  makes one on the rooms' page (a name, days it works, rooms open at once,
  the apps of `ASTERISM_ROOM_APPS` it may open), sees it shown once
  (`/invite#invite=<secret>`; only the secret's SHA-256 is kept), lists
  them (until, rooms open, rooms made) and revokes one, optionally closing
  its open rooms. Whoever opens the link, without an account, gets a page
  that only makes rooms (one of its apps, 3 hours unless said, at most 12,
  an optional name), shows the room's link once, and lists and closes the
  rooms of the same invite link. Refusals say why (ended, revoked, its
  limit, every slot taken). Rooms made so take free slots like any other;
  the rooms' page says which invite link made each. Secrets that are no
  invite link's are counted per address (10 in 10 minutes, then 429), every
  try is limited, and nginx's example opens `/invite` to the rooms' door's
  addresses (`asterism-door-allow.conf`).

## 0.3.4

What an update needs: `./update.sh 0.3.4`. No migration, no change to
`.env` or nginx. The router's configuration changes (the console's reading
of the statuses, below): the update's setup writes it from the registry
and restarts the router on it, as Apply does. A game host that should tell
its tables' counts needs a line in its role (below). docs/install.md,
"From 0.3.3 to 0.3.4".

- The applications' statuses (asterism's `asterism/<node>/<app>/@status`:
  a small map an application tells about itself and puts again when it
  changes; a game host's tables' counts) show in the graph's details: an
  app's details have a "Status" row, its node's details one per app that
  has a status. The graph itself (its nodes and lines) does not change.
  The bridge asks each application once when it appears and follows the
  puts (`Bridge::Statuses`); the graph's data `status` is on the apps.
- The router's configuration gives the console's certificate a rule for
  `asterism/*/*/@status` (`console__statuses_in`: its query and
  subscription; `console__statuses_out`: the replies and the puts), as for
  the profiles in 0.3.3 (`**` does not match a chunk that starts with
  `@`). It reads the statuses and writes none; no other subject gets the
  rule.
- docs/rooms.md: the role `games-host` gets `asterism/${node}/*/@status`
  in "Read and write", so that the permanent tables' host (asterism-games
  0.9.0) may tell its tables' counts. Add it to the role on a running
  console (Admin > Relay > Roles, then Apply); without it the host's
  status does not get through and the details show none. A room's host
  tells none (the rooms' rules are unchanged).
- docs/g1_5.md, "Looking only": a viewer role for an admin's `.tar`, with
  which the asterism gem's command line (`asterism nodes / tree / watch`)
  and its MCP bridge see the whole network outside the rooms and the
  router refuses every call (`test/lib/relay/viewer_role_test.rb`).

## 0.3.3

What an update needs: `./update.sh 0.3.3`. No migration, no change to
`.env` or nginx. The router's configuration changes (the console's
profiles, below): the update's setup writes it from the registry and
restarts the router on it, as Apply does. docs/install.md, "From 0.3.2
to 0.3.3".

- A room's game host has a label of its own in the graph. The host joins
  every room and keeps its permanent tables with one certificate (`games`),
  so the graph had two nodes `games`, one in a room's frame and one outside,
  and nothing told them apart. A node in a room's frame whose ID is one of
  `ASTERISM_ROOM_HOSTS` is now labelled `<ID> (room <slot>)`, such as
  `games (room 05)` (data `room_host` in the graph; the console cannot read
  the profiles in a room, so the label is the console's own). The same ID
  outside the rooms and every other node keep their labels: a profile's
  name before the ID, the browsers' IDs, "(this console)".
- The permanent tables' host (asterism-games 0.7.1) gives its profile the
  name `permanent tables`, which the graph shows as `permanent tables
  (games)`.
- The console reads the nodes' profiles through the cloud router again.
  A key expression's `**` does not match a chunk that starts with `@`, and
  the console's own row (made by `bin/asterism setup`) has `asterism/**`
  only, so the router let neither the console's query on
  `asterism/<node>/@profile` nor the profiles' puts through: the graph
  showed the IDs without the names, marks and icons of the profiles (the
  console's own is drawn without the network). The router's configuration
  now gives the console's certificate a rule of its own for
  `asterism/*/@profile` (`console__profiles_in`: its query and
  subscription; `console__profiles_out`: the replies and the puts to it).
  It reads the profiles and writes none; no other subject gets the rule.
  The registry's rows are not changed (no migration): the rule comes from
  the code, so the update's setup writes it and restarts the router.

## 0.3.2

What an update needs: `./update.sh 0.3.2`. No migration, no change to
`.env`, nginx or the router's configuration. docs/install.md, "From 0.3.1
to 0.3.2".

- zenohd 1.10.1 can get stuck: while it answers a query on its admin space
  (the token table, the linkstate, which the bridge reads every 2 seconds)
  it holds a read lock on its routing tables and takes it again to send
  the reply; when a connection, a declaration or a disconnection waits for
  the write lock in between, neither goes on. From then on it takes no new
  session, the sessions it has drop as their lease runs out, and it does
  not recover by itself. The fault is in zenohd (a fix is under way); until
  a fixed zenohd is in the image, the console restarts it.
- The router watch (`Bridge::RouterWatch`, a thread of the bridge): every
  `ASTERISM_RELAY_WATCH_EVERY` seconds (30) it opens a brand-new session to
  the router with the console's certificate (a session the bridge already
  has would not notice), allowing `ASTERISM_RELAY_WATCH_TIMEOUT` seconds
  (10), and closes it. After `ASTERISM_RELAY_WATCH_FAILS` failures in a row
  (2) it asks for the router's restart as Apply does (`restart.request`,
  `bin/relay_restart_request`): a stuck router is restarted some 50 to 80
  seconds after it stops. Nothing is counted for
  `ASTERISM_RELAY_WATCH_GRACE` seconds (60) after any restart request (an
  apply's or its own) or while an apply runs; when its restarts do not help,
  each next one waits twice as long (up to 30 minutes) until a check
  passes. `ASTERISM_RELAY_WATCH_EVERY=0` turns it off; it runs only where
  the console writes the router's configuration.
- The probe sessions carry an ID the watch chose, and the graph leaves them
  out: no node, no session, the same counts as before.
- The bridge logs each failed check and each restart with its reason
  (`bridge: router watch: ...`); Admin > Relay shows the last automatic
  restart, its time and reason (`router_watch.json` next to the router's
  generated configuration).
- The compose file gives the bridge the `generated` volume (read-write) and
  the restart settings Apply uses.

## 0.3.1

What an update needs: `./update.sh 0.3.1`, and removing a
`WS_DOOR_ROOM_LEGACY` line from `.env` if there is one. A migration (going
back needs the update's backup). docs/install.md, "From 0.3.0 to 0.3.1".

- The rooms' certificates are out of the relay registry: the registry
  lists only the rows an admin registered. The seats' certificates
  (`room-NN-sMM`) are the rooms' own, kept where they were (the `rooms`
  volume's `certs/`, `Relay::RoomCerts`), and the router's ACL takes the
  seats from the settings (`ASTERISM_ROOM_SLOTS`, `ASTERISM_ROOM_SEATS`)
  and the certificates there. The migration removes the room rows and
  their ledger entries; the seats' certificates are kept, not issued again.
  A registry row cannot take a room certificate's name.
- No certificate of a slot's own any more (`room-NN`, its `.tar`): setup
  removes their files, and the ACL has no rules for them. `WS_DOOR_ROOM_LEGACY`
  and the door's way in for the pages from before the seats are gone: such
  a page is closed with 4426. A slot without seats in the router's
  configuration lets nobody in (503) and takes no room.
- The rooms' page has "Slots and seats": the slots, the seats per slot,
  the seats' certificates (good, the first to end), how many the router
  lets in, the rooms and seats in use; each room shows its seats taken.
- `bin/asterism room-seat <slot> <seat>` writes a seat's certificate as a
  credentials `.tar`, for an admin's test in a room from CRuby
  (docs/rooms.md, "An admin in a room").
- `ASTERISM_ROOM_SEATS` is 1..99 (0 no longer means "the slot's
  certificate"; `ASTERISM_ROOM_SLOTS=0` turns the rooms off).

## 0.3.0

What an update needs: the game host first (asterism-games 0.5.0, when
there is one), then four lines in `.env` (`ASTERISM_ROOM_SEATS`,
`ASTERISM_ROOM_HOSTS`, `WS_DOOR_SEAT_IDLE`, `WS_DOOR_ROOM_LEGACY`; set the
last to 1 while the published browser build is older than the seats), the
new `location = /room/seat` in nginx, and `./update.sh 0.3.0` (it makes the
seats' certificates and restarts the router on them). No migration.
docs/install.md, "From 0.2.3 to 0.3.0".

- Seats in the rooms (docs/rooms.md "Seats"): 16 certificates per slot
  (`room-NN-sMM`, made by setup); the door gives each page a seat from its
  secret (`POST /room/seat`, the secret in the body and in the WebSocket's
  first message, never in a URL, a header or a log; the door keeps only its
  SHA-256) and connects with the seat's certificate. The router's ACL lets
  a seat write only under its node ID (`wasm-<slot><seat>`, `@profile`
  included) and call only as itself (two subjects per certificate). The
  same secret gets the same seat until the room is over; a seat nobody was
  on for 30 minutes may go to a new page when all are taken; 409 when
  full; a room that is over loses its seats.
- Game hosts in the rooms (`ASTERISM_ROOM_HOSTS`, `games`): the host's own
  row gets the rooms' tables (`room/*/asterism/games$*`), and nobody else in
  a room may write there or call under the host's names; the slot
  certificates get denies on the hosts' and the seats' names.
- `rooms.json` says, per open room, how many seats the router's
  configuration lets in, and the seats' node prefix and the hosts (a game
  host reads them). It is written again on every apply.
- The registry's list shows the seats as one line; the apply pages count
  them per slot; the graph leaves them out of the registry.
- A WebSocket the door refuses after 101 (4403, 4408, 4426, 1013) is
  closed only after what the page had already sent is read: closing with
  unread bytes reset the connection, and nginx logged the reset with the
  request line, the room's key in it.
- `WS_DOOR_ROOM_LEGACY=1` lets a page from before the seats into a room
  with seats, with the slot's certificate (the slot's certificate is kept
  for that and for an admin's tests).

## 0.2.3

What an update needs: nothing beyond `./update.sh 0.2.3`. No migration,
no change to `.env`, nginx or the router's configuration.

- A game host's permanent tables (asterism-games 0.4.0): the rooms' page
  shows them under the game host's line (the host's node, whether its
  process is up or waits for its certificate, each table's state and
  counts). The tables themselves need no code in the console: two roles
  (`games-host` for the host's row, `games` for the boards and the
  browsers) and a row, docs/rooms.md "A game host's permanent tables", with
  a test that asks the ACL what those roles allow and keep closed.

## 0.2.2

What an update needs: nothing beyond `./update.sh 0.2.2`; add
`ASTERISM_ROOM_APPS` to `.env` for the choice of apps (env.example). No
migration, no change to nginx or the router's configuration.

- The door (rooms): a browser's message of exactly 127 bytes was read as
  if a 64-bit length followed, and the connection was cut ("a ...-byte
  frame" in the door's log). The 7-bit length now decides alone. The
  mahjong table's calls hit it within a minute of play.
- The rooms' page offers the apps a room's link opens as a choice
  (`ASTERISM_ROOM_APPS`, "Label=/path,...", then the roles' browser apps),
  with "Or another app" for any other path.
- `rooms.json` says what each open room's link opens (`"app"`): a game
  host next to the console (asterism-games) serves tables in the rooms that
  open its table (docs/rooms.md, "A room's host").
- A game host on the rooms' page (`ASTERISM_GAMES_STATUS_URL`): whether it
  answers, its rooms with tables and each table's state and counts, a
  "Tables" column in the list of rooms and on a room's page.
- Backups: `ASTERISM_BACKUP_EXTRA` ("name=/dir,...") adds another
  service's directory to the daily backup under `extra/<name>/` (listed in
  the manifest; a restore leaves it alone). `deploy/vps/docker-compose.games.yml`
  sets it, and the status URL, for a game host next to the console
  (docs/install.md section 12, "A game host").
- `deploy/local/rehearse`: `GAMES=1` adds that file to the rehearsal.

## 0.2.1

What an update needs: set `CONSOLE_TIME_ZONE` in `.env` if the pages
should not show UTC (e.g. `CONSOLE_TIME_ZONE=Asia/Tokyo`). No migration.
The cloud router's ACL changes (when there are room slots): update with
0.2.1's `update.sh`, which restarts the router on the new configuration
itself (`git show v0.2.1:deploy/vps/update.sh > /tmp/asterism-update.sh`,
then `sh /tmp/asterism-update.sh -C "$PWD" 0.2.1`, docs/install.md
section 20); with 0.2.0's script, Apply once after the update.

- Rooms in the graph (docs/rooms.md): an admin sees each open room as a
  frame (its name, slot and end) holding the nodes in it (browser pages,
  `wasm-xxxxxx`) with their apps and objects, joined to the router by
  their sessions like other clients. A layer "Rooms", on by default for
  admins. The objects in a room have no call form. A user who is not an
  admin never receives the rooms: the graph's diffs go on two streams,
  and the page's whole graph leaves them out. Recordings (admins only)
  keep them. A room's pages now count as connected for "Apply when nobody
  is connected" (before, their sessions carried nothing the console could
  see), and a room's node is never taken for a registered name.
- The cloud router's ACL lets the console's certificate watch the rooms
  (when there are room slots): the liveliness watch and liveliness
  queries on `room/*/asterism/**` and their answers, nothing else (no put,
  subscription, queryable, query or token in a room). Checked against
  zenohd 1.10.1.
- `CONSOLE_TIME_ZONE` (any Rails or IANA name, UTC unless set): the
  server's pages (`config.time_zone`) and the browser's times (graph
  details, timelines, logs, plots, recordings) are in it; a time shown
  alone carries the zone's name. Setup checks it.
- `bin/asterism setup --from-update` (what `update.sh` runs now): when it
  writes the cloud router a new configuration it also restarts the router
  on it, as Apply does, so after an update the router runs the registry.
  Its last lines, and `update.sh`'s, say so: Apply is needed only after
  changing the registry later. A first setup says that the router starts
  on the configuration it wrote.

## 0.2.0

- Roles let advanced pub/sub's history through: a zenohd ACL's `**` does
  not reach keys with an `@adv` chunk, so the role form's "Fill in", the
  seeded "match" role and a migration for existing roles add
  `asterism/${node}/<app>/**/@adv/**` (read and write) and
  `asterism/*/<app>/**/@adv/**` (read, ask) next to each app's plain lines.
  Apply once after updating so the router gets them.

Rooms (G2, docs/rooms.md): time-limited key spaces that anyone with a
room's link joins from a browser, without an account.

- Admin > Rooms: make a room (name, the app its link opens, hours: 3
  unless said, at most 24; connections at once: at most 16), see its link
  once, make another link, see its connections, close it. A room takes one
  of `ASTERISM_ROOM_SLOTS` (8) room slots, whose certificates (`room-01`
  ...) and ACL (`room/<slot>/**` and `room/<slot>/**/@adv/**`) are made
  once, so making and closing rooms restarts nothing.
- The rooms' keys are signed (Ed25519) by the signer, with a key that stays
  in its volume (`POST /room-token`, `GET`/`POST /room-keys`); the console
  keeps no copy of a key.
- The door (`bin/ws_door`) has a rooms' listener (7452): it checks a room's
  key (signature, end, the room still on its slot, not closed) before it
  connects to zenohd, then connects with the room slot's certificate over
  mutual TLS and moves the WebSocket's batches to TLS framing. It limits
  connections (48 in all, 16 per room), message size and keys that do not
  check per address, cuts a room's connections when it ends or is closed,
  and answers its counts on 7453 for the console.
- The router's `max_sessions` default is 96 (was 64).
- Updating (docs/install.md, section 20): new `.env` lines, the rooms'
  parts of the nginx example (`location = /room`, the `asterism_room` and
  `asterism_room_conn` zones, the `asterism_room_door` upstream), the
  setup (it makes the slots and the signing key) and one Apply.
- `deploy/vps/update.sh`: the restart line of the checks no longer prints
  the unit's name twice ("…(the unit starts the stack)docker-compose-service@…").

## 0.1.4

- Issuing a certificate on a peer's page says what comes next without a
  reload (which would lose the key the page holds): the "Changes not yet
  applied to the cloud router" banner appears in place of "The cloud
  router runs this registry.", the result says "Saved? Next: apply" with
  the "Review and apply" button (or that there is nothing to apply when
  the cloud router already lets the peer in), and the ACL badge and the
  ledger show the new certificate. The issuing answer carries these parts,
  rendered by the console.
- A peer without a valid certificate says the next step at the top of its
  Certificates: "No certificate yet: issue one below; it joins the ACL when
  you apply." (or that its certificates expired or were revoked, or that a
  disabled peer must be enabled first).
- Apply (Review and apply): one form with the choice of when (now, when
  nobody is connected, at a time) and one button that says what it does.
  The time is asked for only when "at a time" is chosen (going to the time
  field chooses it); before, "at a time" was a form of its own whose
  large button stood out from the other two, and pressing it without a
  time asked for one. "Now" still asks for a confirmation; the console checks the time
  for "at a time" only, as before.
- `deploy/vps/update.sh`: with a systemd unit, the restart is the unit's
  alone. 0.1.3 also ran `docker compose up -d` right after `systemctl
  restart`, which raced the unit's own `docker compose up` for the
  containers' names ("container name ... is already in use") and failed the
  update after everything else had been done (the stack was up under the
  unit).
- Updating from 0.1.3: `./update.sh 0.1.4` (docs/install.md, "Updating");
  with a systemd unit, the `update.sh` of 0.1.3 runs into the race above
  at its end, so take the new one first (`git fetch --tags`, `git show
  v0.1.4:deploy/vps/update.sh > /tmp/asterism-update.sh`,
  `sh /tmp/asterism-update.sh -C <deploy/vps> 0.1.4`, with `--sudo` / `-f`
  as your server needs). No migration; the compose file and `.env` are as
  in 0.1.3 apart from the version.

## 0.1.3

- Backups of the console's databases without anyone doing anything: a new
  service, `backup`, copies them once a day (`ASTERISM_BACKUP_HOUR`,
  default 3, UTC unless `TZ` is set) into a new volume, `backups`, and
  keeps the newest `ASTERISM_BACKUP_KEEP` (default 7). Each backup is one
  `.tar.gz` with a consistent copy of every database (SQLite's
  `VACUUM INTO`, safe while the console runs) and a manifest (the console's
  version, the time, the migration). When a backup fails, or none was made
  for two days, Admin > Relay and Users show a warning; Users shows the
  last backup.
- `bin/asterism backup`, `bin/asterism backups` and
  `bin/asterism restore <name>`. A restore refuses while the console, the
  bridge or a backup uses the databases (they hold a lock file in
  `storage/` now) and says what to stop; it checks the backup's version and
  migration against the console's (docs/install.md, "Restoring").
- `deploy/vps/update.sh <version>`: an update in one command on the server
  (plain sh): a backup first, the tag, `CONSOLE_VERSION` in `.env`, pull,
  `bin/asterism setup`, the restart (through a systemd unit when there is
  one), a check that the new containers run and nothing old is left, and
  the command that goes back (`update.sh <old version> --restore <the
  backup it took>`). `--dry-run` prints the steps; `--sudo`, `-f` (a
  compose file that includes this one), `--unit` (docs/install.md,
  "Updating").
- The CA is still backed up once, by hand, after the first setup (it never
  changes); the daily backups do not include it.
- Updating from 0.1.2 or earlier: 0.1.2 has no `update.sh`; take it from
  the new tag (`git fetch --tags`, `git show v0.1.3:deploy/vps/update.sh >
  /tmp/asterism-update.sh`, `sh /tmp/asterism-update.sh -C <deploy/vps> 0.1.3`,
  with `--sudo` / `-f` as your server needs). It takes the first backup
  with the 0.1.3 image. No migration. The compose file has a sixth service
  (`backup`) and a new volume (`backups`); add `ASTERISM_BACKUP_HOUR` and
  `ASTERISM_BACKUP_KEEP` to `.env` if the defaults (3 o'clock UTC, 7) do not
  suit you. Going back to 0.1.2 removes the `backup` container and keeps
  the `backups` volume.

## 0.1.2

- Every link the console gives a browser names the node: the pass and the
  node ID from the user's handle (`wasm-<handle>`), and the app when one is
  chosen. "Make a pass" now makes a pass for that node and shows its link
  in the same form as "Open the browser build" (the app empty); before, it
  carried the pass alone and the page joined under an ID of its own. A
  user without a handle is asked to choose one before any pass is made.
  `ASTERISM_BROWSER_PAGE` without `{node}` is not used, and
  `bin/asterism setup` stops on it (docs/g1_5.md, "Every link names the
  node").
- Easier to read: larger type (16 px body, 14 px hints, tables and code)
  with matching headings, spacing and buttons, on every page.
- The menu is grouped by role: Watch (Graph, Plots, Logs, Call log,
  Recordings), Play ("Open the browser build" when the user can, Browser
  passes), Admin (Relay, Call permissions, Users; admins only, in their own
  tint), then the account (the handle, or the email address's first part)
  and Sign out, on the title's row from about 1200 px up; the groups are
  parted by thin lines, the current page is marked. At phone width they
  fold behind a "Menu" button, with the group names. The graph's legend
  keeps its small type.
- Relay: Apply is no longer a tab (Registry and Roles are). While the
  registry differs from the file the cloud router runs with, both pages show
  a banner whose "Review and apply" opens the confirmation (now, when nobody
  is connected, or at a time, as before); the history of applies is linked
  from there. The old addresses still work.
- Relay roles: an "App name" helper with "Fill in" fills the four templates
  with the usual pattern for one app and suggests a name and a description
  (only empty fields, unless overwriting is confirmed); each template field
  says what it allows and what `${node}`, `*`, `**` and `@` mean. The
  descriptions are shown in the roles list and next to the roles a registry
  row picks. The example role "match" gets a description when it has none
  (a migration for existing consoles, the seed for new ones).
- The graph page: the watched keys moved to a panel under the graph and
  Details, one row per key (key, latest value, time, Stop; a click on the
  value shows it in full with the recent samples). The panel's height and
  the Details column's width can be dragged, the panel collapsed to one
  line; this browser remembers them.
- Updating from 0.1.1: set `CONSOLE_VERSION=0.1.2` in `.env`, pull and
  restart (docs/install.md, "Updating"). One migration (the description of
  the role "match", only when it has none). Check that
  `ASTERISM_BROWSER_PAGE` has `{node}` (as in `env.example`), or there are
  no links and no button. Users who open browser pages need a handle
  (Account > Handle). Serve a browser build that refuses a pass without a
  node (fmruby-core after 2026-10-14); an older one still opens a hand-made
  pass-only link under an ID of its own.

## 0.1.1

- The asterism gem 0.7.1 (with asterism-zenoh 0.4.1) in the image: the
  bridge keeps its connection across a router restart (an apply, an update,
  a dropped line) instead of reconnecting from scratch.
- Updating from 0.1.0: set `CONSOLE_VERSION=0.1.1` in `.env`, pull and
  restart (docs/install.md, "Updating"). No migration.

## 0.1.0

The first version installable by anyone on their own server
(docs/install.md, design in docs/o1.md).

- Published image for amd64 and arm64, built and pushed by
  `.github/workflows/image.yml` when a tag `v<VERSION>` is pushed. The
  compose file pulls `${CONSOLE_IMAGE}:${CONSOLE_VERSION}`;
  `docker-compose.build.yml` builds it on the server instead.
- `bin/asterism setup`: the first setup in one command (settings check,
  databases, the CA in the signer, the example role, the first admin, the
  server's own certificates, the router's configuration); idempotent.
  `bin/asterism version`.
- The signer starts without a CA and makes one when the setup asks
  (`POST /init`, once).
- `ASTERISM_ENROLLMENT=admin`: how people get in (the only mode for now).
- The certificate page saves everything as one file, "Save all (.tar)",
  made in the browser: the key (0600), the certificate, the CA, an example
  configuration (a home router's, which runs as it is, or a client's) and
  `asterism.json` (name, kind, router, until, the console). CRuby connects
  with that file alone (the asterism gem's `credentials:`).
- Nothing assumes one particular network: no default page for passes
  (`ASTERISM_STUDIO_URL` is no longer read; `ASTERISM_BROWSER_PAGE`), no
  node kinds guessed from names, generic defaults for the router's restart
  (`bin/relay_restart_request`) and name (`zenohd-cloud`), and the web
  server, the firewall and systemd as examples (nginx, Caddy).
- The pass check also reads `X-Forwarded-Uri` (Caddy's `forward_auth`).

Updating a deployment made before 0.1.0: docs/install.md, "Updating from
an earlier deployment".
