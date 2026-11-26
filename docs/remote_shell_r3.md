# R3: the Terminal's remote shell into a Family mruby machine

Stage R3 of Family mruby's remote shell (fmruby-core `doc/remote_shell`;
the machine's side is R1 and R2 there). Done 2026-11-26 on the branch
`remote-shell`; tested against a stand-in machine (a CRuby node exposing
the answers of the machine's report r1), a local router with the
generated ACL, and the page in a headless Chromium. Not yet against the
Family mruby simulation or a board (the parent stage does that). How to use
it and who may: [terminal.md](terminal.md), "The remote shell".

## What was built

| Part | Where |
|---|---|
| `remote`, `remote <node>`, the lines in a machine, `exit`, Tab: Rails' check | `TerminalsController` (`run`, `complete`), `lib/terminal/remote.rb` (`Terminal::Remote`: the words as the machine splits them, its table, the three permissions, the system's area, the refusals in the user's words) |
| The session per page, the calls, more, kill's wait, the page closing | `lib/bridge/terminal.rb` (`start_remote`, `finish_remote`, `leave`), `lib/bridge/remote_shell.rb` (`Bridge::RemoteShell`) |
| The prompt `<node>:<cwd>$` (wide characters count two), Ctrl-D, the y/N question, Tab with whole-word candidates | `app/javascript/controllers/terminal_controller.js` |
| The users' permission (none / read / write; none by default, admins too) | `users.rshell_access`, Admin > Users (`Admin::UsersController#rshell`) |
| The mark "Remote shell from the console" (members' rows, users' browsers), sent as the kind `rshell` | `rshell_from_console` (relay_peers, users), `ReceiverLists#receivers_payload` |
| No other subject calls a remote shell | `Relay::CloudConfig#no_rshell` (the shared deny `no_rshell_calls`) |
| No call permission covers `<node>/transfer/rshell` | `CallPermission.reserved?` (the page's calls, the Terminal's `call`, the bridge's second check) |
| The record | `terminal_commands.remote`, `.confirmed`, the status `asked`; the call log shows "remote shell <node>" |
| The migration | `db/migrate/20261126100000_remote_shell.rb` (columns only) |

## A line's way

```
 page  -- POST /terminal/commands {line, remote: <node the page believes>, confirmed} -->
 Rails: TerminalSession.remote (the bridge's copy: node, the machine's table, cwd)
        Terminal::Remote.check(line, table, user.rshell_access) -> TerminalCommand (pending / denied)
 bridge: @remotes[page] (the session: the machine's id stays here)
        Terminal::Remote.check again (the permission now, the paths from cwd)
        a change outside /home /app /mnt/sd /tmp, not confirmed -> "asked" (the page asks y/N)
        thread: <node>/transfer/rshell exec_read | exec_write (id, line)
                then more(id, pos) while "more" (every 0.25 s while "wait"), Ctrl-C between
        main thread: the output to the page, the row, TerminalSession.remote (cwd), "done" with {node, cwd}
```

`remote <node>`: the bridge refuses a second page for the same machine,
checks that the node and its transfer app are there, calls `open`, keeps the
session and writes the node, the table and `cwd` into the page's
`TerminalSession.remote` (one JSON column). `exit` calls `close`. The page
closing (token released or run out), the bridge stopping: `close` on a
thread of its own and an `exit` row ("the page was closed", "the bridge
stopped"). A bridge that starts clears the columns; the page's next line
is then refused with where it is ("the remote shell on <node> has ended")
and the prompt goes back.

## Where the permissions are checked

| Check | Rails (the line typed) | The bridge (before it sends) | The machine |
|---|---|---|---|
| The user may use the remote shell at all | yes | yes | - |
| Read only: no write command | yes (the machine's table) | yes (the permission of that moment) | `exec_read` refuses a write command (126) |
| A word the machine did not name; `get` / `put` | yes | yes | 127 |
| One page per machine | - | yes | one session per caller |
| The system's area (y/N) | - | yes (paths folded from `cwd`) | - |
| The console may come in | - | - | `rshell` lists in `receive.toml`, a checked connection |
| Only the console calls `transfer/rshell` | `CallPermission` never covers it | the bridge's second check of calls too | - |
| ... on the router | - | - | `no_rshell_calls` for every other subject that could query it |

## The lists and the ACL

- The lists the bridge sends (`policy_set`) always carry `"rshell"`: the
  console's node when the row (or the user's browser) is marked, `[]`
  otherwise. Ticking or clearing the mark counts as a change of the lists
  (`receivers_changed_at`), so the row becomes managed and the list goes
  out at once. `rshell` is not a sender's list for the inbox:
  `receives_config` (the ACL's `transfer/inbox/call/<sender>` lines) leaves
  it out.
- **No allow line was needed**: the machine's queryable and replies on
  `asterism/<node>/transfer/rshell/**` are inside the rw transfer keys a
  managed row gets, and the console's certificate has `asterism/**` (its
  setup). Checked through a real router (`rshell_acl_live_test.rb`).
- **A deny was**: a member whose role asks `asterism/*/*/*/call/${node}`
  (or with rw / ro `asterism/**`) could call any machine's remote shell
  under its own name, and a machine that names it by hand would let it in.
  Every subject other than the console whose allows meet
  `asterism/*/transfer/rshell[/**]` for queries from it gets the shared
  deny `no_rshell_calls` (key expressions compared chunk by chunk,
  `CloudConfig.keys_meet?`); a browser with a certificate in both its
  subjects; the shared `ws/` subject is refused every transfer key already.
  Subjects whose rules never reach it (a role that calls only
  `asterism/*/calc/*/call/${node}`, the seats) are unchanged. The live test
  shows the member reaching the machine's inbox but not its remote shell,
  and reaching it when the deny is taken out.

## Checks

- `bin/rails test`: 721 runs, 0 failures (681 before; the existing tests
  changed only where the lists now carry `rshell` and where a subject now
  has `no_rshell_calls`: `relay_peer_receivers_test`, `receivers_test`,
  `cloud_config_test`, `room_seats_acl_test`).
- Added: `test/lib/terminal/remote_test.rb` (8),
  `test/controllers/terminal_remote_controller_test.rb` (6),
  `test/lib/bridge/terminal_remote_test.rb` (16, against
  `test/test_helpers/fake_rshell.rb`), `test/lib/bridge/terminal_remote_live_test.rb`
  (2, the stand-in exposed by a CRuby node in another process, through the
  real object layer), `test/lib/relay/rshell_marks_test.rb` (6),
  `test/lib/relay/rshell_acl_live_test.rb` (2, a real router with the
  generated ACL and mutual TLS).
- By hand (2026-11-26, WSL): a CRuby router on a free local port, the
  stand-in machine on it, `bin/rails server` on another free port and
  `bin/bridge`, the page in a headless Chromium (`script/headless/run`):
  a user with "read only" listed the machines, went in, `ls`, Tab on
  `cat my` (put in `my\ file.txt`) and on `c` (listed), was refused
  `rm` with the reason, `exit`; a user with "read and change" was asked
  about `rm ../etc/system_conf.toml` (n: not sent; y: sent), `kill 7`
  (asked, then the result through more), Ctrl-D left; the call log showed
  the rows with their machine; a page closed without `exit` was left by
  the bridge 30 s later with an `exit` row. Everything was stopped
  afterwards and the development database put back as it was (after the
  migration).

## What differed from the plan

- **One session per caller on the machine, one caller for the whole
  console**: a second page (or another user) opening the same machine
  would silently replace the first page's session on the machine (it sees
  the same caller, `console`). The console keeps one page per machine
  itself ("another user of the console is in ...").
- **The table in Rails**: to refuse a write command to a "read only" user
  when the line is typed, Rails needs the machine's table, so the page's
  `TerminalSession.remote` holds the node, the table and `cwd` (one column,
  JSON). The session number stays in the bridge.
- **ACL**: no allow line, one shared deny (above). The deny also keeps out
  nodes a machine's owner lets in by hand (`[rshell] from` in its
  `receive.toml`) when they come through this console's router: on the
  cloud router, only the console reaches a remote shell.
- **A machine whose transfer app is not running** (every switch off) has
  no queryable at all: a call would wait for its time-out. The bridge
  looks first (`<node>/transfer/*` on the network) and says the remote shell
  is off; a machine that is not there at all is said to be so.
- **The answers of `more`** carry `wait` and `code` (R2's brief): the
  bridge asks again every 0.25 s while `wait`, and takes `code` when it
  comes.
- The development database of the working copy has the new columns (the
  migration was run there); `git checkout main` leaves them in place
  (harmless; `db:rollback` on this branch takes them away).

## Left for later

- **R4**: `get` and `put` (refused now as "not in this version of the
  console"); the machine's `read` is already in the table of methods.
- **The machine's side (fmruby-core), wished for**:
  - The console reads the refusals by their words (`lets no remote shell
    in (rshell_enabled is off`, `only over a checked connection`, `lets no
    remote shell in from`, `has a remote shell open from`, `no remote shell
    session`): keep them as they are, or tell the console when they
    change (`Terminal::Remote.explain`; an unknown text is shown as it
    is).
  - `complete`'s `word` in characters and items as whole typed words (with
    `\ `), as in report r1: the page replaces the word with them.
  - `policy_set` now always brings `"rshell"`; a machine of R1 or later
    keeps it in `[managed.rshell]`. Older machines ignore the key.
  - The sim and a board through this console (the parent's R5): the
    commands' real output, `kill` / `open` against the kernel, the
    certificate's check (`rshell_uncertified` for the sim).
- Whether a user's browser (wasm) should be offered as a machine in the
  list differently (the plan's open point 1): it is listed like any other
  node whose remote shell is on.
- The question about the system's area is in English, like the rest of
  the Terminal.
