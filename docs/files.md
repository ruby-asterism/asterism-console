# Files: sending to the machines, receiving from them (T4, T4b, T6)

The console sends a file from the browser to a machine, receives the files
the machines send to it, and records both. The carrying is Asterism's
`Asterism::Transfer` (the asterism gem's `data/transfer`, the same code a
Family mruby machine runs): pieces over calls, resent from the receiver's
position after a lost or repeated piece or a dropped connection, the whole
checked by its SHA-256. This note is the design and how it was checked;
the page is "Files" (`/files`).

## What it does

- **Send** (every signed-in user, to the nodes of the members marked
  "Receives files from the console"): pick a
  file on the PC, the node, and whether a file of the same name is
  overwritten (otherwise the machine puts it beside it as `name(1)`) and
  whether it goes to the SD card (`/sd/inbox/`; a machine without a card
  refuses). The page uploads the file into the console's outbox
  (`storage/transfers/outbox/`, at most `ASTERISM_TRANSFER_UPLOAD_MAX_BYTES`,
  256 MB) and writes a row; the bridge sends it to `<node>/transfer/inbox`
  as the node `console` (`ASTERISM_CONSOLE_NODE`), at most two at once, on
  a thread of its own per file; the row shows how much the machine holds
  (the page asks once a second) and a Cancel button (the machine drops what
  it held). The upload is deleted when the file has gone (or failed).
- **Receive** (admins see them): the bridge answers at
  `<console>/transfer/inbox`, where a machine's `asend console <file>`
  (or `FmrbTransfer`) sends, for the nodes of the members marked "May send
  files to the console" (none marked: nobody). Whole files go to
  `storage/transfers/inbox/` (the same rules as a machine's
  `/home/inbox/`: a name that stays there, `name(1)` beside a name already
  there unless the sender asks to overwrite, the pieces hidden beside it
  until the whole is checked), at most `ASTERISM_TRANSFER_INBOX_MAX_BYTES`
  (1 GB) in all: a file that does not fit is refused before its first
  piece. The page lists them, downloads and deletes them.
