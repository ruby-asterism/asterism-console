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

1. **Decide in one place, the same rules at every router.** The registry
   stays the one list of members, and the console gives every router the
   same ACL made from it (plus each router's own links). No new field on
   the members' page: which router a member comes in through does not
   matter, and a member that moves (a laptop at home and outside) needs
   nothing. The rules grow only inside the routers' files. A router whose
   local machines connect over plain TCP (no certificate, so no name to
   match) trusts what comes in on that interface, as a home router does
   today.
2. **Start without a helper.** For two or three routers, the members' page
   offers each router's configuration file to download; its owner puts it
   in place and restarts zenohd. Nothing new runs anywhere.
3. **A helper next to each zenohd, when there are more.** It does what
   `run.sh` does on the VPS, and fetches its configuration over Zenoh, not
   HTTP: the console answers at `relay/config/<router name>`, and the ACL
   lets a router query only the key with its own name (the same pattern as
   calls under one's own name). No new port, no new credential: the
   router's certificate is the credential. It asks at start, when the
   console puts "changed" for it, and every ten minutes or so as a fallback;
   when the file differs it writes it and restarts zenohd. The router watch
   moves into the helper and then works for every router.
4. **Apply one router at a time.** Each router restarts after the one
   before has come back (checked the way the router watch checks), the
   cloud router last, since the other routers' helpers reach the console
   through it. The page shows each router as applied or waiting.

## Checking permissions in Asterism (for later)

**Today** the receiving side already decides: the transfer inbox's receive
lists and the remote shell look at who the caller is. The caller's name is
the last part of the call's key (`asterism/<node>/transfer/inbox/call/<caller>`),
and the router's ACL makes it trustworthy: a member may call only under its
own name. So the routers do not decide what a member may do so much as
guarantee that names cannot be forged.

**In Asterism** that guarantee would travel with the message: a call (and a
put) carries a signature made with the caller's private key over the target,
the method, a digest of the arguments, a time and a nonce, and the receiver
checks it against the network's CA. Every member already has a certificate
and key from the console's signer, so nothing new is handed out. The name
then holds whatever routers the message crossed, and routers need only a
coarse ACL: who may be in the network at all.

What it changes: a new wire protocol version, signing and checking in every
implementation (the CRuby gem, mruby and PicoRuby on the boards, the browser
build), an ECDSA check per call on an ESP32 (tens of milliseconds expected,
not measured), clocks and replay. And it protects calls and writes only:
who may subscribe and read still needs the routers' ACL (or encryption). It
complements the ACL rather than replacing it.

**Not per call on a microcontroller** (the owner, 2026-11-28): a public-key
check on every call is too heavy for the boards. If names ever have to hold
without the routers, the heavy check would happen once per peer (both sides
check each other's certificate and agree on a shared key, as a TLS
handshake does) and each call would carry a short MAC made with that key (a
hash's worth of work). Even that brings per-peer keys, redoing it after a
restart and a protocol change, so as long as the same ACL reaches every
router, the routers keeping names honest stays the simpler way. Family mruby's remote control
plan keeps the same idea as its long-term route (G3 in fmruby-core's
doc/remote_guard).

## Open questions

1. Whether giving every router the whole ACL stays small enough as the
   registry grows (it is text in a file; nothing measured).
2. When to add the helper (how many routers make downloading by hand a
   chore).
3. Upstream: `TablesLock::update_config` already rebuilds every face's
   interceptors and is only unused. Wiring it to a write of
   `access_control` could be a small upstream pull request; with it, the
   helper could change the rules without a restart (no dropped
   connections). Worth trying once the open one (zenoh #2619) moves.
