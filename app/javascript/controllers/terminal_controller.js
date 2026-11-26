import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// The Terminal (docs/terminal.md): the asterism command line's commands,
// typed here and run by the bridge on the console's connection.
//
// The page has a random token, leased while it is open (POST
// /terminal/lease every LEASE_EVERY; released on pagehide, and the bridge
// then stops what it runs for this page). Its output comes on the stream of
// that token (ConsoleChannel "terminal"), which only this user may take.
//
// The line is edited here (xterm.js only draws): left / right, Home / End
// (Ctrl-A / Ctrl-E), Backspace / Delete, Ctrl-U / Ctrl-K, up / down for the
// history (kept in this browser, per user), Tab asks the bridge for the
// candidates (the command line's __complete), Enter sends the line, Ctrl-C
// stops the command (or drops the line), Ctrl-L clears the screen. While a
// command runs only Ctrl-C is taken.
//
// The remote shell (docs/terminal.md): remote <node> goes into a machine
// (the bridge holds the session); the prompt then says where
// (<node>:<cwd>$, its width counting wide characters as two), the lines go
// to the machine, Tab asks the machine, and exit or Ctrl-D (on an empty
// line) leaves. Every line says where the page believes it is (remote), so
// a session that ended meanwhile is told back. A change of the machine's
// system area is asked about first (y/N); y sends the line again,
// confirmed.
//
// Files in a machine (docs/terminal.md, "Files: get and put"): get <file>
// ends with a "download" message, a link this browser follows once (the
// file is saved). put [<folder>] opens the file chooser (the browser lets a
// page open it only from the user's key or click, so it opens as Enter is
// pressed), and files dropped on the Terminal are put the same way (into the
// folder of a put typed on the line, else where the session is): the files
// go up to the console (POST /terminal/uploads, its progress shown), then
// the line is sent with the upload's token. A file of the same name there
// is asked about (y/N), and y sends the line again with the same upload.

const LEASE_EVERY = 10000
const HISTORY_MAX = 200
const PROMPT = "\x1b[1;36masterism\x1b[0m> "
const PROMPT_WIDTH = "asterism> ".length
const WAITING_NOTE_MS = 4000
// How long a message that came before one of its command's earlier ones
// waits for it, and how many commands' messages are kept in order at once.
const GAP_MS = 2000
const ORDERS_MAX = 64

export default class extends Controller {
  static targets = ["screen", "state"]
  static values = { available: Boolean, user: String, level: String, fileMax: Number }

  async connect() {
    this.page = randomToken()
    this.buf = []          // the line's characters
    this.cur = 0           // the cursor, an index into buf
    this.row = 0           // the row of the line the cursor was drawn on
    this.running = null    // the id of the command running
    this.completing = null // the id of the Tab asked
    this.history = loadHistory(this.historyKey())
    this.hpos = this.history.length
    this.saved = null      // the line being typed, while the history is shown
    this.remote = null     // {node, cwd}: the machine the page is in
    this.confirming = null // the line asked about (y/N), while asked
    this.orders = new Map() // id => {next, held, timer}: the bridge's messages put in order

    const [{ Terminal }, { FitAddon }] = await Promise.all([import("@xterm/xterm"), import("@xterm/addon-fit")])
    if (!this.element.isConnected) return
    this.term = new Terminal({
      convertEol: true, cursorBlink: true, fontSize: 14, scrollback: 5000,
      fontFamily: 'ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
      theme: { background: "#14171a" },
    })
    this.fit = new FitAddon()
    this.term.loadAddon(this.fit)
    this.term.open(this.screenTarget)
    this.fitNow()
    this.onResize = () => this.fitNow()
    window.addEventListener("resize", this.onResize)
    this.term.onData((d) => this.input(d))
    window.consoleTerminal = this
    this.setupFiles()

    if (!this.availableValue) {
      this.term.write("\x1b[31mThe Terminal needs the asterism gem 0.13.0 or newer (its command line on the " +
        "bridge's connection).\x1b[0m\r\n")
      this.state("not available")
      return
    }
    const ok = await this.lease()
    if (!ok) {
      this.term.write("\x1b[31mThis page could not open a Terminal (reload it).\x1b[0m\r\n")
      return
    }
    this.leaseTimer = setInterval(() => this.lease(), LEASE_EVERY)
    this.onHide = () => this.release()
    window.addEventListener("pagehide", this.onHide)
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create({ channel: "ConsoleChannel", stream: "terminal", page: this.page }, {
      connected: () => this.state("connected"),
      disconnected: () => this.state("connection lost; trying again"),
      rejected: () => this.state("refused (reload the page)"),
      received: (msg) => this.received(msg),
    })
    this.term.write("\x1b[2mThe asterism command line on the console's connection. help: the commands.\x1b[0m\r\n")
    this.prompt()
    this.term.focus()
  }

