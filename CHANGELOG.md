# Changelog

The console's versions (`VERSION`; the image
`ghcr.io/ruby-asterism/asterism-console:<version>` carries the same
number). Each version says what an update needs (docs/install.md,
"Updating"). Database migrations run when the console starts; going back
to an older version across a migration means restoring the backup made
before the update (from 0.1.3, `deploy/vps/update.sh` takes it and prints
the command that goes back).

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
