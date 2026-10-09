import { Controller } from "@hotwired/stimulus"
import uPlot from "uplot"

// A recording's timeline (like rqt_bag): one row per channel with its
// message ticks, a time cursor (click or drag on the rows, or on the plot),
// the selected channel's message at the cursor (decoded by the server with
// V3's decoders), every channel's message at the cursor, a plot of numeric
// fields over the whole recording, and playback: in the page only (the
// cursor moves at 0.25x / 1x / 4x and the messages follow), or, for an
// admin and after a confirmation, to the network (the bridge republishes;
// the page follows along).
//
// Times are nanoseconds from the first message (offsets): the server
// takes and gives them so (RecordingsController).

const ROW_H = 24
const LABEL_W = 240
const AXIS_H = 26
const KIND_COLORS = { ros: "#6a1b9a", key: "#2e7d32", graph: "#1f4e99", other: "#8a8f98" }
const KIND_NAMES = { ros: "ROS 2", key: "Asterism", graph: "network", other: "" }
const COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]

export default class extends Controller {
  static targets = ["canvas", "wrap", "time", "message", "fields", "atList", "plot", "chips", "plotHint",
                    "playButton", "speed", "mode", "playStatus", "rewindLink"]
  static values = { id: Number, info: Object, canPlay: Boolean }

  connect() {
    this.channels = this.infoValue.channels || []
    this.startMs = Number(this.infoValue.start) / 1e6 // wall clock of offset 0 (ms precision is enough to show it)
    this.span = Number(this.infoValue.duration_ns || 0)
    this.cursor = 0
    this.selected = this.channels.find((c) => c.kind !== "graph")?.id ?? null
    this.ticks = null
    this.series = []     // { channel, path, color, t: [s], v: [] }
    this.playing = false
    this.network = null  // the playback to the network, while it runs
    this.inflight = false
    this.again = false
    this.onResize = () => { this.draw(); this.sizePlot() }
    window.addEventListener("resize", this.onResize)
    this.setupCanvas()
    this.loadTicks()
    this.refresh()
    this.loadFields()
    window.consoleTimeline = this // for the headless checks
  }

  disconnect() {
    window.removeEventListener("resize", this.onResize)
    cancelAnimationFrame(this.frame)
    clearInterval(this.netTimer)
    this.chart?.destroy()
  }

  url(action, params = {}) {
    const q = new URLSearchParams(params)
    return `/recordings/${this.idValue}/${action}?${q}`
  }

  async getJSON(action, params) {
    const res = await fetch(this.url(action, params), { headers: { Accept: "application/json" } })
    const body = await res.json().catch(() => ({ error: `HTTP ${res.status}` }))
    if (!res.ok && !body.error) body.error = `HTTP ${res.status}`
    return body
  }

  // ---------------------------------------------------------------- canvas

  setupCanvas() {
    const c = this.canvasTarget
    let dragging = false
    const at = (ev) => {
      const r = c.getBoundingClientRect()
      return { x: ev.clientX - r.left, y: ev.clientY - r.top }
    }
    c.addEventListener("pointerdown", (ev) => {
      const p = at(ev)
      const row = Math.floor((p.y - AXIS_H) / ROW_H)
      if (p.y >= AXIS_H && this.channels[row]) this.select(this.channels[row].id, false)
      if (p.x >= LABEL_W) { dragging = true; c.setPointerCapture(ev.pointerId); this.seek(this.xToT(p.x)) }
    })
    c.addEventListener("pointermove", (ev) => { if (dragging) this.seek(this.xToT(at(ev).x)) })
    c.addEventListener("pointerup", () => { dragging = false })
  }

  width() { return Math.max(400, this.wrapTarget.clientWidth - 2) }
  plotW() { return this.width() - LABEL_W - 12 }
  xToT(x) { return Math.min(this.span, Math.max(0, ((x - LABEL_W) / this.plotW()) * this.span)) }
  tToX(t) { return LABEL_W + (this.span ? (t / this.span) * this.plotW() : 0) }

  async loadTicks() {
    const t = await this.getJSON("ticks", { buckets: Math.round(this.plotW()) })
    if (t.error) { this.wrapTarget.insertAdjacentHTML("beforebegin", `<p class="error">${esc(t.error)}</p>`); return }
    this.ticks = t
    this.span = t.span
    this.draw()
  }