  disconnect() {
    clearInterval(this.leaseTimer)
    clearTimeout(this.waitTimer)
    for (const id of [...this.orders.keys()]) this.dropOrder(id)
    window.removeEventListener("resize", this.onResize)
    if (this.onHide) window.removeEventListener("pagehide", this.onHide)
    this.xhr?.abort()
    this.release()
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.term?.dispose()
  }

  // ------------------------------------------------------------------ input

  input(d) {
    if (d === "\x03") return this.interrupt()
    if (this.running) return
    if (d === "\r") return this.submit()
    if (d === "\x7f" || d === "\b") return this.edit(() => { if (this.cur > 0) this.buf.splice(--this.cur, 1) })
    if (d === "\x1b[3~") return this.edit(() => { this.buf.splice(this.cur, 1) })
    if (d === "\x1b[D") return this.edit(() => { if (this.cur > 0) this.cur-- })
    if (d === "\x1b[C") return this.edit(() => { if (this.cur < this.buf.length) this.cur++ })
    if (d === "\x1b[H" || d === "\x1bOH" || d === "\x01") return this.edit(() => { this.cur = 0 })
    if (d === "\x1b[F" || d === "\x1bOF" || d === "\x05") return this.edit(() => { this.cur = this.buf.length })
    if (d === "\x15") return this.edit(() => { this.buf.splice(0, this.cur); this.cur = 0 })
    if (d === "\x0b") return this.edit(() => { this.buf.splice(this.cur) })
    if (d === "\x1b[A") return this.recall(-1)
    if (d === "\x1b[B") return this.recall(1)
    if (d === "\t") return this.confirming ? undefined : this.tab()
    if (d === "\x04") {
      // Ctrl-D on an empty line leaves the machine
      if (this.remote && !this.confirming && this.buf.length === 0) {
        this.edit(() => { this.buf = [..."exit"]; this.cur = 4 })
        return this.submit()
      }
      return
    }
    if (d === "\x0c") {
      this.term.clear()
      return this.edit(() => {})
    }
    if (d.startsWith("\x1b")) return
    // Typed or pasted text: a line break sends what came before it.
    const parts = d.split(/\r\n|\r|\n/)
    const text = [...parts[0]].filter((c) => c >= " ")
    this.edit(() => {
      this.buf.splice(this.cur, 0, ...text)
      this.cur += text.length
    })
    if (parts.length > 1) this.submit()
  }

  edit(change) {
    change()
    this.draw()
  }

  // Redraws the line (it may wrap) and puts the cursor where it is.
  draw() {
    const cols = this.term.cols
    let out = ""
    if (this.row > 0) out += `\x1b[${this.row}A`
    out += "\r\x1b[J" + this.promptText() + this.buf.join("")
    const pw = this.promptWidth()
    const total = pw + width(this.buf)
    const endRow = total > 0 ? Math.floor((total - 1) / cols) : 0
    const pos = pw + width(this.buf.slice(0, this.cur))
    const row = Math.floor(pos / cols)
    const col = pos % cols
    if (row > endRow) out += "\r\n"
    else if (endRow > row) out += `\x1b[${endRow - row}A`
    out += "\r" + (col > 0 ? `\x1b[${col}C` : "")
    this.row = row
    this.term.write(out)
  }

  prompt() {
    this.buf = []
    this.cur = 0
    this.row = 0
    this.term.write("\r" + this.promptText())
  }

  // The asterism command line's prompt, the machine's (<node>:<cwd>$), or
  // the question about a change of the system's area.
  promptText() {
    if (this.confirming) return `\x1b[33m${this.confirming.question}\x1b[0m`
    if (this.remote) return `\x1b[1;32m${this.remote.node}\x1b[0m:\x1b[1;34m${this.remote.cwd || ""}\x1b[0m$ `
    return PROMPT
  }

  promptWidth() {
    if (this.confirming) return width([...this.confirming.question])
    if (this.remote) return width([...`${this.remote.node}:${this.remote.cwd || ""}$ `])
    return PROMPT_WIDTH
  }

