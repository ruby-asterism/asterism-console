import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// The log page (like rqt_console). The page leases "*" (POST /logs/lease,
// every LEASE_EVERY; released on pagehide); while it does, the bridge
// subscribes to /rosout of every ROS 2 domain and to the Asterism log keys
// (asterism/<node>/<app>/log) and sends the decoded lines on the "logs"
// stream. The page keeps the last MAX_LINES and filters them here: level
// (at least), node (the logger name, a part of it), text (message, file,
// function). Pause freezes the list; lines that come meanwhile are kept
// (within the same bound) and shown on resume.

const LEASE_EVERY = 10000
const MAX_LINES = 2000
const RENDER_MS = 250
// Severity by the reserved status colours, with the level's name as text
// beside it (never colour alone).
const LEVEL_CLASS = { 10: "debug", 20: "info", 30: "warn", 40: "error", 50: "fatal" }

export default class extends Controller {
  static targets = ["rows", "level", "node", "nodes", "text", "pause", "counts", "empty", "wrap"]
  static values = { node: String }

  connect() {
    this.page = randomToken()
    this.lines = []
    this.held = []
    this.paused = false
    this.names = new Set()
    this.dropped = 0
    this.seen = 0
    if (this.nodeValue) this.nodeTarget.value = this.nodeValue
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create({ channel: "ConsoleChannel", stream: "logs" }, {
      received: (msg) => this.received(msg),
    })
    this.lease()
    this.leaseTimer = setInterval(() => this.lease(), LEASE_EVERY)
    this.onHide = () => this.release()
    window.addEventListener("pagehide", this.onHide)
    this.render()
    window.consoleLogs = this
  }

  disconnect() {
    clearInterval(this.leaseTimer)
    clearTimeout(this.renderTimer)
    window.removeEventListener("pagehide", this.onHide)
    this.release()
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
  }

  received(msg) {
    if (msg.type !== "logs") return
    this.dropped = msg.dropped || 0
    const lines = msg.lines || []
    this.seen += lines.length
    for (const l of lines) {
      if (l.name && !this.names.has(l.name) && this.names.size < 500) {
        this.names.add(l.name)
        this.nodesTarget.insertAdjacentHTML("beforeend", `<option value="${esc(l.name)}">`)
      }
    }
    const into = this.paused ? this.held : this.lines
    into.push(...lines)
    if (into.length > MAX_LINES) into.splice(0, into.length - MAX_LINES)
    this.scheduleRender()
  }

  scheduleRender() {
    if (this.renderTimer) return
    this.renderTimer = setTimeout(() => { this.renderTimer = null; this.render() }, RENDER_MS)
  }

  filter() {
    this.render()
  }

  matches() {
    const min = Number(this.levelTarget.value) || 0
    const node = this.nodeTarget.value.trim().toLowerCase()
    const text = this.textTarget.value.trim().toLowerCase()
    return (l) => l.severity >= min &&
      (!node || String(l.name).toLowerCase().includes(node)) &&
      (!text || `${l.msg} ${l.file} ${l.function}`.toLowerCase().includes(text))
  }

  render() {
    const ok = this.matches()
    const shown = this.lines.filter(ok)
    // Newest first.
    let html = ""
    for (let i = shown.length - 1; i >= 0; i--) html += row(shown[i])
    this.rowsTarget.innerHTML = html
    this.emptyTarget.hidden = this.lines.length > 0
    const parts = [`${shown.length} of ${this.lines.length} lines shown (the last ${MAX_LINES} are kept)`]
    if (this.paused) parts.push(`paused, ${this.held.length} new`)
    if (this.dropped) parts.push(`${this.dropped} dropped by the bridge`)
    this.countsTarget.textContent = parts.join(", ")
  }

  togglePause() {
    this.paused = !this.paused
    this.pauseTarget.textContent = this.paused ? "Resume" : "Pause"
    if (!this.paused) {
      this.lines.push(...this.held)
      this.held = []
      if (this.lines.length > MAX_LINES) this.lines.splice(0, this.lines.length - MAX_LINES)
    }
    this.render()
  }

  clear() {
    this.lines = []
    this.held = []
    this.render()
  }

  async lease() {
    try {
      await fetch("/logs/lease", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
        body: JSON.stringify({ page: this.page, wanted: [{ target: "*" }] }),
      })
    } catch { /* the next renewal */ }
  }

  release() {
    const body = new FormData()
    body.append("page", this.page)
    body.append("authenticity_token", csrf())
    navigator.sendBeacon?.("/logs/release", body)
  }
}

function row(l) {
  const cls = LEVEL_CLASS[l.severity] || "info"
  const where = l.file ? `${l.file}${l.line ? `:${l.line}` : ""}` : ""
  return `<tr class="lv-${cls}"><td class="time">${esc(fmtTime(l.at))}</td>` +
    `<td><span class="level lv-${cls}">${esc(l.level)}</span></td>` +
    `<td class="node">${esc(l.name)}${l.source === "asterism" ? ` <span class="hint">asterism</span>` : ""}</td>` +
    `<td class="msg">${esc(l.msg)}</td><td class="where">${esc(where)}</td><td class="fn">${esc(l.function)}</td></tr>`
}

function fmtTime(ms) {
  const d = new Date(ms)
  const p = (n, w = 2) => String(n).padStart(w, "0")
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`
}

function randomToken() {
  const a = new Uint8Array(12)
  crypto.getRandomValues(a)
  return [...a].map((x) => x.toString(16).padStart(2, "0")).join("")
}

function csrf() {
  return document.querySelector("meta[name=csrf-token]")?.content || ""
}

function esc(v) {
  return String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[c])
}
