import { Controller } from "@hotwired/stimulus"

// The recordings list and a running recording's page: while something is
// recording, asks for the progress once a second (the bridge writes it into
// the rows) and fills it in; when a recording ends, the page is loaded again
// (a finished recording's page is its timeline).
const ACTIVE = ["pending", "recording", "stopping"]

export default class extends Controller {
  static values = { active: Boolean, url: String }

  connect() {
    if (this.activeValue) this.timer = setInterval(() => this.poll(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    let rows
    try {
      const res = await fetch(this.urlValue || "/recordings.json", { headers: { Accept: "application/json" } })
      if (!res.ok) return
      rows = await res.json()
    } catch (_e) { return }
    rows = Array.isArray(rows) ? rows : [rows]
    let ended = false
    for (const r of rows) {
      const el = this.urlValue ? this.element : this.element.querySelector(`[data-recording-id="${r.id}"]`)
      if (!el) continue
      const set = (name, text) => { const f = el.querySelector(`[data-field=${name}]`); if (f) f.textContent = text }
      const was = el.querySelector("[data-field=status]")?.textContent
      set("status", r.status)
      set("reason", r.stop_reason || r.error || "")
      set("messages", r.messages)
      set("lost", r.lost)
      set("bytes", fmtBytes(r.bytes))
      set("duration", `${Number(r.duration_s).toFixed(1)} s`)
      set("channels", Object.entries(r.channel_counts || {}).map(([t, n]) => `${t}: ${n}`).join(", "))
      if (ACTIVE.includes(was) && !ACTIVE.includes(r.status)) ended = true
    }
    if (ended) window.location.reload()
  }
}

function fmtBytes(n) {
  if (n == null) return "?"
  if (n >= 1e6) return `${(n / 1048576).toFixed(1)} MB`
  if (n >= 1e3) return `${(n / 1024).toFixed(1)} KB`
  return `${n} Bytes`
}
