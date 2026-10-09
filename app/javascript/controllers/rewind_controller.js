import { Controller } from "@hotwired/stimulus"

// The graph rewind of a recording: a time slider over the recording, steps
// from one change of the network structure to the next, and the list of
// changes (what appeared and what went). It asks the server for the graph
// at a time (GET /recordings/:id/graph?t=, a snapshot with the diffs after
// it applied) and hands it to the console controller on the same element
// (replay mode), which shows it read-only and keeps the places of what
// stays. Times are nanoseconds from the recording's first message.
export default class extends Controller {
  static targets = ["slider", "time", "changes"]
  static values = { id: Number, changes: Array, start: String, span: Number, t: Number }

  connect() {
    this.startMs = Number(this.startValue) / 1e6
    this.inflight = false
    this.pending = null
    this.renderChanges()
    window.consoleRewind = this // for the headless checks
    // The console controller connects first (it is named first).
    setTimeout(() => this.go(this.tValue || (this.changesValue[0]?.at ?? 0)), 0)
  }

  get console() {
    return this.application.getControllerForElementAndIdentifier(this.element, "console")
  }

  times() { return this.changesValue.map((c) => c.at) }

  first() { this.go(this.times()[0] ?? 0) }

  prev() {
    const t = this.times().filter((x) => x < this.current).pop()
    if (t != null) this.go(t)
  }

  next() {
    const t = this.times().find((x) => x > this.current)
    if (t != null) this.go(t)
  }

  slide() { this.go(Number(this.sliderTarget.value), true) }
  settle() { this.go(Number(this.sliderTarget.value)) }

  // Shows the graph at t (one request at a time; the latest t wins).
  async go(t, sliding = false) {
    this.current = Math.max(0, Math.min(this.spanValue, Math.round(t)))
    this.sliderTarget.value = this.current
    this.renderTime()
    this.markChange()
    if (this.inflight) { this.pending = this.current; return }
    this.inflight = true
    try {
      const res = await fetch(`/recordings/${this.idValue}/graph?t=${this.current}`, { headers: { Accept: "application/json" } })
      const g = await res.json()
      if (g.graph) this.console?.showRecorded(g.graph, g.version)
      this.shown = g
      this.renderTime()
    } finally {
      this.inflight = false
      if (this.pending != null) { const p = this.pending; this.pending = null; this.go(p, sliding) }
    }
  }

  renderTime() {
    const at = this.shown?.at
    const changeNo = this.shown ? `change ${this.shown.index + 1} of ${this.shown.count}` : ""
    this.timeTarget.textContent = `${(this.current / 1e9).toFixed(3)} s (${clock(this.startMs + this.current / 1e6)})` +
      (at != null ? `, showing ${changeNo} at ${(at / 1e9).toFixed(3)} s` : "")
  }

  renderChanges() {
    const items = this.changesValue.map((c, i) => {
      const parts = []
      if (c.kind === "snapshot" && i === 0) parts.push(`start: ${c.nodes} nodes`)
      if (c.added?.length) parts.push(`<span class="added">+ ${esc(c.added.join(", "))}</span>`)
      if (c.removed?.length) parts.push(`<span class="removed">- ${esc(c.removed.join(", "))}</span>`)
      if (c.changed) parts.push(`${c.changed} changed`)
      if (!parts.length) parts.push(c.kind === "snapshot" ? "snapshot, no change" : "details changed")
      return `<li data-i="${i}"><a href="#" data-t="${c.at}">${(c.at / 1e9).toFixed(3)} s</a> ${parts.join(" ")}</li>`
    })
    this.changesTarget.innerHTML = items.length ? `<ol class="plain changes">${items.join("")}</ol>` : `<p class="hint">No changes recorded.</p>`
    this.changesTarget.querySelectorAll("[data-t]").forEach((a) => a.addEventListener("click", (ev) => {
      ev.preventDefault()
      this.go(Number(a.dataset.t))
    }))
  }

  markChange() {
    const ts = this.times()
    let idx = -1
    ts.forEach((x, i) => { if (x <= this.current) idx = i })
    this.changesTarget.querySelectorAll("li").forEach((li) => li.classList.toggle("current", Number(li.dataset.i) === idx))
  }
}

function clock(ms) {
  const d = new Date(ms)
  return `${d.toLocaleTimeString([], { hour12: false })}.${String(d.getMilliseconds()).padStart(3, "0")}`
}

function esc(v) {
  return String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}