  // Where the console says the page is ({node, cwd} or null), when it says.
  place(msg) {
    if (msg && Object.prototype.hasOwnProperty.call(msg, "remote")) {
      this.remote = msg.remote && msg.remote.node ? msg.remote : null
    }
  }

  recall(step) {
    if (this.history.length === 0) return
    const next = Math.min(Math.max(this.hpos + step, 0), this.history.length)
    if (next === this.hpos) return
    if (this.hpos === this.history.length) this.saved = this.buf.join("")
    this.hpos = next
    const text = next === this.history.length ? (this.saved || "") : this.history[next]
    this.edit(() => {
      this.buf = [...text]
      this.cur = this.buf.length
    })
  }

  interrupt() {
    if (this.running === "choosing") return this.chosen([])
    if (this.running === "uploading") {
      this.xhr?.abort()
      return
    }
    if (this.running) {
      this.term.write("^C\r\n")
      post(`/terminal/commands/${this.running}/stop`, {})
      return
    }
    this.completing = null
    this.edit(() => { this.cur = this.buf.length })
    this.term.write("^C\r\n")
    this.hpos = this.history.length
    this.confirming = null
    this.prompt()
  }

  async submit() {
    let line = this.buf.join("")
    this.edit(() => { this.cur = this.buf.length })
    this.term.write("\r\n")
    this.completing = null
    this.hpos = this.history.length
    let confirmed = false
    let upload = ""
    if (this.confirming) {
      const asked = this.confirming.line
      upload = this.confirming.upload || ""
      this.confirming = null
      if (!/^\s*y(es)?\s*$/i.test(line)) {
        this.term.write("\x1b[2m(not sent)\x1b[0m\r\n")
        return this.prompt()
      }
      line = asked
      confirmed = true
    } else {
      if (!line.trim()) return this.prompt()
      this.remember(line)
      // put: the file chooser, now (while the key press lets it open)
      if (this.remote && firstWord(line) === "put" && this.levelValue === "write") return this.choose(line)
    }
    return this.send(line, { confirmed, upload })
  }

  // Sends a line (the page's answer and the bridge's messages follow).
  async send(line, { confirmed = false, upload = "" } = {}) {
    this.running = "sending"
    let res, body
    try {
      res = await post("/terminal/commands", { page: this.page, line: line, cols: this.term.cols,
                                               remote: this.remote?.node || "", confirmed: confirmed, upload: upload })
      body = await res.json().catch(() => ({}))
    } catch {
      this.running = null
      this.early = []
      this.term.write("\x1b[31mterminal: the console did not answer\x1b[0m\r\n")
      return this.prompt()
    }
    if (res.status === 201) {
      this.started = false
      this.running = body.id
      this.replayEarly()
      if (this.running !== body.id) return
      this.waitTimer = setTimeout(() => {
        if (this.running === body.id && !this.started) this.state("waiting for the bridge to pick it up")
      }, WAITING_NOTE_MS)
      return
    }
    this.running = null
    this.replayEarly()
    this.place(body)
    if (body.status === "empty") return this.prompt()
    const why = body.reason || body.error || `the console answered ${res.status}`
    this.term.write(`\x1b[31m${said(this.who(body), why)}\x1b[0m\r\n`)
    this.prompt()
  }

  remember(line) {
    if (this.history[this.history.length - 1] !== line) this.history.push(line)
    if (this.history.length > HISTORY_MAX) this.history.splice(0, this.history.length - HISTORY_MAX)
    this.hpos = this.history.length
    saveHistory(this.historyKey(), this.history)
  }

  async tab() {
    const before = this.buf.slice(0, this.cur).join("")
    this.completing = "asking"
    this.tabLine = before
    try {
      const res = await post("/terminal/complete", { page: this.page, line: before, cols: this.term.cols })
      const body = await res.json().catch(() => ({}))
      if (this.completing !== "asking" || this.tabLine !== this.buf.slice(0, this.cur).join("")) return
      this.completing = res.status === 201 ? body.id : null
      this.replayEarly()
    } catch {
      this.completing = null
    }
  }

