import { Controller } from "@hotwired/stimulus"

// The Files page's record: while a file is on its way, asks for the rows
// once a second (the bridge writes the progress into them) and fills in
// how much the machine holds; otherwise every 5 seconds, for a file a
// machine starts sending. When one ends or a new one starts, the page is
// loaded again (the received files and the buttons change).
const ACTIVE = ["pending", "sending", "cancelling", "receiving"]

export default class extends Controller {
  static values = { active: Boolean }

  connect() {
    this.ticks = 0
    this.timer = setInterval(() => {
      this.ticks += 1
      if (this.activeValue || this.ticks % 5 === 0) this.poll()
    }, 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    let rows
    try {
      const res = await fetch("/files.json", { headers: { Accept: "application/json" } })
      if (!res.ok) return
      rows = await res.json()
    } catch (_e) { return }
    let ended = false
    let fresh = false
    for (const r of rows) {
      const el = this.element.querySelector(`[data-transfer-id="${r.id}"]`)
      if (!el) { fresh = true; continue }
      const set = (name, text) => { const f = el.querySelector(`[data-field=${name}]`); if (f) f.textContent = text }
      const was = el.querySelector("[data-field=status]")?.textContent
      set("status", r.status)
      set("reason", r.reason || "")
      if (ACTIVE.includes(r.status)) {
        const pct = r.size ? Math.floor((100 * r.done_bytes) / r.size) : 0
        set("done", `${fmtBytes(r.done_bytes)} (${pct} %) of `)
      } else {
        set("done", "")
      }
      if (ACTIVE.includes(was) && !ACTIVE.includes(r.status)) ended = true
    }
    if (ended || fresh) window.location.reload()
  }
}

function fmtBytes(n) {
  if (n == null) return "?"
  if (n >= 1e6) return `${(n / 1048576).toFixed(1)} MB`
  if (n >= 1e3) return `${(n / 1024).toFixed(1)} KB`
  return `${n} Bytes`
}
