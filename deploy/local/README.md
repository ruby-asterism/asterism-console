# The rehearsal of docs/install.md on one PC

`deploy/vps` as it runs on a server, on this PC: the same compose file
and nginx server blocks, with an nginx container in place of the server's
web server (a self-signed certificate for `asterism.localtest`,
`router.localtest` and `play.localtest`), a home router run from the
`.tar` the console hands out, and a web network (172.31.240.0/24) whose
fixed addresses stand in for an admin (172.31.240.50) and a stranger (any
other).

```
deploy/local/rehearse prepare            # deploy/local/.env (fresh secrets) and the web certificate
deploy/local/rehearse build              # or: put CONSOLE_IMAGE / CONSOLE_VERSION of a pulled image in .env
ADMIN_EMAIL=admin@example.org ADMIN_PASSWORD=... deploy/local/rehearse bootstrap   # bin/asterism setup
PLAY_DIST=<a browser build's dist> deploy/local/rehearse up
# issue the home router's row (e.g. home-a) in the console, "Save all (.tar)",
# and extract it in deploy/local/certs/ (tar xf home-a.tar -C deploy/local/certs), then:
HOME_ROUTER=1 HOME_ROUTER_NAME=home-a deploy/local/rehearse up
# a game host next to the console (asterism-games): start its deploy/vps as project
# asterism-games-rehearsal with ASTERISM_PROJECT=asterism-rehearsal in its .env, then:
GAMES=1 PLAY_DIST=<dist> deploy/local/rehearse up
deploy/local/rehearse down               # VOLUMES=1 also drops the volumes (the rehearsal's CA too)
```

`NGINX_IMAGE=nginx:1.18-alpine` (in the environment of `up`) runs the
nginx of an older distribution instead of 1.27 (Ubuntu 22.04 ships 1.18),
so a directive the server's nginx does not know fails here first.
`PLAY_DIST` must be a page built for the same wire protocol as the gems
(asterism 0.7.0: protocol 1).

- The compose project is `asterism-rehearsal`; nothing is shared with other
  projects (an installation's volumes are `asterism_*`). Published on this
  PC: the router's mutual TLS on `127.0.0.1:17448`, nginx's 443 / 7443 on
  `127.0.0.1:18443` / `17443`, and the home router on
  `${HOME_ROUTER_BIND}:${HOME_ROUTER_PORT}`.
- Clients (a headless browser, curl, a CRuby container) join the network
  `asterism-rehearsal_web` with `--ip 172.31.240.50` (the admin's address)
  or another; every `*.localtest` name resolves to the nginx container
  there, which also hands 7448 on to zenohd (as a server's published port).
- `.env` sets `ASTERISM_BROWSER_PAGE` and `ASTERISM_ROOM_PAGE` to the page
  served here, so the Browser passes page has "Open the browser build" and
  a room's link opens it (rooms, docs/rooms.md).
- `.env` and `certs/` are ignored by git.