  draw() {
    const c = this.canvasTarget
    const w = this.width()
    const h = AXIS_H + this.channels.length * ROW_H + 6
    const dpr = window.devicePixelRatio || 1
    c.width = w * dpr
    c.height = h * dpr
    c.style.width = `${w}px`
    c.style.height = `${h}px`
    const g = c.getContext("2d")
    g.scale(dpr, dpr)
    const css = getComputedStyle(document.documentElement)
    const text = css.getPropertyValue("--text") || "#222"
    const muted = css.getPropertyValue("--muted") || "#666"
    const line = css.getPropertyValue("--line") || "#ddd"
    g.fillStyle = css.getPropertyValue("--panel") || "#fff"
    g.fillRect(0, 0, w, h)
    g.font = "11px system-ui, sans-serif"
    // The time axis: seconds from the start, and the wall clock of the first.
    g.fillStyle = muted
    g.strokeStyle = line
    const step = niceStep(this.span / 1e9, this.plotW() / 90)
    for (let s = 0; s * 1e9 <= this.span + 1; s += step) {
      const x = this.tToX(s * 1e9)
      g.beginPath(); g.moveTo(x, AXIS_H - 6); g.lineTo(x, h); g.stroke()
      g.fillText(`${+s.toFixed(3)} s`, x + 2, AXIS_H - 10)
    }
    g.fillText(new Date(this.startMs).toLocaleTimeString(), 6, AXIS_H - 10)
    // The rows.
    this.channels.forEach((ch, i) => {
      const y = AXIS_H + i * ROW_H
      if (ch.id === this.selected) {
        g.fillStyle = "rgba(31, 78, 153, 0.10)"
        g.fillRect(0, y, w, ROW_H)
      }
      g.fillStyle = KIND_COLORS[ch.kind] || muted
      g.fillRect(4, y + 7, 8, 8)
      g.fillStyle = text
      g.fillText(shorten(ch.topic, 30), 18, y + 12)
      g.fillStyle = muted
      g.fillText(`${shorten(ch.schema || ch.message_encoding, 24)} - ${ch.count}`, 18, y + 22)
      g.strokeStyle = line
      g.beginPath(); g.moveTo(0, y + ROW_H - 0.5); g.lineTo(w, y + ROW_H - 0.5); g.stroke()
      const counts = this.ticks?.channels?.[ch.id]
      if (!counts) return
      const n = counts.length
      const max = Math.max(...counts, 1)
      g.strokeStyle = KIND_COLORS[ch.kind] || muted
      g.lineWidth = 1
      for (let b = 0; b < n; b++) {
        if (!counts[b]) continue
        const x = LABEL_W + ((b + 0.5) / n) * this.plotW()
        const hh = 5 + (ROW_H - 9) * Math.min(1, Math.log1p(counts[b]) / Math.log1p(max))
        g.beginPath(); g.moveTo(x, y + ROW_H - 2); g.lineTo(x, y + ROW_H - 2 - hh); g.stroke()
      }
    })
    // The cursor.
    const x = this.tToX(this.cursor)
    g.strokeStyle = "#d32f2f"
    g.lineWidth = 2
    g.beginPath(); g.moveTo(x, 4); g.lineTo(x, h); g.stroke()
    g.lineWidth = 1
    this.timeTarget.textContent = `${(this.cursor / 1e9).toFixed(3)} s of ${(this.span / 1e9).toFixed(3)} s  (${fmtClock(this.startMs + this.cursor / 1e6)})`
    if (this.hasRewindLinkTarget) this.rewindLinkTarget.href = `/recordings/${this.idValue}/structure?t=${Math.round(this.cursor)}`
  }

  // ---------------------------------------------------------------- cursor

  seek(t) {
    this.cursor = Math.min(this.span, Math.max(0, Math.round(t)))
    this.draw()
    this.chart?.redraw(false)
    this.refresh()
  }

  select(id, refresh = true) {
    if (this.selected === id) return
    this.selected = id
    this.draw()
    this.loadFields()
    if (refresh) this.refresh()
    else this.refresh()
  }

  // The messages at the cursor: one request at a time (the latest cursor wins).
  async refresh() {
    if (this.inflight) { this.again = true; return }
    this.inflight = true
    try {
      const t = Math.round(this.cursor)
      const [one, all] = await Promise.all([
        this.selected != null ? this.getJSON("message", { channel: this.selected, t }) : null,
        this.getJSON("message", { t }),
      ])
      this.last = one
      this.renderMessage(one)
      this.renderAt(all)
    } finally {
      this.inflight = false
      if (this.again) { this.again = false; this.refresh() }
    }
  }

  stepPrev() { if (this.last?.prev != null) this.seek(this.last.prev) }

