# The Terminal: the asterism command line in the console (VT1, VT2)

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
