# R4: files in the remote shell (get, put) and a long cp

Stage R4 of Family mruby's remote shell (fmruby-core `doc/remote_shell`;
the machine's side is in fmruby-core's transfer app, the same branch).
Done 2026-11-27 on the branch `remote-shell`; tested against the stand-in
machine and through to the real machine side: the Family mruby simulation
(tcp, `rshell_uncertified`) and the native build (a `tls/` router with
certificates). How to use it and who may: [terminal.md](terminal.md),
"Files: get and put".

## What was built

| Part | Where |
|---|---|
| `get` and `put` as the console's words in a machine (get: read only is enough; put: read and change; their usage; put's folder in the system's area) | `Terminal::Remote.check` (`FILE_COMMANDS`, `Line#effect`), `Terminal::Remote.escape` |
| The files on their way (a get waiting to be downloaded, a put's upload), their user, once, KEEP, the sweep | `app/models/terminal_files.rb` (`TerminalFiles`, `storage/rshell_files/{get,put}/<token>/`) |
| The upload of put, the download of get | `TerminalsController#upload` (`POST /terminal/uploads`), `#download` (`GET /terminal/files/:token`) |
| get, put, the question about a name there, the record | `Bridge::Terminal#start_get`, `#start_put`, `#ask_put`; `Bridge::RemoteShell#get`, `#put`, `#there`, `Progress` |
| A long cp's progress line and Ctrl-C (`stop`) | `Bridge::RemoteShell#run` |
| The file chooser on Enter, drag and drop, the upload's progress, the download, y/N with the same upload | `app/javascript/controllers/terminal_controller.js` |
| Tab: `get` and `put` as first words | `Bridge::RemoteShell#complete` |
| The record of what a line carried | `terminal_commands.files` (JSON), migration `20261127100000_remote_shell_files.rb` |
| The settings | `ASTERISM_RSHELL_FILE_MAX_BYTES` (16 MB), `ASTERISM_RSHELL_FILE_KEEP_SECONDS` (600), `ASTERISM_RSHELL_FILES_DIR` |

## The machine's calls used (its version 3)

```
read(id, path, pos, len)                -> {"data", "pos", "size"}   (len <= 8192; every version)
write_begin(id, path, size, overwrite)  -> {"path", "size", "pos" => 0, "piece"}
write_chunk(id, pos, data)              -> the position it holds now
write_end(id)                           -> {"path", "size"}
write_cancel(id)                        -> true
stop(id)                                -> true  (a long cp, or a wait for kill / open)
more(id, pos)                           -> ... "progress" => {"done", "total"} while a cp copies
```

## put's way

```
 page: put (Enter) -> file chooser -> POST /terminal/uploads (XHR, progress) -> {upload}
       POST /terminal/commands {line, upload}            (Rails: TerminalCommand, files {"upload"})
 bridge: the upload is the row's user's? the machine's version >= 3?
         thread: stat the folder given / each target (exec_read "stat ...")
                 a name there or the system's area, not confirmed -> "asked" (+ upload) -> the page asks y/N
                 each file: write_begin -> write_chunk ... (Ctrl-C: write_cancel) -> write_end
         main: the row (files: path, size, result), the upload deleted
```

## Checks

- `bin/rails test`: 739 runs, 0 failures (722 before). Added: the bridge's
  get / put / long cp against the stand-in (`terminal_remote_test.rb`, 10),
  Rails' upload and download (`terminal_files_controller_test.rb`, 5), the
  lines (`remote_test.rb`). The stand-in (`fake_rshell.rb`) reads and
  writes files as the machine does (version 3).
- Against the simulation (tcp), the page in a headless Chromium: text,
  kana, a PNG and 1 MB of random bytes got and put, each the same SHA-256
  at the other end; put of several files at once and by dropping them; the
  y/N for a name there (n: nothing sent; y: written over); a folder, a
  secret and put by a read-only user refused; Ctrl-C in a 6 MB put (the
  machine kept no `.part`); a 4 MB and a 64 MB cp; the progress line and
  Ctrl-C in a cp slowed down for the check (the partial copy deleted).
- Times (sim, the same PC): 1 MB get 0.43 s in the bridge (0.6 s from Enter
  to the next prompt), 1 MB put 0.64 s in the bridge (0.8 to 1.1 s with the
  upload to the console).
- Against the native build through a `tls/` router: get works (1 MB 0.44
  to 0.53 s). **put does not**: see below.

## What differed from the plan

- **put over a `tls/` router to the native build fails**: a call to the
  machine larger than about 2000 bytes (one that zenoh-pico receives in
  fragments) breaks the machine's TLS link (`TLS: the connection failed:
  -0x004e`), and the call is never answered. Calls up to 1950 bytes pass; a
  1 MB put in 1792-byte pieces takes 1.8 s there. Over tcp (the sim) 8 KB
  pieces pass. The cause is in the TLS port of zenoh-pico's gem
  (picoruby-asterism-zenoh, outside this repository); the console sends
  the piece the machine names in `write_begin`, so a smaller piece needs
  no change here. Left to the parent stage.
- The files go through the console (upload, then the machine), not the
  Files page's transfer: the remote shell's permissions alone decide.
- The question about a name there uses the machine's `stat` (an
  `exec_read`) before anything is written.

## Left for later

- put over TLS (above).
- `get` of a folder (refused now), several files in one get.
- The y/N of put answered n leaves its upload until KEEP (10 minutes).
- Progress of a long cp is seen only where the copy takes longer than the
  bridge's 0.25 s wait (the sim copies 64 MB in half a second; a board is
  slower).