- **The record**: one row per file (`file_transfers`): sent to / from, the
  node, who (the sender's account for a send), when, the file's name and
  where it was placed, its size and SHA-256, the result (done, failed,
  cancelled, denied; received: done, refused, dropped) with the reason,
  how long it took. A user sees their own sends; an admin everything,
  received files and refused senders included (a refused begin is recorded
  once a minute per node and reason).

## The members' marks (T4b, 0.3.14)

Who takes part is chosen per row of the relay registry (Admin > Members,
the row's Edit), for the nodes the row speaks for (its own name, or the
nodes behind a home router):

| Mark | The console | The cloud router's ACL (on apply) |
|---|---|---|
| May send files to the console | the bridge's inbox takes files from its nodes | ask: `asterism/<console>/transfer/inbox/call/<node>` (the query from it, the reply to it) |
| Receives files from the console | the page may send to its nodes | rw: `asterism/<node>/transfer`, `asterism/<node>/transfer/**` |

`<console>` is the bridge's node ID (`ASTERISM_CONSOLE_NODE`, `console`).
The ACL lines are the row's own rules beside its roles' (rule ids
`<row>__files_to_console_ask` and `_answer`, `<row>__files_from_console_rw`);
no role needs a line for files. The ask line carries the reply too: zenohd
1.10.1 checks a reply going to the caller against the caller's egress
rules, and a role's ask line gets that from the role's read lines; a
mark has no read lines, and with the query alone the calls went
unanswered (found on the PC through the generated ACL). A row's page lists the lines its marks give, the
Members list shows the marks, and a changed mark needs an apply like any
other change of the registry. A disabled row's nodes neither send nor
receive (the console's side too, before the apply).

- **Sending, the console's key**: the page checks the mark when it takes
  the upload (another node is a "denied" row, nothing uploaded) and the
  bridge again before it sends (a mark cleared meanwhile). Call
  permissions have nothing to do with files: a call row (even `*/*/*` `*`)
  lets no file go.
- **Sending, the machine's key**: its `/home/asterism/receive.toml` must
  let the console in, `[file] from = ["console"]` (T2). Without it the
  machine refuses at begin and the row says so (`fmruby-xxxxxx takes no
  file from console (file from in /home/asterism/receive.toml)`).
- **Receiving**: the bridge reads the marks again every 2 seconds
  (`Bridge::Transfers::FROM_EVERY`), so a mark set or cleared takes effect
  without restarting it; a node not marked is refused at begin
  (`console takes no file from <node>`, a "refused" row). A machine sends
  to whom its user types.

0.3.13 had `ASTERISM_TRANSFER_FROM` (`.env`) for receiving and call
permissions of kind "file" ("Allow sending files") for sending. The
migration of 0.3.14 (`db/migrate/*_member_file_marks.rb`) marks the rows
that speak for a node one of their patterns matches, says the patterns
that match no row, then deletes the file rows and the column `kind`.

## Who a machine receives from (T6, 0.3.16)

A row's Edit also chooses who its machines (the nodes it speaks for)
receive files from, one list per kind: "Files (to /home/inbox)" (kind
`file`) and "Apps moved here (checkpoint)". The choices are the nodes of
the registry's rows and the console's; a client row's own node is left
out, a home router's nodes may send to each other. Under them, patterns and
other nodes, one per line (`fmruby-*`, `*` for every member): letters,
digits, `.` `_` `-` and `*`, at most 64. The row's page shows the lists and
what each of its machines holds.

| Where | What |
|---|---|
| The cloud router's ACL (on apply) | every row with a node a list names or matches gets, for that node and each node of the receiving row, ask `asterism/<receiver>/transfer/inbox/call/<sender>` and the reply to it (`<row>__sends_files_ask` / `_answer`); the receiving row, once its lists were ever chosen, rw `asterism/<node>/transfer` and `asterism/<node>/transfer/**` (`<row>__receives_files_rw`; kept when the lists are emptied, so that the empty list still reaches the machine). The two kinds share the inbox: the ACL does not tell them apart, the machine does |
| The bridge (`Bridge::Receivers`) | calls `<node>/transfer/inbox` `policy_set({"file" => [...], "checkpoint" => [...], "at" => <when the lists changed>})` as the console's node: when the lists changed, when the machine's transfer app appears (again), every 10 minutes while it stays, and 30 s after a failure. What each node got (or why not) is kept on the row (`receivers_delivered`) and said once in the bridge's log |
| The machine (Family mruby's transfer app) | takes the list from the console's node only (`console` in its `/home/asterism/config.toml`, `console` by default), and only over a connection with its certificate (a `tls/` router: the router's ACL binds the caller's node ID to its certificate there). It writes the list below a mark in `/home/asterism/receive.toml` (`[managed]` `by`, `at`; `[managed.file]` and `[managed.checkpoint]` `from`), only when it changed (the flash is not written for the same list), leaves the part above the mark (written by hand) as it is, and takes a kind from the nodes of both parts. While the console cannot be reached it goes on with the last list it wrote (no time limit). The shell's `asend -l` shows both parts |

A machine with the console's credentials (a `.tar` in `/home/asterism/`)
starts its transfer app at boot, receive.toml or not, so that the list can
reach it.

**Connections without certificates.** On a connection without
certificates (a home router's `tcp/`, peer to peer, the browser build's
`ws/`) any node could call as `console`, so a machine there refuses the
list ("takes no list from console over a connection without certificates")
and the row shows that reason. Such a machine receives what its
receive.toml says by hand (and a list it took earlier over a `tls/`
router). The native Linux program and the simulation have no TLS link
(`Z_FEATURE_LINK_TLS`) today, so the list reaches the ESP32 boards that
connect to the cloud router with their certificate.

The marks above stay: "Receives files from the console" is the console's
key for sending; the machine's key is its receive.toml, by hand (`[file]
from = ["console"]`) or by choosing `console` in the row's list.

## How it is built

- `Asterism::Transfer::FileInbox` and `Asterism::Transfer::Endpoint`
  (asterism gem, CRuby only, `require "asterism/transfer"`): the receiver
  of the kind "file" with a Family mruby machine's rules, and an inbox
  answering at `<node>/transfer/inbox` on a Zenoh connection beside the
  application `Asterism.connect` made. Asterism's object layer is one
  application per process (the bridge's is `console/console`); the
  machines send to `<node>/transfer/inbox`, so the endpoint declares that
  application's and object's tokens and answers their calls and meta with
  the object layer's encoding, on the bridge's reading session. The graph
  shows the console with two applications, `console` and `transfer`.
- `Bridge::Transfers` (`lib/bridge/transfers.rb`): the inbox in
  `storage/transfers/` (notes of a file coming in under `work/`: a bridge
  started again goes on with a file it held, and a hidden piece no note
  speaks for is deleted), the rows of what arrives (the receiving thread
  hands them to the main loop through a queue), the senders.
- `FileTransfer` (the rows; `storage/transfers/` is under the gitignored
  `storage/`, `ASTERISM_TRANSFERS_DIR` moves it), `TransfersController`
  (`/files`), `RelayPeer#files_to_console` / `#files_from_console`
  (`RelayPeer.file_senders`, `.file_receivers`), the ACL lines in
  `Relay::CloudConfig#file_rules`.
- `Bridge::Receivers` (`lib/bridge/receivers.rb`): the lists to the
  machines, one call at a time on a thread of its own (10 s per call).
  `RelayPeer#receivers`, `#receivers_payload`, `.managed`,
  `.sender_choices`; the ACL lines in `Relay::CloudConfig#file_lines`
  (`sender_keys`).
- `ASTERISM_TRANSFERS=0` leaves the bridge's side out (no inbox, nothing
  sent, no lists).

## On a server (the VPS)

- **The gem**: the console needs the asterism gem with
  `Asterism::Transfer::FileInbox` and `Endpoint` (0.12.0; the image takes
  it from rubygems.org).
- **Migrations** (two, run when the console starts): `call_permissions`
  gets `kind` (default "call": the existing rows stay what they are);
  `file_transfers` is a new table. Nothing is deleted.
- **`.env`**: if the defaults do not suit, `ASTERISM_TRANSFER_INBOX_MAX_BYTES`
  and `ASTERISM_TRANSFER_UPLOAD_MAX_BYTES`. The files live in the `storage`
  volume (`storage/transfers/`), with the databases; the daily backup
  copies the databases only.
- **nginx**: `client_max_body_size 300m` (as for the recordings) lets a
  256 MB upload through; a larger `ASTERISM_TRANSFER_UPLOAD_MAX_BYTES` needs
  more there.
- **The router's rules**: the members' marks, then apply (above). The
  console's certificate has `asterism/**` already.

## How it was checked

T4 (2026-11-08, 0.3.13, before the marks): `bin/rails test` (the model, the controller, the bridge's side over a
stand-in connection: receive, refuse, send, overwrite, the permission
removed, cancel; the call permissions' kinds). On the PC: zenohd 1.10.1,
the console from the source (`bin/dev`) and a Family mruby native program
(`fmruby-t4a`, `receive.toml` `[file] from = ["console"]`), the pages in a
headless Chromium (`script/headless`):

- the page sends 1.5 MB (placed, then `photo(1).bin` beside it, then over
  it with Overwrite; the machine's files have the sent SHA-256), a 40 MB
  file cancelled on its way (the machine dropped its piece file at 5.7 MB);
- `asend console /home/inbox/photo.bin` in the machine's Shell: placed in
  `storage/transfers/inbox/` (then `photo(1).bin`), downloaded from the
  page with the same SHA-256; a node `ASTERISM_TRANSFER_FROM` does not name
  is refused at begin and recorded;
- a node no file row names: "denied", nothing sent; the SD card on a
  machine without one, and a machine whose `receive.toml` does not name
  the console: failed with the machine's reason;
- the record shows all of it (sent / from, node, name, placed name, size,
  SHA-256, result, who).

T4b (2026-11-08): `bin/rails test` (the migration with patterns that match
rows and patterns that match nobody, and back down; the ACL lines and what
zenohd decides with them; a member's form, list and page; the Files page's
suggestions and senders; the bridge taking a mark set or cleared while it
runs). On the PC: zenohd, the console from the source and the CRuby sender
`fmruby-core/tools/fmrb_send.rb`: a marked node's file placed in the
inbox, an unmarked one refused at begin, the mark cleared and set on the
running bridge; the generated `cloud.json5` with the lines of both marks.

T6 (0.3.16): `bin/rails test` (the lists on the form, the ACL lines with
`AclEvaluator`, the bridge's sending with a stand-in machine, the
migration). On the PC: a cloud zenohd with the ACL made from a working
copy's registry (mTLS), a home zenohd with a router certificate, three
native programs behind it, the bridge with the console's certificate. The
list chosen on the page reached the three machines after the apply, and
each refused it (their connection is the home router's `tcp/`); the row's
page showed the reason. The machine's own part (written by its transfer
app, taken and refused by it, kept while the console is stopped and after
a restart) was checked on the native programs and in Family mruby's
`rake regress:transfer:quick` (fmruby-core doc/asterism_file_transfer/report/t6.md).
