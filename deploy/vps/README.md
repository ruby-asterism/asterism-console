# deploy/vps: Asterism on a server

What runs on a server: the internet router (zenohd), the console, its
bridge, its signer and the browsers' door, from the published image.
**The steps are in [docs/install.md](../../docs/install.md).**

| File | |
|---|---|
| `docker-compose.yml` | the stack (project `asterism`); the console's image is `${CONSOLE_IMAGE}:${CONSOLE_VERSION}` |
| `docker-compose.build.yml` | add it to build the image here instead of pulling it (install.md 18) |
| `env.example` | the settings, copied to `.env` (never committed) |
| `zenohd/run.sh` | the router's container: starts zenohd on the configuration the console writes, restarts it when the console asks |
| `Dockerfile` | the console's image (published by `.github/workflows/image.yml` for each `v*` tag, amd64 and arm64) |
| `nginx/` | an example of the web server in front: nginx (install.md 8) |
| `caddy/Caddyfile` | the same with Caddy 2 |
| `check_node.rb` | a CRuby node for checking a new server (`--credentials <name>.tar`) |

The web server, the firewall and how the stack starts with the server are
yours to choose; nginx, Caddy and a systemd unit are examples, and plain
`docker compose up -d` with Docker starting at boot is enough.

The same layout runs on one PC, with an nginx container in place of the
server's and names under `.localtest`: `deploy/local/README.md`.

This directory keeps its place (`deploy/vps/`): an existing server's own
compose file may take it in (`include:`), and the volumes keep the project
name `asterism`.
