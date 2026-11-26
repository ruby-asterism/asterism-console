# The Terminal: the asterism command line in the console (VT1, VT2), and the remote shell (R3)

A page (`/terminal`, "Terminal" in the menu) where a signed-in user types
the commands of the asterism gem's command line (`asterism node list`,
`tree`, `status echo`, `call`, ...) and sees their output as a terminal
shows it: the same names, arguments, output and colours as on a PC with
the gem installed, without the gem or a certificate on the device in hand
(a phone or a tablet away from home is enough). What the PC's command line
does not have is added: the console's sign-in, the call permissions, and a
record of who typed what. This note is the design and how it was checked.

## What it does

- **The commands** are the asterism command line's own, run by the bridge
  on its connection: the console's node (`ASTERISM_CONSOLE_NODE`), its
  certificate and what the router's ACL lets it see. No second session is
  opened and no certificate per user is used: who typed a command is in the
  record instead. A leading `asterism` may be typed or left out.
- **Who may run what** (`lib/terminal/line.rb`, and the command line's own
  plan in the bridge):

  | Commands | Kind | Who |
  |---|---|---|
  | `node list/info`, `app list/info`, `object list/info/find/get/echo`, `status get/echo/hz`, `tree`, `watch`, `ping PATH`, `nodes`, `objects`, `echo`, `help`, `version` | read | every signed-in user |
  | `call PATH METHOD [ARG...]`, `ping PATH --call METHOD [ARG...]` | call | when a call permission allows the object and the method (the page's rows, Admin > Call permissions) |
  | `mcp`, `completion` | local (a server on stdio, a shell script) | nobody |
  | anything else (`ls`, `sh`, ...), `__complete` typed | | nobody: "not an asterism command" |

  The kinds are the gem's (`Asterism::CLI.kind`: every command reads,
  except `call` and `ping --call`). Refused too: the options that choose
  another connection (`--router`, `--credentials`, `--peer`, `--node`,
  `--app`), and `--timeout` above 30 s (a command's wait holds a thread of
  the bridge, as the page's calls do: `BridgeRequest::MAX_TIMEOUT`).
  Sending files is not a command of the command line (0.12.0), so the
  members' file marks (T4b) have nothing to apply to here yet.
- **No shell**: the line is split into words as a shell would (quotes,
  backslashes) by Ruby's `Shellwords`, and the words are handed to the
  command line (`Asterism::CLI#run`) as they are. Nothing is given to a
  shell or to `system`, and a first word that is not in the command
  line's table is refused before anything runs. The command line itself,
  given the bridge's connection, takes no connection options, never runs
  `mcp` or `completion`, and takes long options only as written in full
  (OptionParser would otherwise read `--cal` as `--call`: a call that
  would pass for a read).
- **The page**: xterm.js (vendored, `vendor/javascript/@xterm--xterm.js`,
  6.0.0, with its fit addon; loaded only by this page). The line is edited
  in the page: left / right, Home / End, Backspace / Delete, Ctrl-U /
  Ctrl-K, Ctrl-L clears; up / down recall the history (the last 200 lines,
  kept in the browser per user); Tab asks the bridge for the candidates
  (the command line's `__complete`: the commands, verbs, options, and the
  nodes, `node/app`, `node/app/object` a part at a time, an object's
  methods after `call PATH`), puts the one in, extends the word as far as
  several agree, or lists them; Enter sends the line; Ctrl-C stops the
  command running (or drops the line). The output keeps the command
  line's colours and is laid out at the page's width.
- **Streams** (`watch`, `object echo`, `status echo`, `status hz`, a long
  `ping`) run until Ctrl-C, `--duration`, or the page is closed: the
  bridge then stops them (the page leases its token every 10 s and
  releases it on pagehide; a page that just goes away is forgotten after
  30 s). A command stops within a second of being asked (the bridge
  reads the request every 0.5 s; a call already waiting for its answer
  finishes its wait first).
- **Limits**: one command at a time per page; at most
  `ASTERISM_TERMINAL_PER_USER` (3) running per user across their pages
  (refused with the reason) and `ASTERISM_TERMINAL_MAX` (12) in all (the
  others wait their turn; one not started within 30 s expires); a command
  that prints more than `ASTERISM_TERMINAL_MAX_OUTPUT` (4 MB) is stopped;
  the page gets at most 64 KB per 0.1 s. A line is at most 2000 bytes and
  64 words. Four Tabs are answered at once.
- **The record** is the call log: each line typed (`terminal_commands`,
  kind "run") with who, when, the line, its kind (read / call, the object
  and method of a call), how it ended (ok, failed, denied, stopped,
  expired) with the exit code and the reason, how long it took, and the
  first 2000 bytes of its output without the colours. Refused lines are
  kept as "denied", as the page's refused calls are. "Call log" shows them
  under "Terminal commands" (a user their own, an admin everyone's, the
  last 200). No page or route removes them, and they are kept as long as
  the call log's rows (there is no expiry for either). Tabs are not
  recorded (they read names only; their rows are removed once answered).

## The remote shell: into a Family mruby machine (R3)

`remote <node>` in the Terminal goes into a machine: the prompt becomes
`<node>:<cwd>$ ` and each line typed runs on the machine, a line at a
time (no full screen, no Ruby of one's own). For supporting a machine one
handed to someone, without being on its network: the call goes through the
router like any other. The machine's side is Family mruby's transfer app
(`<node>/transfer/rshell`; fmruby-core `doc/remote_shell`).

- **Using it**: `remote` lists the machines whose remote shell is on the
  network now; `remote <node>` goes in; then the machine's commands
  (`help` lists them: `pwd`, `cd`, `ls`, `cat`, `head`, `tail`, `stat`,
  `df`, `free`, `ps`, `ver`; `cp`, `mv`, `rm`, `mkdir`, `kill`, `open`);
  `exit` or Ctrl-D on an empty line leaves. Tab completes the command's
  name, a path on the machine (a name with a blank goes in as `my\ file`),
  the apps for `open` and `kill`; one candidate is put in, several as far
  as they agree, or listed. Ctrl-C stops a long output or a wait between
  two calls (one call already on the machine finishes first). The history
  is the Terminal's. `get` and `put` are kept for the console's file
  commands (a later version) and refused now.
- **Long output** comes 8 KB per call; the bridge asks for the rest
  (`more`) and passes it on as it comes, up to the machine's 64 KB (the
  machine writes the note when it cuts). `kill` and `open` answer that they
  asked; the bridge asks again every 0.25 s until the result is in (the
  machine gives up after 5 s).
- **A change of the system's area**: a line that changes a path outside
  `/home`, `/app`, `/mnt/sd` and `/tmp` (folded from where the session is,
  as the machine folds it: `rm ../etc/x` from `/home` is `/etc/x`) is not
  sent at once: the page asks `... is in the system's area of <node> ...
  Go on? (y/N)`, and only `y` sends it (the record says "confirmed"). The
  paths looked at: every path of `rm`, `mv` and `mkdir`, the destination of
  `cp`; `kill` and `open` change no path.
- **One page at a time per machine**: the machine sees one caller, the
  console, so the console keeps the others out ("another user of the
  console is in ...", "you are in ... on another Terminal page").

### Who may

Three keys, all needed:

| Where | What | Who sets it |
|---|---|---|
| The user (Admin > Users, "Remote shell") | none (the default, admins too) / read only / read and change | an admin, for anybody, themselves included |
| The member's row (Admin > Members, Edit) or the user's browser (Members > Browsers, Edit) | "Remote shell from the console": its nodes let the console in | an admin; sent to the machines with the receivers' lists, kind `rshell` (`["console"]`, or `[]` when not ticked), and kept in their `/home/asterism/receive.toml` |
| The machine | its owner turns the remote shell on (the Receiving app; `rshell_enabled = true`) | the machine's owner |

- "read only" sends the machine's read commands (`exec_read`), "read and
  change" also the others (`exec_write`). Which is which is the machine's
  own table (its `open` answers it); the console keeps none, and a word the
  machine did not name is not sent. The machine checks again (a change
  sent to `exec_read` is refused there).
- **Checked twice**, as the Terminal's calls are: by Rails when the line is
  typed (`Terminal::Remote` with the user's permission and the machine's
  table) and by the bridge before it sends it (the permission of that
  moment, and the paths). "none" refuses everything but `exit`.
- **Not through a call**: no call permission covers
  `<node>/transfer/rshell`, even `*/*/*` `*`: the page's calls and the
  Terminal's `call` are refused ("only the Terminal's remote <node> calls
  it"). Only the remote shell calls it.
- **The router**: every subject whose rules would let it query a remote
  shell (an ask line `asterism/*/*/*/call/${node}`, rw or ro `asterism/**`,
  a machine's own transfer keys ...) gets the shared deny
  `no_rshell_calls` (queries on `asterism/*/transfer/rshell` and below);
  the console's own certificate does not. A deny wins inside a subject, so
  no other member calls a machine's remote shell, whatever its roles say
  (checked through a real router: `test/lib/relay/rshell_acl_live_test.rb`).
  The machine's own keys (its queryable, the replies) come with the
  transfer keys a row gets once its lists are managed; ticking the mark
  makes the row managed. A change of the mark needs an apply like any
  other.
- **The machine** takes the remote shell only over a checked connection
  (a `tls/` router with certificates, or the console's door in the browser
  build), and only from the nodes in its `rshell` lists (from the console,
  or by hand).

### Why it does not go in

The page says it in the console's words, the machine's own after them in
brackets:

| The page says | Why |
|---|---|
| you may not use the remote shell | the user's permission is "none" |
| `rm`: changes the machine; you may only read | the user's permission is "read only" |
| `<node>` is not on the network now | nothing of the node is there |
| the remote shell is off on `<node>` | the machine has no `transfer/rshell` (`no_object`): its owner has not turned it on |
| `<node>` does not let this console in | the machine's `rshell` list does not have the console: tick the mark and Apply (and wait for the list to reach it) |
| `<node>` takes the remote shell only over a checked connection | not a `tls/` router with certificates (nor the door) |
| someone else is in `<node>` now | another caller holds the machine's one session |
| another user of the console is in `<node>` / you are in `<node>` on another Terminal page | the console's one page per machine |
| `<node>` did not answer open in 10 s | the machine is gone, or the router's ACL does not let the console reach it |
| the session on `<node>` has ended | not used for 5 minutes, or the machine restarted: the page leaves the machine |
| not a command of this remote shell / not in this version of the console | a word the machine did not name / `get`, `put` |

### How it is built

- **Rails** (`TerminalsController`): `remote` and `remote <node>` are read
  before the command line's table. While the page's `TerminalSession` says
  it is in a machine (its `remote` column: the node, the machine's table
  and where it is, JSON, written by the bridge), a line is the remote
  shell's (`Terminal::Remote`). The page says where it believes it is with
  every line; when that is not so (the bridge restarted, the session
  ended), the line is refused with where it is, and the prompt follows.
- **The bridge** (`Bridge::Terminal`, `Bridge::RemoteShell`) keeps a
  session per page in memory: the machine's session number never leaves
  it. A line runs on the command's thread like the command line's (the
  output buffered, sent by the main thread, Ctrl-C read every 0.5 s). The
  page closing (its token released or run out) closes the session on the
  machine and writes an `exit` row ("the page was closed"); so does the
  bridge stopping; a bridge that starts clears the `remote` columns.
- **The record** (`terminal_commands`, the call log): `remote <node>`
  (effect "open"), each line (the command, read / write, the exit code, the
  start of the output), `exit` (typed, or written by the bridge), with the
  machine (`remote`), shown as "remote shell <node>" in the call log;
  lines asked about are "asked", sent after `y` "confirmed".

## How it is built

```
 page (xterm.js) --POST /terminal/commands--> Rails: Terminal::Line (table, permissions)
      ^                                         |  TerminalCommand row (pending / denied)
      |                                         v
      +-- Action Cable "console:terminal:<page>" <-- bin/bridge: Bridge::Terminal
                (output, started, done, complete)       Terminal::Line again, then
                                                        Asterism::CLI.new(net: <bridge's connection>,
                                                          stop:, permit:).run(words)
```

- **The page's token** (`terminal_sessions`): a random token per page,
  leased by its user (`POST /terminal/lease`; another user's token is
  refused). Its stream (`ConsoleChannel`, `stream: "terminal"`) is taken
  only by the user whose lease it is, so nobody else sees the output.
- **Rails** (`TerminalsController`) reads the line (`Terminal::Line`, with
  the gem's command table loaded alone: `asterism/cli/commands`, so Puma
  still never loads Zenoh) and writes the row: pending, or denied with the
  reason (the page shows it at once).
- **The bridge** (`lib/bridge/terminal.rb`) picks up pending rows on every
  tick (0.1 s), reads the line again with the call permissions of that
  moment, and runs it on a thread of its own with the gem's command line
  on the object layer's connection (the bridge's `Asterism::Connection`). The command line asks
  `permit:` once it has parsed the options its own way (an
  `Asterism::CLI::Plan`: the command, read or call, the object and the
  method), and that answer decides: the row records the plan's object and
  method. The thread never touches the database: what the command prints
  goes into a buffer (`Bridge::Terminal::Output`, a terminal of the page's
  width for the command line: `tty?`, `winsize`), and the main thread
  sends it to the page and writes the row when it ends. Ctrl-C writes
  "stopping" into the row; the bridge reads it every 0.5 s and sets the
  command's `stop:`. Whatever a command subscribed to or hooked onto the
  connection (watch, echo, hz, get) is released when it ends; the
  connection stays.
- **When the bridge stops** or loses its router, the commands are stopped
  and their rows written; a bridge that starts finishes the rows one left
  running. While no bridge runs, the page is not held by a row nobody will
  finish (Rails writes it "stopped").
- **The asterism gem** (0.13.0): the command
  line runs on a connection given to it (`CLI.new(net:, stop:, permit:)`),
  and its table loads alone. With an older gem the page says the Terminal
  needs it and the bridge says so in its log; nothing else changes.
- **Content security policy**: xterm.js puts `<style>` elements of its own
  into the page (the cells' sizes and colours) and cannot give them a
  nonce, so on this page alone styles may be inline (`style-src 'self'
  'unsafe-inline'`); scripts keep the nonce. The page is always loaded whole
  (Turbo does not swap it in), so the policy is its own.

## Checks

The remote shell (R3): `test/lib/terminal/remote_test.rb` (the words as
the machine splits them, the table, the three permissions, the system's
area, the refusals' words), `test/controllers/terminal_remote_controller_test.rb`
(remote, the lines in a machine, where the page believes it is, Tab, the
call log), `test/lib/bridge/terminal_remote_test.rb` (the bridge against a
stand-in machine, `test/test_helpers/fake_rshell.rb`: going in, more,
kill's result, Ctrl-C, Tab, exit, the page closing, one page per machine,
the permission read again, the question, the refusals, the bridge stopping
and starting), `test/lib/bridge/terminal_remote_live_test.rb` (the same
stand-in exposed by a CRuby node over a peer link, through the real object
layer), `test/lib/relay/rshell_marks_test.rb` (the mark and the lists, the
ACL's deny, the call permissions, the users' page) and
`test/lib/relay/rshell_acl_live_test.rb` (a real router with the generated
ACL: the console gets in, a member whose role calls anything does not).

The Terminal (VT1, VT2):

- `bin/rails test`: `test/lib/terminal/line_test.rb` (the kinds, the words,
  refusals: OS commands, mcp, completion, connection options, timeouts;
  calls by the permissions), `test/controllers/terminals_controller_test.rb`
  (the page and its policy, tokens per user, pending / denied rows, one at a
  time, the per-user limit, Ctrl-C, rows no bridge will finish, Tab, the
  call log), `test/channels/console_channel_test.rb` (the stream for its
  user only), `test/lib/bridge/terminal_test.rb` (the bridge with a stand-in
  command line: output to the page, the row, failures, the plan decides,
  Ctrl-C, a closed page, the limits, Tab, expiry, the bridge stopping and
  starting, the output buffer) and `test/lib/bridge/terminal_live_test.rb`
  (the real command line on a real connection to a CRuby node over a peer
  link: listing in colour, a call allowed and refused, `--cal`, Ctrl-C on
  `status echo`, Tab).
- The asterism gem's `test/test_cli.rb` `test_on_a_given_connection`.
- By hand (2026-11-08, WSL): zenohd 1.10.1 in docker, a CRuby node
  (`calcnode/calc/calc` with `add` and `sub`, a status changing every 2 s),
  `bin/rails server` and `bin/bridge`, a user who is not an admin, one call
  permission (`calcnode/calc/calc add`), and the page driven by a headless
  Chromium (Playwright): reads (`node list`, `tree --methods`, `object
  info`, `status get`) in colour; Tab (`cal` -> `calcnode/` ->
  `calcnode/calc/` -> `calcnode/calc/calc `, the methods `add  sub` listed);
  the history; `watch` and `status echo` streaming and stopped by Ctrl-C;
  `call ... add 2 3` -> `5`, `call ... sub` refused, `--cal` refused,
  `ls`, `mcp` and `--router` refused; the call log's rows; and a page
  closed while `watch` ran: stopped 0.4 s later ("the page was closed").
