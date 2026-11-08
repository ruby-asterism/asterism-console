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

const LEASE_EVERY = 10000
const HISTORY_MAX = 200
const PROMPT = "\x1b[1;36masterism\x1b[0m> "
const PROMPT_WIDTH = "asterism> ".length
const WAITING_NOTE_MS = 4000

export default class extends Controller {
  static targets = ["screen", "state"]
  static values = { available: Boolean, user: String }

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
    window.removeEventListener("resize", this.onResize)
    if (this.onHide) window.removeEventListener("pagehide", this.onHide)
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
    if (d === "\t") return this.tab()
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
    out += "\r\x1b[J" + PROMPT + this.buf.join("")
    const total = PROMPT_WIDTH + width(this.buf)
    const endRow = total > 0 ? Math.floor((total - 1) / cols) : 0
    const pos = PROMPT_WIDTH + width(this.buf.slice(0, this.cur))
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
    this.term.write("\r" + PROMPT)
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
    if (this.running) {
      this.term.write("^C\r\n")
      post(`/terminal/commands/${this.running}/stop`, {})
      return
    }
    this.completing = null
    this.edit(() => { this.cur = this.buf.length })
    this.term.write("^C\r\n")
    this.hpos = this.history.length
    this.prompt()
  }

  async submit() {
    const line = this.buf.join("")
    this.edit(() => { this.cur = this.buf.length })
    this.term.write("\r\n")
    this.completing = null
    this.hpos = this.history.length
    if (!line.trim()) return this.prompt()
    this.remember(line)
    this.running = "sending"
    let res, body
    try {
      res = await post("/terminal/commands", { page: this.page, line: line, cols: this.term.cols })
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
    if (body.status === "empty") return this.prompt()
    const why = body.reason || body.error || `the console answered ${res.status}`
    this.term.write(`\x1b[31masterism: ${why}\x1b[0m\r\n`)
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

  handle(msg) {
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
        if (msg.status === "stopped") {
          this.term.write(`\x1b[2m(${msg.reason || "stopped"})\x1b[0m\r\n`)
        } else if (["denied", "expired"].includes(msg.status) && !msg.output_bytes) {
          this.term.write(`\x1b[31masterism: ${msg.reason}\x1b[0m\r\n`)
        } else if (msg.status === "failed" && msg.reason && !msg.output_bytes) {
          this.term.write(`\x1b[31masterism: ${msg.reason}\x1b[0m\r\n`)
        }
        this.prompt()
        break
      case "complete":
        this.completed(msg)
        break
    }
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
