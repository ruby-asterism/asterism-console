# The rehearsal of deploy/vps on one PC

`deploy/vps` as it would run on the server, on this PC: the same compose
file and nginx server blocks, with an nginx container in place of the
server's nginx (a self-signed certificate for `asterism.localtest`,
`router.localtest` and `studio.localtest`), a home router for boards on the
LAN, and a web network (172.31.240.0/24) whose fixed addresses stand in for
an admin (172.31.240.50) and a stranger (any other).

```
deploy/local/rehearse prepare            # deploy/local/.env (fresh secrets) and the web certificate
deploy/local/rehearse build
ADMIN_EMAIL=admin@example.org ADMIN_PASSWORD=... deploy/local/rehearse bootstrap
STUDIO_DIST=<a browser build's dist> deploy/local/rehearse up
HOME_ROUTER=1 HOME_ROUTER_BIND=0.0.0.0 HOME_ROUTER_PORT=7447 deploy/local/rehearse up   # with the home router
deploy/local/rehearse down               # VOLUMES=1 also drops the volumes (the rehearsal's CA too)
```

`NGINX_IMAGE=nginx:1.18-alpine` (in the environment of `up`) runs the
nginx of the server's distribution instead of 1.27 (Ubuntu 22.04 ships
1.18), so a directive the server's nginx does not know fails here first.
`STUDIO_DIST` must be a dist built from the same wire protocol as the gems
(asterism 0.7.0: protocol 1); an older dist connects and plays with other
old browsers but answers nobody else.

- The compose project is `asterism-rehearsal`; nothing is shared with other
  projects. Published on this PC: the router's mutual TLS on
  `127.0.0.1:17448`, nginx's 443 / 7443 on `127.0.0.1:18443` / `17443`, and
  the home router on `${HOME_ROUTER_BIND}:${HOME_ROUTER_PORT}`.
- Clients (a headless browser, curl) join the network
  `asterism-rehearsal_web` with `--ip 172.31.240.50` (the admin's address)
  or another; the names resolve to the nginx container there.
- The home router reads `certs/home/` (its certificate, key and the CA):
  issue `zenohd-home` (a router with the role "match", its boards under
  "Nodes it speaks for") in the console and save the three files there.
- `.env` sets `ASTERISM_BROWSER_PAGE` to the studio served here, so the
  Browser passes page has "Open the browser build".
- `.env` and `certs/` are ignored by git.