  stepNext() {
    if (this.last?.next != null) this.seek(this.last.next)
    else if (this.last && this.last.log_time > this.cursor) this.seek(this.last.log_time)
  }

  renderMessage(m) {
    const ch = this.channels.find((c) => c.id === this.selected)
    if (!ch || !m) { this.messageTarget.innerHTML = `<p class="hint">Click a channel's row.</p>`; return }
    let html = `<p class="name">${esc(ch.topic)}</p>`
    if (m.error && m.log_time == null) { this.messageTarget.innerHTML = html + `<p class="error">${esc(m.error)}</p>`; return }
    const ago = this.cursor - m.log_time
    html += dl([
      ["Type", ch.schema ? `${ch.schema} (${ch.message_encoding})` : ch.message_encoding],
      ["Message", `${m.index + 1} of ${m.count}${ago > 0 ? `, ${(ago / 1e6).toFixed(1)} ms before the cursor` : ago < 0 ? " (the first, after the cursor)" : ""}`],
      ["Received", `${(m.log_time / 1e9).toFixed(6)} s (${fmtClock(this.startMs + m.log_time / 1e6)})`],
      ["Sent", m.publish_offset != null && m.publish_offset !== m.log_time ? `${(m.publish_offset / 1e9).toFixed(6)} s (source time)` : null],
      ["Sequence", m.sequence ? m.sequence : null],
      ["Size", m.size != null ? `${m.size} bytes` : null],
    ])
    if (m.error) html += `<p class="error">${esc(m.error)}</p>`
    if (m.log) {
      const l = m.log
      html += `<p><span class="level lv-${String(l.level).toLowerCase()}">${esc(l.level)}</span> <strong>${esc(l.name)}</strong> ${esc(l.msg)}` +
        (l.file ? ` <span class="hint">${esc(l.file)}:${esc(l.line)} ${esc(l.function)}</span>` : "") + `</p>`
    }
    html += imageTag(m.image)
    if (m.value !== undefined) html += `<pre class="msg-value">${esc(JSON.stringify(m.value, null, 2))}</pre>`
    else if (m.text) html += `<pre class="msg-value">${esc(m.text)}</pre>`
    this.messageTarget.innerHTML = html
  }

  renderAt(all) {
    if (!all || all.error) { this.atListTarget.innerHTML = `<p class="error">${esc(all?.error || "")}</p>`; return }
    const rows = this.channels.filter((c) => c.kind !== "graph").map((c) => {
      const m = all.at?.[c.id]
      const text = !m ? "-" : m.error ? m.error : m.log ? `[${m.log.level}] ${m.log.name}: ${m.log.msg}` : m.text
      const old = m && m.log_time > this.cursor ? " (later)" : ""
      return `<li><a href="#" data-ch="${c.id}">${esc(c.topic)}</a>${old} ${imageTag(m?.image, "msg-thumb")}<code class="wrap">${esc(shorten(text, 160))}</code></li>`
    })
    this.atListTarget.innerHTML = `<ul class="plain at-list">${rows.join("")}</ul>`
    this.atListTarget.querySelectorAll("[data-ch]").forEach((a) => a.addEventListener("click", (ev) => {
      ev.preventDefault()
      this.select(Number(a.dataset.ch))
    }))
  }

  // ---------------------------------------------------------------- fields

  async loadFields() {
    const ch = this.channels.find((c) => c.id === this.selected)
    if (!ch || ch.kind === "graph") { this.fieldsTarget.innerHTML = `<p class="hint">No numeric fields.</p>`; return }
    this.fieldsTarget.innerHTML = `<p class="hint">Reading the fields...</p>`
    const r = await this.getJSON("fields", { channel: ch.id })
    if (r.error) { this.fieldsTarget.innerHTML = `<p class="error">${esc(r.error)}</p>`; return }
    const list = r.fields || []
    if (!list.length) { this.fieldsTarget.innerHTML = `<p class="hint">No numeric fields in ${esc(ch.topic)}.</p>`; return }
    this.fieldsTarget.innerHTML = `<ul class="plain fields">${list.map((f) =>
      `<li><label><input type="checkbox" value="${esc(f.path)}"> <code>${esc(f.path || "(the value)")}</code> <span class="hint">${esc(f.kind)}</span></label></li>`).join("")}</ul>
      <div class="row actions"><button type="button" data-role="plot">Plot</button></div>`
    this.fieldsTarget.querySelector("[data-role=plot]").addEventListener("click", () => {
      const paths = [...this.fieldsTarget.querySelectorAll("input:checked")].map((i) => i.value)
      if (paths.length) this.addSeries(ch, paths)
    })
  }