  // The candidates for the word before the cursor: one is put in (with a
  // space after it unless it ends a part with "/"), several extend the word
  // as far as they agree, or are listed.
  completed(msg) {
    if (msg.id !== this.completing) return
    this.completing = null
    if (this.tabLine !== this.buf.slice(0, this.cur).join("")) return
    if (msg.remote) return this.completedRemote(msg)
    const word = msg.word || ""
    const cands = (msg.candidates || []).filter((c) => c.startsWith(word) && !c.startsWith(":"))
    if (cands.length === 0) return this.term.write("\x07")
    let add
    if (cands.length === 1) {
      add = cands[0].slice(word.length) + (cands[0].endsWith("/") ? "" : " ")
    } else {
      add = commonPrefix(cands).slice(word.length)
      if (!add) {
        this.edit(() => { this.cur = this.buf.length })
        this.term.write("\r\n" + columns(cands, this.term.cols) + "\r\n")
        const keep = this.buf
        const at = this.cur
        this.prompt()
        this.edit(() => { this.buf = keep; this.cur = at })
        return
      }
    }
    this.edit(() => {
      const chars = [...add]
      this.buf.splice(this.cur, 0, ...chars)
      this.cur += chars.length
    })
  }

  // The machine's candidates (the remote shell): each is the whole word
  // from start (characters) as it is typed (a blank as "\ "), so the word
  // typed is replaced rather than extended: one is put in (with a space
  // after it unless it is a folder, "/"), several put in as much as they
  // agree on when that is more than what was typed, or are listed.
  completedRemote(msg) {
    const before = this.buf.slice(0, this.cur)
    const start = Math.max(0, Math.min(Number.isInteger(msg.start) ? msg.start : before.length, before.length))
    const typed = before.slice(start).join("")
    const items = (msg.candidates || []).filter((c) => typeof c === "string")
    if (items.length === 0) return this.term.write("\x07")
    let put
    if (items.length === 1) {
      put = items[0] + (items[0].endsWith("/") ? "" : " ")
    } else {
      const common = commonPrefix(items)
      if ([...unescapeWord(common)].length > [...unescapeWord(typed)].length) {
        put = common
      } else {
        const dir = common.lastIndexOf("/") + 1
        this.edit(() => { this.cur = this.buf.length })
        this.term.write("\r\n" + columns(items.map((i) => i.slice(dir)), this.term.cols) + "\r\n")
        const keep = this.buf
        const at = this.cur
        this.prompt()
        this.edit(() => { this.buf = keep; this.cur = at })
        return
      }
    }
    this.edit(() => {
      const chars = [...put]
      this.buf.splice(start, this.cur - start, ...chars)
      this.cur = start + chars.length
    })
  }

  // ----------------------------------------------------------- the stream

  received(msg) {
    // What comes before the answer to the request that started it (the
    // bridge may be quicker than the console's answer) waits for the id.
    if (this.running === "sending" || this.completing === "asking") {
      (this.early ||= []).push(msg)
      if (this.early.length > 2000) this.early.shift()
      return
    }
    this.handle(msg)
  }

  replayEarly() {
    const list = this.early || []
    this.early = []
    for (const m of list) this.handle(m)
  }

  // The bridge numbers the messages about one command (seq: 1, 2, ...,
  // the last "done" or "complete"), and Action Cable may deliver two that
  // came close together in either order (lib/bridge/terminal.rb,
  // send_page). They are handled in their order: one that comes early is
  // kept until those before it are in; a gap not filled within GAP_MS is
  // passed over (what is kept is handled in its order). A message without
  // seq (an older bridge) is handled as it comes.
  handle(msg) {
    if (msg.id == null || !Number.isInteger(msg.seq)) return this.apply(msg)
    let q = this.orders.get(msg.id)
    if (!q) {
      q = { next: 1, held: new Map(), timer: null }
      this.orders.set(msg.id, q)
      if (this.orders.size > ORDERS_MAX) this.dropOrder(this.orders.keys().next().value)
    }
    if (msg.seq < q.next) return this.apply(msg) // after a gap passed over
    q.held.set(msg.seq, msg)
    this.drain(msg.id, q)
  }

  drain(id, q) {
    let last = false
    while (q.held.has(q.next)) {
      const m = q.held.get(q.next)
      q.held.delete(q.next)
      q.next++
      last = m.type === "done" || m.type === "complete"
      this.apply(m)
    }
    clearTimeout(q.timer)
    q.timer = null
    if (q.held.size > 0) {
      q.timer = setTimeout(() => {
        q.next = Math.min(...q.held.keys())
        this.drain(id, q)
      }, GAP_MS)
    } else if (last) {
      this.orders.delete(id)
    }
  }

  dropOrder(id) {
    const q = this.orders.get(id)
    if (q) clearTimeout(q.timer)
    this.orders.delete(id)
  }

