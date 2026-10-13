# Changelog

The console's versions (`VERSION`; the image
`ghcr.io/ruby-asterism/asterism-console:<version>` carries the same
number). Each version says what an update needs (docs/install.md,
"Updating"). Database migrations run when the console starts; going back
to an older version across a migration means restoring the backup made
before the update.

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
