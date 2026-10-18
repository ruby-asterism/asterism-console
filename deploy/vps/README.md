# deploy/vps: Asterism on a server

What runs on a server: the internet router (zenohd), the console, its
bridge, its signer, the browsers' door and the daily backup of the
console's databases, from the published image.
**The steps are in [docs/install.md](../../docs/install.md).**

| File | |
|---|---|
| `docker-compose.yml` | the stack (project `asterism`); the console's image is `${CONSOLE_IMAGE}:${CONSOLE_VERSION}` |
| `docker-compose.games.yml` | add it when a game host (asterism-games) runs next to the console: its status on the rooms' page, its saved tables in the daily backup (install.md 12) |
| `docker-compose.build.yml` | add it to build the image here instead of pulling it (install.md 18) |
| `env.example` | the settings, copied to `.env` (never committed) |
| `update.sh` | updating (or going back) in one command: a backup, the tag, `.env`, pull, setup, restart, a check (install.md 15, 16) |
| `zenohd/run.sh` | the router's container: starts zenohd on the configuration the console writes, restarts it when the console asks |
| `Dockerfile` | the console's image (published by `.github/workflows/image.yml` for each `v*` tag, amd64 and arm64) |
| `nginx/` | an example of the web server in front: nginx (install.md 8) |
| `caddy/Caddyfile` | the same with Caddy 2 |
| `exposure.example.yml` | the checks of `bin/asterism-exposure`: what the outside should see of the server (docs/exposure.md) |
| `check_node.rb` | a CRuby node for checking a new server (`--credentials <name>.tar`) |

Updating, from this directory (`--dry-run` prints the steps; `--help`
lists the options for sudo, a systemd unit and a compose file of your own):

```
git fetch --tags
./update.sh 0.2.2
# going back, with the data from before the update (update.sh prints this line):
./update.sh 0.1.3 --restore asterism-<date>-<time>-0.1.3-before-0.1.4.tar.gz
```

Backups: the `backup` service copies the databases into the `backups`
volume every day (`ASTERISM_BACKUP_HOUR`, keeping `ASTERISM_BACKUP_KEEP`);
`docker compose exec console bin/asterism backups` lists them and
`bin/asterism restore <name>` puts one back (install.md 14, 16). The CA's
key is not in them: copy it off the server once, after the first setup
(install.md 14).

The web server, the firewall and how the stack starts with the server are
yours to choose; nginx, Caddy and a systemd unit are examples, and plain
`docker compose up -d` with Docker starting at boot is enough.

The same layout runs on one PC, with an nginx container in place of the
server's and names under `.localtest`: `deploy/local/README.md`.

This directory keeps its place (`deploy/vps/`): an existing server's own
compose file may take it in (`include:`), and the volumes keep the project
name `asterism`.