  apply(msg) {
    switch (msg.type) {
      case "output":
        if (msg.id === this.running) this.term.write(msg.data)
        break
      case "started":
        if (msg.id === this.running) {
          this.started = true
          this.state("connected")
        }
        break
      case "done":
        if (msg.id !== this.running) break
        clearTimeout(this.waitTimer)
        this.running = null
        this.state("connected")
        // A line the output left open is ended before what follows.
        if (this.term.buffer.active.cursorX > 0) this.term.write("\r\n")
        const who = this.who(msg)
        if (msg.status === "stopped") {
          this.term.write(`\x1b[2m(${msg.reason || "stopped"})\x1b[0m\r\n`)
        } else if (["denied", "expired"].includes(msg.status) && !msg.output_bytes) {
          this.term.write(`\x1b[31m${said(who, msg.reason)}\x1b[0m\r\n`)
        } else if (msg.status === "failed" && msg.reason && !msg.output_bytes) {
          this.term.write(`\x1b[31m${said(who, msg.reason)}\x1b[0m\r\n`)
        }
        this.place(msg)
        if (msg.status === "asked" && msg.confirm) {
          this.confirming = { line: msg.line, question: msg.confirm, upload: msg.upload || "" }
        }
        this.prompt()
        break
      case "download":
        if (msg.id === this.running) this.download(msg)
        break
      case "complete":
        this.completed(msg)
        break
    }
  }

  // Who a refusal is from: the machine's name in a machine, the command
  // line's otherwise.
  who(msg) {
    if (msg.remote_node) return msg.remote_node
    if (msg.command === "remote") return "remote"
    return this.remote?.node || "asterism"
  }

  // ------------------------------------------------------- get and put

  setupFiles() {
    this.fileInput = document.createElement("input")
    this.fileInput.type = "file"
    this.fileInput.multiple = true
    this.fileInput.hidden = true
    this.element.appendChild(this.fileInput)
    this.fileInput.addEventListener("change", () => this.chosen([...this.fileInput.files]))
    this.fileInput.addEventListener("cancel", () => this.chosen([]))
    this.onDragOver = (ev) => {
      if (!ev.dataTransfer?.types?.includes("Files")) return
      ev.preventDefault()
      ev.dataTransfer.dropEffect = "copy"
    }
    this.onDrop = (ev) => {
      if (!ev.dataTransfer?.files?.length) return
      ev.preventDefault()
      this.dropped([...ev.dataTransfer.files])
    }
    this.screenTarget.addEventListener("dragover", this.onDragOver)
    this.screenTarget.addEventListener("drop", this.onDrop)
  }

  // put typed: the chooser opens; chosen() goes on.
  choose(line) {
    this.running = "choosing"
    this.putLine = line
    this.fileInput.value = ""
    this.term.write("\x1b[2m(choose the files to put; Ctrl-C: none)\x1b[0m\r\n")
    this.fileInput.click()
  }

  chosen(files) {
    if (this.running !== "choosing") return
    this.running = null
    if (files.length === 0) {
      this.term.write("\x1b[2m(no file chosen)\x1b[0m\r\n")
      return this.prompt()
    }
    this.upload(this.putLine, files)
  }

  // Files dropped on the Terminal: put, into the folder of a put on the
  // line (else where the session is).
  dropped(files) {
    if (this.running || this.confirming) return this.term.write("\x07")
    const typed = this.buf.join("")
    if (!this.remote) {
      this.term.write("\r\n\x1b[33mfiles go into a machine: remote <node> first, then drop them (or put)\x1b[0m\r\n")
      this.prompt()
      return this.edit(() => { this.buf = [...typed]; this.cur = this.buf.length })
    }
    const line = firstWord(typed) === "put" ? typed : "put"
    this.edit(() => { this.buf = [...line]; this.cur = this.buf.length })
    this.term.write("\r\n")
    this.remember(line)
    if (this.levelValue !== "write") return this.send(line)
    this.upload(line, files)
  }

