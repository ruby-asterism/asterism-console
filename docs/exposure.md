# Checking what the outside sees (exposure check, 0.3.6)

Changing what a server lets in (nginx's allow lists
`asterism-door-allow.conf` and `asterism-admin-allow.conf`, a location in
`asterism-console.conf`, the provider's packet filter, `DOCKER-USER`
rules) can open more than meant, or close an entrance that should be
open. `bin/asterism-exposure` asks the server from outside, as a stranger
would, and compares the answers with a list of what they should be:

- an HTTP path's status code (`/invite` 200, `/` 403, `/admin/rooms` 403),
  optionally that the body contains a text;
- an asset the page loads (`/assets/...css` or `.js`, picked from the
  page, since its name changes with every build);
- whether a TCP port takes a connection (the browsers' door, 7443) or not
  (the router's mTLS port, 7448, open only to the allowed addresses).

It prints one line per check and exits 1 when one does not match. Run
on a schedule (below), a failure becomes GitHub's email.

## Why from outside

From the server itself, a request to its own name does not pass the
provider's packet filter, and often not nginx's address checks the way a
stranger's does: it would say "fine" for a port that the filter closes,
or that is open to the whole internet. From an admin's home the answers
are those for an allowed address. A GitHub Actions runner is neither, so
it sees what everyone else sees.

The checks run in **your own private repository**, not in
asterism-console's: the console is public, and its Actions must not knock
on anyone's server. Your server's names stay in that repository's
secrets; they are in no file and in no log.

## The checks (YAML)

`deploy/vps/exposure.example.yml` is a starting point. The file names no
host, so it can be public; copy it and change the paths, ports and
answers to match your nginx and your firewall.

```yaml
scheme: https        # defaults for every check (each may set its own)
timeout: 5           # seconds, for connecting and for reading
checks:
  - http: /invite              # GET; a redirect is not followed
    status: 200                # one code, or a list: [302, 403]
    body: "Make a room"        # optional: the body contains this text
  - asset_from: /invite        # the first /assets/*.css or .js in the page
    status: 200                # the asset's status (default 200)
  - http: /
    status: 403
  - tcp: 7443
    host: router               # this check's host: ASTERISM_EXPOSURE_HOST_ROUTER
    expect: open
  - tcp: 7448
    host: router
    expect: closed             # a timeout or a refusal both pass
    timeout: 5
```

| Key | |
|---|---|
| `http` | a path; its status must be one of `status`; with `body`, the body must contain that text |
| `asset_from` | a page's path; the page must answer 200 and name an `/assets/...css` or `.js`, whose status must be one of `status` (default 200) |
| `tcp` | a port; `expect: open` (a connection is made) or `closed` (it times out, or is refused or unreachable) |
| `host` | which host the check asks (below); without it, the default host |
| `scheme`, `port` | `https` (default) or `http`, and the HTTP port (default 443 / 80) |
| `timeout` | seconds (default 5) |

Redirects are not followed, so a 302 to the sign-in page and a 403 are
told apart (a mismatch shows where the redirect points, the host left
out). HTTPS checks the certificate as a browser does: an expired or
wrong certificate fails the check. A connection that fails (refused,
timed out, a TLS error, a name that does not resolve) fails that check
alone; the others still run. A `closed` port whose name does not resolve
fails too: that says nothing about the port.

## The hosts

The host names come from the environment, never from the file:

- `ASTERISM_EXPOSURE_HOST`: the default host (the console's name);
- `ASTERISM_EXPOSURE_HOST_<NAME>`: the host of the checks with
  `host: <name>` (`ASTERISM_EXPOSURE_HOST_ROUTER` for `host: router`);
  when the router has the console's name, set both to the same name.

or from `--host value` / `--host name=value`. A check whose host is not
given stops the run before anything is asked (exit 2).

The output never names a host: it prints `<host>` (or `<router>`), and
cuts the names and their addresses out of any message (a redirect's
target, a TLS error), so the log can be read by anyone with access to the
repository, whether or not GitHub's secret masking catches it.

```
ok    http  https://<host>/invite              expected 200            actual 200
ok    asset https://<host>/assets/application-0a1b2c3d.css expected 200            actual 200
FAIL  http  https://<host>/                    expected 403            actual 302 -> https://<host>/session/new
ok    tcp   <router>:7443                      expected open           actual open
FAIL  tcp   <router>:7448                      expected closed         actual open
3 passed, 2 failed
```

Exit status: 0 when every check passes, 1 when one fails, 2 for a usage
or configuration error (no host, a file that does not parse).

## From your own machine

Plain Ruby (3.1 or later): no Rails, no `bundle install`.

```
ASTERISM_EXPOSURE_HOST=asterism.example.org ASTERISM_EXPOSURE_HOST_ROUTER=router.example.org \
  ruby bin/asterism-exposure deploy/vps/exposure.example.yml
```

From an admin's address the admin pages answer differently (they are
allowed): run it from somewhere else (a phone's tethering, say) to see
the outside's answers, or rely on the scheduled run.

## Scheduled, in a private repository

1. On GitHub, make a **private** repository of your own (e.g.
   `asterism-watch`). Put your checks in it as `exposure.yml` (from
   `deploy/vps/exposure.example.yml`).
2. In that repository, Settings > Secrets and variables > Actions > New
   repository secret: `ASTERISM_EXPOSURE_HOST` (the console's name, e.g.
   `asterism.example.org`) and `ASTERISM_EXPOSURE_HOST_ROUTER` (the
   router's name).
3. Add the workflow below as `.github/workflows/exposure.yml`, push, and
   run it once by hand (Actions > exposure > Run workflow) to see the
   first output.

```yaml
# Asks your server from outside every 6 hours whether it answers as
# exposure.yml says (asterism-console's bin/asterism-exposure,
# docs/exposure.md). A failed run is GitHub's email to you.
name: exposure

on:
  schedule:
    - cron: "17 */6 * * *"   # every 6 hours (UTC), at a minute other jobs do not crowd
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: exposure
  cancel-in-progress: false

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: This repository (exposure.yml)
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: asterism-console at a fixed version
        uses: actions/checkout@v4
        with:
          repository: ruby-asterism/asterism-console
          ref: v0.3.6
          path: asterism-console
          persist-credentials: false

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"

      - name: Check
        env:
          ASTERISM_EXPOSURE_HOST: ${{ secrets.ASTERISM_EXPOSURE_HOST }}
          ASTERISM_EXPOSURE_HOST_ROUTER: ${{ secrets.ASTERISM_EXPOSURE_HOST_ROUTER }}
        run: ruby asterism-console/bin/asterism-exposure exposure.yml
```

- **The email**: GitHub writes to you when a run fails, by default by
  email (your Settings > Notifications > Actions). For a scheduled
  workflow it writes to the user who last changed the `cron` line: push
  that change yourself.
- **The version**: `ref:` pins asterism-console's tag, so a new release
  changes nothing until you change the line. The tool needs 0.3.6 or
  later.
- **Minutes**: four runs a day of well under a minute each, about 120 of
  the private repositories' monthly Actions minutes (GitHub counts each
  run as at least one minute).
- Schedules start late when GitHub is busy, and a run is sometimes
  skipped; a run by hand is always there.
- After changing your nginx or firewall, run it by hand, and change
  `exposure.yml` in the same commit when the answers are meant to change.