  // ------------------------------------------------------------------ plot

  async addSeries(ch, paths) {
    this.plotHintTarget.textContent = "Reading the recording..."
    const q = new URLSearchParams({ channel: ch.id })
    paths.forEach((p) => q.append("paths[]", p))
    const res = await fetch(`/recordings/${this.idValue}/series?${q}`, { headers: { Accept: "application/json" } })
    const r = await res.json()
    if (r.error) { this.plotHintTarget.textContent = r.error; return }
    for (const p of paths) {
      if (this.series.some((s) => s.channel === ch.id && s.path === p)) continue
      if (this.series.length >= COLORS.length) break
      this.series.push({ channel: ch.id, topic: ch.topic, path: p, color: COLORS[this.series.length], t: r.t.map((ms) => ms / 1000), v: r.v[p] })
    }
    this.plotHintTarget.textContent = `${ch.topic}: ${r.used} of ${r.messages} messages plotted${r.errors ? `, ${r.errors} did not decode` : ""}. Click the plot to move the cursor.`
    this.buildPlot()
  }

  clearPlot() {
    this.series = []
    this.chart?.destroy()
    this.chart = null
    this.chipsTarget.innerHTML = ""
  }

  buildPlot() {
    this.chart?.destroy()
    const box = this.plotTarget
    box.innerHTML = ""
    this.chipsTarget.innerHTML = this.series.map((s) =>
      `<span class="chip"><span class="swatch line" style="background:${s.color}"></span>${esc(s.topic)} ${esc(s.path)}</span>`).join("")
    const xs = [...new Set(this.series.flatMap((s) => s.t))].sort((a, b) => a - b)
    const cols = this.series.map((s) => {
      const m = new Map(s.t.map((t, i) => [t, s.v[i]]))
      return xs.map((t) => (m.has(t) ? m.get(t) : null))
    })
    const self = this
    const opts = {
      width: Math.max(300, box.clientWidth || 600),
      height: 220,
      legend: { show: true, live: true },
      cursor: { drag: { x: true, y: false } },
      scales: { x: { time: true } },
      axes: [
        { stroke: "#5f6670", grid: { stroke: "#eceff3", width: 1 } },
        { stroke: "#5f6670", grid: { stroke: "#eceff3", width: 1 }, size: 60 },
      ],
      series: [{ label: "time" }, ...this.series.map((s) => ({ label: `${s.topic} ${s.path}`, stroke: s.color, width: 2, spanGaps: true, points: { show: false } }))],
      hooks: {
        draw: [(u) => {
          const x = u.valToPos(self.startMs / 1000 + self.cursor / 1e9, "x", true)
          const ctx = u.ctx
          ctx.save()
          ctx.strokeStyle = "#d32f2f"
          ctx.lineWidth = 2
          ctx.beginPath(); ctx.moveTo(x, u.bbox.top); ctx.lineTo(x, u.bbox.top + u.bbox.height); ctx.stroke()
          ctx.restore()
        }],
      },
    }
    this.chart = new uPlot(opts, [xs, ...cols], box)
    this.chart.over.addEventListener("click", () => {
      const left = this.chart.cursor.left
      if (left == null || left < 0) return
      this.seek((this.chart.posToVal(left, "x") - this.startMs / 1000) * 1e9)
    })
  }

  sizePlot() {
    if (this.chart && this.plotTarget.clientWidth) this.chart.setSize({ width: this.plotTarget.clientWidth, height: 220 })
  }

  // -------------------------------------------------------------- playback

  changeSpeed() {
    if (this.playing && !this.network) { this.playFrom = this.cursor; this.playT0 = performance.now() }
  }

  togglePlay() {
    if (this.playing) return this.stopPlay()
    if (this.modeTarget.value === "network") return this.playNetwork()
    this.playLocal()
  }

  playLocal() {
    if (this.cursor >= this.span) this.cursor = 0
    this.playing = true
    this.playFrom = this.cursor
    this.playT0 = performance.now()
    this.playButtonTarget.textContent = "Pause"
    this.playStatusTarget.textContent = "playing in the page (nothing is sent)"
    const tick = () => {
      if (!this.playing) return
      const speed = Number(this.speedTarget.value)
      const t = this.playFrom + (performance.now() - this.playT0) * 1e6 * speed
      this.seek(t)
      if (t >= this.span) return this.stopPlay("end of the recording")
      this.frame = requestAnimationFrame(tick)
    }
    this.frame = requestAnimationFrame(tick)
  }