  // The files up to the console, then the line with their token.
  upload(line, files) {
    const big = files.find((f) => f.size > this.fileMaxValue)
    if (big) {
      this.term.write(`\x1b[31mput: ${big.name}: over ${Math.floor(this.fileMaxValue / 1048576)} MB (the console's limit)\x1b[0m\r\n`)
      return this.prompt()
    }
    const total = files.reduce((n, f) => n + f.size, 0)
    const form = new FormData()
    form.append("page", this.page)
    for (const f of files) form.append("files[]", f, f.name)
    this.running = "uploading"
    const xhr = this.xhr = new XMLHttpRequest()
    xhr.open("POST", "/terminal/uploads")
    xhr.setRequestHeader("X-CSRF-Token", csrf())
    xhr.setRequestHeader("Accept", "application/json")
    xhr.upload.onprogress = (ev) => {
      this.term.write(`\r\x1b[Kup to the console: ${kb(ev.loaded)} / ${kb(ev.lengthComputable ? ev.total : total)}`)
    }
    const end = (text) => {
      this.xhr = null
      this.running = null
      this.term.write("\r\x1b[K")
      if (text) this.term.write(text + "\r\n")
    }
    xhr.onload = () => {
      let body = {}
      try { body = JSON.parse(xhr.responseText) } catch { /* not JSON */ }
      if (xhr.status === 201 && body.upload) {
        end(`\x1b[2m${files.length} file${files.length === 1 ? "" : "s"} (${kb(total)}) at the console; to ${this.remote?.node}\x1b[0m`)
        return this.send(line, { upload: body.upload })
      }
      end(`\x1b[31m${this.who({})}: ${body.error || `the console answered ${xhr.status}`}\x1b[0m`)
      this.prompt()
    }
    xhr.onerror = () => { end("\x1b[31mput: the upload to the console failed\x1b[0m"); this.prompt() }
    xhr.onabort = () => { end("\x1b[2m(stopped before the files reached the console)\x1b[0m"); this.prompt() }
    xhr.send(form)
  }

  // get's file: the browser saves it (the link works once).
  download(msg) {
    const a = document.createElement("a")
    a.href = msg.url
    a.download = msg.name || ""
    a.hidden = true
    document.body.appendChild(a)
    a.click()
    a.remove()
  }

  // --------------------------------------------------------------- the page

  fitNow() {
    try { this.fit.fit() } catch { /* not laid out yet */ }
  }

  state(text) {
    if (this.hasStateTarget) this.stateTarget.textContent = text
  }

  historyKey() {
    return `asterism-terminal-history-${this.userValue}`
  }

  async lease() {
    try {
      const res = await post("/terminal/lease", { page: this.page })
      return res.ok
    } catch {
      return false
    }
  }

  release() {
    if (!this.page) return
    const body = new FormData()
    body.append("page", this.page)
    body.append("authenticity_token", csrf())
    navigator.sendBeacon?.("/terminal/release", body)
  }
}

// The columns a character takes (East Asian wide ones two).
function width(chars) {
  let n = 0
  for (const c of chars) n += /[ᄀ-ᅟ⺀-〾ぁ-㏿㐀-䶿一-鿿ꀀ-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(c) ? 2 : 1
  return n
}

// A word as the machine reads it: "..." and backslashes taken away.
function unescapeWord(s) {
  let out = ""
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (c === "\\" && i + 1 < s.length) { out += s[++i]; continue }
    if (c === '"') continue
    out += c
  }
  return out
}

// A refusal with who it is from, unless it says so itself.
function said(who, why) {
  return String(why).startsWith(`${who}: `) ? why : `${who}: ${why}`
}

// The first word of a line (blanks part words).
function firstWord(line) {
  return line.trim().split(/[ \t]+/)[0] || ""
}

function kb(n) {
  if (n < 1024) return `${n} bytes`
  return n >= 10485760 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.round(n / 1024)} KB`
}

function commonPrefix(list) {
  let p = list[0]
  for (const s of list) while (!s.startsWith(p)) p = p.slice(0, -1)
  return p
}

function columns(list, cols) {
  const w = Math.max(...list.map((s) => s.length)) + 2
  const per = Math.max(1, Math.floor(cols / w))
  const rows = []
  for (let i = 0; i < list.length; i += per) rows.push(list.slice(i, i + per).map((s) => s.padEnd(w)).join("").trimEnd())
  return rows.join("\r\n")
}

function loadHistory(key) {
  try {
    const v = JSON.parse(localStorage.getItem(key) || "[]")
    return Array.isArray(v) ? v.filter((x) => typeof x === "string").slice(-HISTORY_MAX) : []
  } catch {
    return []
  }
}

function saveHistory(key, list) {
  try { localStorage.setItem(key, JSON.stringify(list)) } catch { /* private window */ }
}

function post(url, data) {
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
    body: JSON.stringify(data),
  })
}

function randomToken() {
  const a = new Uint8Array(12)
  crypto.getRandomValues(a)
  return [...a].map((x) => x.toString(16).padStart(2, "0")).join("")
}

function csrf() {
  return document.querySelector("meta[name=csrf-token]")?.content || ""
}
