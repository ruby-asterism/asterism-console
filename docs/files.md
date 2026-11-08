# Files: sending to the machines, receiving from them (T4)

The console sends a file from the browser to a machine, receives the files
the machines send to it, and records both. The carrying is Asterism's
`Asterism::Transfer` (the asterism gem's `data/transfer`, the same code a
Family mruby machine runs): pieces over calls, resent from the receiver's
position after a lost or repeated piece or a dropped connection, the whole
checked by its SHA-256. This note is the design and how it was checked;
the page is "Files" (`/files`).

## What it does

- **Send** (every signed-in user, to the nodes an admin allowed): pick a
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
  (or `FmrbTransfer`) sends, for the nodes `ASTERISM_TRANSFER_FROM` names
  (patterns with `*`; empty: nobody). Whole files go to
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

## Two keys

- **The console's**: a row of the call permissions of kind "file" ("Allow
  sending files", Admin > Call permissions) names the nodes the page may
  send to (a pattern with `*`). The page checks it when it takes the
  upload (a node no row names is a "denied" row, nothing uploaded) and the
  bridge again before it sends (a row removed meanwhile). A file row allows
  no call, and a call row (even `*/*/*` `*`) lets no file go: the column
  `kind` ("call" or "file") keeps them apart, and every existing row is a
  call row.
- **The machine's**: its `/home/asterism/receive.toml` must let the console
  in, `[file] from = ["console"]` (T2). Without it the machine refuses at
  begin and the row says so (`fmruby-xxxxxx takes no file from console
  (file from in /home/asterism/receive.toml)`).

Receiving has the console's setting only (`ASTERISM_TRANSFER_FROM`); a
machine sends to whom its user types.

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
  (`/files`), `CallPermission#kind`.
- `ASTERISM_TRANSFERS=0` leaves the bridge's side out (no inbox, nothing
  sent).

## On a server (the VPS)

- **The gem**: the console needs the asterism gem with
  `Asterism::Transfer::FileInbox` and `Endpoint` (after 0.11.0; in the
  image, the gem from rubygems.org: a release of the gem first).
- **Migrations** (two, run when the console starts): `call_permissions`
  gets `kind` (default "call": the existing rows stay what they are);
  `file_transfers` is a new table. Nothing is deleted.
- **`.env`**: `ASTERISM_TRANSFER_FROM` (who may send to the console; unset:
  nobody), and if the defaults do not suit, `ASTERISM_TRANSFER_INBOX_MAX_BYTES`
  and `ASTERISM_TRANSFER_UPLOAD_MAX_BYTES`. The files live in the `storage`
  volume (`storage/transfers/`), with the databases; the daily backup
  copies the databases only.
- **nginx**: `client_max_body_size 300m` (as for the recordings) lets a
  256 MB upload through; a larger `ASTERISM_TRANSFER_UPLOAD_MAX_BYTES` needs
  more there.
- **The router's rules** (Admin > Members > Roles, then apply): the
  console's certificate has `asterism/**` already. A machine that sends
  to the console calls `asterism/console/transfer/inbox/call/<itself>`: a
  role with that ask line (`asterism/console/transfer/inbox/call/${node}`),
  and a machine the console sends to answers on its own
  `asterism/${node}/transfer/**` (its rw lines, with
  `asterism/${node}/transfer` for its application's token).

## How it was checked (2026-11-08)

`bin/rails test` (the model, the controller, the bridge's side over a
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