  async playNetwork() {
    const sendable = this.channels.filter((c) => c.kind === "ros" || c.kind === "key")
    const count = sendable.reduce((n, c) => n + c.count, 0)
    const speed = Number(this.speedTarget.value)
    const ok = window.confirm(`Play this recording to the network at ${speed}x from ${(this.cursor / 1e9).toFixed(2)} s?\n\n` +
      `It republishes up to ${count} messages on ${sendable.map((c) => c.topic).join(", ")}. ` +
      `Other nodes will receive them and may act on them (robots move on /cmd_vel). The playback is logged with your name.`)
    if (!ok) return
    const res = await fetch("/playbacks", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
      body: JSON.stringify({ recording_id: this.idValue, speed, confirm: "inject", start_ns: this.absStart(this.cursor) }),
    })
    const pb = await res.json()
    if (!res.ok) { this.playStatusTarget.textContent = `not started: ${(pb.errors || [pb.error]).join(", ")}`; return }
    this.network = pb
    this.playing = true
    this.playButtonTarget.textContent = "Stop"
    this.playStatusTarget.textContent = "waiting for the bridge..."
    this.netFrom = this.cursor
    this.netTimer = setInterval(() => this.pollNetwork(), 500)
  }

  // The absolute start time for the server (a string: it does not fit a number).
  absStart(offset) {
    return (BigInt(this.infoValue.start) + BigInt(Math.round(offset))).toString()
  }

  async pollNetwork() {
    if (!this.network) return
    const res = await fetch(`/playbacks/${this.network.id}`, { headers: { Accept: "application/json" } })
    if (!res.ok) return
    const pb = await res.json()
    this.network = pb
    const skipped = Object.entries(pb.skipped || {}).map(([t, why]) => `${t}: ${why}`).join("; ")
    if (pb.status === "running" && pb.started_at) {
      // The page follows the bridge's clock from when it started.
      if (!this.netT0) this.netT0 = performance.now()
      const t = this.netFrom + (performance.now() - this.netT0) * 1e6 * pb.speed
      this.seek(Math.min(t, this.span))
    }
    this.playStatusTarget.textContent = `to the network: ${pb.status}, ${pb.messages_sent} sent${skipped ? ` (not sent: ${skipped})` : ""}${pb.error ? ` - ${pb.error}` : ""}`
    if (!["pending", "running", "stopping"].includes(pb.status)) this.endNetwork()
  }

  endNetwork() {
    clearInterval(this.netTimer)
    this.network = null
    this.netT0 = null
    this.playing = false
    this.playButtonTarget.textContent = "Play"
  }

  async stopPlay(why = "paused") {
    if (this.network) {
      await fetch(`/playbacks/${this.network.id}/stop`, { method: "POST", headers: { Accept: "application/json", "X-CSRF-Token": csrf() } })
      this.pollNetwork()
      return
    }
    this.playing = false
    cancelAnimationFrame(this.frame)
    this.playButtonTarget.textContent = "Play"
    this.playStatusTarget.textContent = why
  }
}

function niceStep(totalS, maxTicks) {
  const raw = totalS / Math.max(1, maxTicks)
  for (const s of [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]) {
    if (s >= raw) return s
  }
  return 7200
}

function fmtClock(ms) {
  const d = new Date(ms)
  return `${d.toLocaleTimeString([], { hour12: false })}.${String(d.getMilliseconds()).padStart(3, "0")}`
}

function dl(rows) {
  return `<dl>${rows.filter(([, b]) => b !== null && b !== undefined).map(([a, b]) => `<dt>${esc(a)}</dt><dd>${esc(b)}</dd>`).join("")}</dl>`
}

// A picture from the bridge ({ mime, data (base64), bytes, width, height };
// Bridge::Payload.image) as an <img>; "" without one.
function imageTag(img, cls = "msg-image") {
  if (!img?.data || !/^image\/(jpeg|png)$/.test(img.mime)) return ""
  const size = img.width ? `${img.width}x${img.height}, ` : ""
  return `<img class="${cls}" src="data:${img.mime};base64,${img.data}" alt="${esc(`${size}${img.bytes} bytes`)}" title="${esc(`${size}${img.bytes} bytes`)}">`
}

function shorten(text, n) {
  const s = String(text ?? "")
  return s.length > n ? `${s.slice(0, n - 3)}...` : s
}

function csrf() {
  return document.querySelector("meta[name=csrf-token]")?.content || ""
}

function esc(v) {
  return String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}
