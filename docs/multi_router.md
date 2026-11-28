# Several routers, one console (idea)

Status: idea, nothing built (2026-11-28). How one console could manage the
members of a network that has more than one router, as nodes spread over
several places. The guiding rule is the owner's: **the settings are already
complex; add as little as possible.**

## What the console does today

- **Certificates are network-wide.** The signer holds one CA; a member's
  certificate (its common name is its name everywhere) is accepted by any
  router that trusts that CA.
- **The ACL is per router.** In Zenoh the access control is part of each
  zenohd's configuration and is enforced by that router on the messages
  that cross it. Zenoh has no way to spread an ACL over a network.
- **The console writes one router's configuration.** From the registry
  (members, their read/write and read-only key expressions, their roles) it
  makes `cloud.json5` for the cloud router and has it restarted
  (`restart.request`, `deploy/vps/zenohd/run.sh`). The ACL is per member
  (the certificate's common name) and per key expression: read and write,
  or read only, which `lib/relay/cloud_config.rb` expands into Zenoh's
  message kinds (put, declare_subscriber, query, reply, liveliness ...) and
  flows (ingress / egress). Roles are key templates with `${node}`.
- **Other routers are members of kind "router".** A home router gets a
  certificate to link to the cloud router, and the cloud router's ACL says
  what may come through it; its own ACL (what its local machines may do) is
  not the console's.
- What works through any router (the bridge connects to `ASTERISM_ROUTER`):
  the graph, the Terminal, the remote shell, transfers, recording. What is
  tied to the cloud router: Apply (it writes that router's file and restarts
  it), the router watch (it runs only where the console makes the router's
  configuration), the signer and the browsers' door (parts of the same
  compose).

## What zenohd allows at run time (checked in the source, 1.10.2)

Read in zenoh at tag 1.10.2 (commit cc839802); 1.10.1 not checked, assumed
the same.

- **The admin space cannot change the ACL, TLS or the endpoints.** A PUT to
  `@/<zid>/router/config/<key>` (with `adminspace.permissions.write`) goes
  through `ensure_config_key_is_dynamically_writable`, which refuses every
  key not under `plugins/` (`zenoh/src/api/config.rs`, `insert_json5`,
  `try_insert_json5_array_item`). The only listener to config changes
  (`zenoh/src/net/runtime/adminspace.rs`) starts and stops plugins and skips
  the rest.
- **The ACL is built when a connection opens.** The interceptor factories are
  made with the routing tables (`interceptor_factories(config)`), and each
  face gets its interceptors as it is created. A function that rebuilds them
  for every face exists (`TablesLock::update_config`) but is dead code, used
  only by a test.
- A DEL on the admin space is not checked the same way and could remove
  `access_control` from the configuration the admin space shows, while the
  ACL in force stays as it was (inferred, not tried). Not something to rely
  on.
- **zenohd does not reload its file.** It reads the configuration once at
  start; there is no signal handler or file watch.
- **No plugin or option distributes an ACL.** The subjects (common name,
  username, interface, protocol, zid) are matched against each router's own
  configuration.

So a router's ACL changes only by **writing its configuration file and
restarting it**, which drops its connections for a moment. That is what
Apply does today, and it stays the only way.

## A direction that adds little

1. **Decide in one place, apply at each router.** The registry stays the
   one list of members. A member row gains one field: the router it comes in
   through (empty for the cloud router, as today). From the one registry the
   console makes one configuration per router, the way it makes
   `cloud.json5` now.
2. **The router fetches its configuration.** A small helper next to each
   zenohd (the role `run.sh` plays on the VPS) asks the console, with the
   router's own certificate, for its configuration; when it differs, it
   writes the file and restarts zenohd. The console never logs in to the
   router's machine, so a router at home behind NAT works the same. The
   router watch moves into the same helper and then works for every router.
3. **Strict at the edges, open between routers.** Only the router a member
   comes in through needs that member's rules. Links between routers are
   mutual TLS with the network's CA and carry what the edge already let in,
   so each router's configuration stays small: its own members, plus "the
   other routers may pass everything".
4. **Nothing new on the pages beyond the router field.** Apply applies to
   every router whose configuration changed (each restarts once); the
   members' page shows which router each comes through.

### The other direction, for later

Checking permissions in Asterism instead of in the routers' ACLs: calls and
puts carry a signed grant that the receiving machine or app checks. Then the
rules are one set for the whole network, whatever the routers and wherever
they are, and routers need no per-member rules at all. The cost is that a
refused message still travels the network before it is refused, and every
receiver has to check. Family mruby's remote control plan keeps this as its
long-term route (G3 in fmruby-core's doc/remote_guard). The two can meet:
routers keep a coarse ACL (who may be in the network at all), Asterism the
fine one.

## Open questions

1. Whether a router-per-member field is enough, or a member may come in
   through several routers (a laptop at home and outside).
2. How the helper authenticates to the console and how often it asks
   (polling is simplest; a Zenoh queryable on the console would avoid HTTP).
3. Restarts: several routers restarting at one Apply. Staggering them, or
   applying one router at a time from the page.
4. Whether to wait for upstream: if zenoh ever wires `update_config` to
   config changes for `access_control`, the helper could PUT instead of
   restarting. Nothing points that way in 1.10.2.
