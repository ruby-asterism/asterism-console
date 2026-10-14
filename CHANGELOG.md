# Changelog

The console's versions (`VERSION`; the image
`ghcr.io/ruby-asterism/asterism-console:<version>` carries the same
number). Each version says what an update needs (docs/install.md,
"Updating"). Database migrations run when the console starts; going back
to an older version across a migration means restoring the backup made
before the update.

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
