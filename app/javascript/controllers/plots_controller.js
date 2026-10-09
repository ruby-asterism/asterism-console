import { Controller } from "@hotwired/stimulus"
import uPlot from "uplot"
import { createConsumer } from "@rails/actioncable"

// The plot page (like rqt_plot). A plot holds series, each a field (a path)
// of a target: a ROS 2 topic ("r_topic:0/cmd_vel") or an Asterism key
// ("key:demo/imu"). The page leases its targets with the fields it wants
// (POST /plots/lease, every LEASE_EVERY and at once on a change; released
// on pagehide); the bridge decodes, decimates to at most 30 points a
// second per field and sends them on the "plots" stream, with what it
// knows of each target ("plot_meta": type, fields, error).
//
// Each series keeps the last KEEP_S seconds (at most KEEP_POINTS points).
// A plot shows its window (10 / 30 / 60 s) up to now and redraws REDRAW_MS;
// a paused plot stops redrawing (zoom and the cursor still work) while its
// series go on filling.

const LEASE_EVERY = 10000
const KEEP_S = 60
const KEEP_POINTS = 2000
const REDRAW_MS = 100
const WINDOWS = [10, 30, 60]
// The categorical order (fixed, never cycled; a 9th series reuses no hue:
// a plot takes at most 8).
const COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
const MAX_SERIES = COLORS.length

export default class extends Controller {
  static targets = ["plots", "empty", "source", "key", "meta", "fields", "path", "into", "error", "status"]
  static values = { topics: Array, topic: String }

  connect() {
    this.page = randomToken()
    this.plots = []           // { id, series: [{ target, path, color }], windowS, paused, el, chart }
    this.buffers = new Map()  // "target|path" -> { t: [], v: [] } (seconds, numbers)
    this.metas = new Map()    // target -> meta
    this.stats = new Map()    // target -> { received, kept, errors }
    this.browsing = null      // the target whose fields the picker shows
    this.offset = 0           // the bridge's clock minus this one (ms)
    this.nextId = 1
    this.fillSources(this.topicsValue)
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create({ channel: "ConsoleChannel", stream: "plots" }, {
      received: (msg) => this.received(msg),
    })
    this.leaseTimer = setInterval(() => this.lease(), LEASE_EVERY)
    this.topicTimer = setInterval(() => this.refreshTopics(), 10000)
    this.redrawTimer = setInterval(() => this.redraw(), REDRAW_MS)
    this.onHide = () => this.release()
    window.addEventListener("pagehide", this.onHide)
    this.onResize = () => this.plots.forEach((p) => this.sizeChart(p))
    window.addEventListener("resize", this.onResize)
    if (this.topicValue) this.browse(this.topicValue)
    this.renderInto()
    window.consolePlots = this
  }

  disconnect() {
    clearInterval(this.leaseTimer)
    clearInterval(this.topicTimer)
    clearInterval(this.redrawTimer)
    window.removeEventListener("pagehide", this.onHide)
    window.removeEventListener("resize", this.onResize)
    this.release()
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.plots.forEach((p) => p.chart?.destroy())
  }

  // ---------------------------------------------------------------- sources

  fillSources(topics) {
    const sel = this.sourceTarget
    const current = sel.value || this.browsing || this.topicValue
    sel.innerHTML = `<option value="">(a ROS 2 topic)</option>` + topics.map((t) =>
      `<option value="${esc(t.id)}">${esc(t.name)}${t.domain !== "0" ? ` (domain ${esc(t.domain)})` : ""} - ${esc(t.type || "?")}</option>`).join("")
    if (current && !topics.some((t) => t.id === current) && current.startsWith("r_topic:")) {
      sel.insertAdjacentHTML("beforeend", `<option value="${esc(current)}">${esc(current.replace(/^r_topic:\d+/, ""))} (not on the network now)</option>`)
    }
    if (current?.startsWith("r_topic:")) sel.value = current
  }

  async refreshTopics() {
    try {
      const res = await fetch("/graph", { headers: { Accept: "application/json" } })
      if (!res.ok) return
      const g = (await res.json()).graph || { nodes: [] }
      this.fillSources(g.nodes.filter((n) => n.kind === "r_topic").map((n) => ({
        id: n.id, name: n.data.name, type: n.data.type, domain: n.data.domain,
      })).sort((a, b) => (a.domain + a.name).localeCompare(b.domain + b.name)))
    } catch { /* the next try */ }
  }

  pickSource() {
    if (this.sourceTarget.value) this.browse(this.sourceTarget.value)
  }

  pickKey(ev) {
    ev.preventDefault()
    const key = this.keyTarget.value.trim()
    if (!key) return
    this.browse(`key:${key}`)
  }

  browse(target) {
    this.browsing = target
    if (target.startsWith("r_topic:")) this.sourceTarget.value = target
    this.renderPicker()
    this.lease()
  }

  renderPicker() {
    const target = this.browsing
    if (!target) {
      this.metaTarget.innerHTML = ""
      this.fieldsTarget.innerHTML = ""
      return
    }
    const meta = this.metas.get(target)
    const st = this.stats.get(target)
    let html = `<p class="name">${esc(label(target))}</p>`
    if (!meta) html += `<p class="hint">Asking the bridge...</p>`
    else if (meta.error) html += `<p class="error">${esc(meta.error)}</p>`
    else html += `<p class="hint">${esc(meta.type || "MessagePack values")}${st ? ` - ${st.received} messages seen, ${st.kept} plotted${st.errors ? `, ${st.errors} did not decode` : ""}` : ""}</p>`
    this.metaTarget.innerHTML = html
    const fields = mergeFields(meta)
    if (meta && !meta.error && fields.length === 0) {
      this.fieldsTarget.innerHTML = `<p class="hint">No numeric field seen yet${meta.kind === "key" ? " (waiting for a value on the key)" : ""}. Type a path below.</p>`
      return
    }
    // Keep what is ticked across the re-renders that new meta brings.
    const ticked = new Set([...this.fieldsTarget.querySelectorAll("input:checked")].map((i) => i.value))
    this.fieldsTarget.innerHTML = fields.length ? `<ul class="plain fields">` + fields.map((f) =>
      `<li><label><input type="checkbox" value="${esc(f.path)}"${ticked.has(f.path) ? " checked" : ""}> <code>${esc(f.path || "(the value)")}</code>` +
      ` <span class="hint">${esc(f.kind === "sequence" ? "sequence: edit the index below" : f.kind)}</span></label></li>`).join("") + "</ul>" : ""
    this.fieldsTarget.querySelectorAll("input[type=checkbox]").forEach((cb) => cb.addEventListener("change", () => {
      if (cb.checked && cb.closest("li").textContent.includes("sequence")) this.pathTarget.value = cb.value
    }))
  }

  // ------------------------------------------------------------------ plots

  addFields(ev) {
    ev.preventDefault()
    this.errorTarget.textContent = ""
    const target = this.browsing
    if (!target) { this.errorTarget.textContent = "Pick a topic or a key first."; return }
    const meta = this.metas.get(target)
    if (meta?.error) { this.errorTarget.textContent = meta.error; return }
    const seqs = new Set(mergeFields(meta).filter((f) => f.kind === "sequence").map((f) => f.path))
    const paths = [...this.fieldsTarget.querySelectorAll("input:checked")].map((i) => i.value).filter((p) => !seqs.has(p))
    this.pathTarget.value.split(",").map((s) => s.trim()).filter((s) => s).forEach((p) => paths.push(p))
    const bad = paths.filter((p) => !validPath(p))
    if (bad.length) { this.errorTarget.textContent = `Not a path: ${bad.join(", ")}`; return }
    if (!paths.length) { this.errorTarget.textContent = "Tick a field or type a path."; return }
    let plot = this.plots.find((p) => String(p.id) === this.intoTarget.value)
    if (!plot) plot = this.newPlot()
    for (const path of paths) {
      if (plot.series.some((s) => s.target === target && s.path === path)) continue
      if (plot.series.length >= MAX_SERIES) { this.errorTarget.textContent = `A plot takes ${MAX_SERIES} series at most; add the rest to a new plot.`; break }
      const used = new Set(plot.series.map((s) => s.color))
      plot.series.push({ target, path, color: COLORS.find((c) => !used.has(c)) })
      const k = bufKey(target, path)
      if (!this.buffers.has(k)) this.buffers.set(k, { t: [], v: [] })
    }
    this.fieldsTarget.querySelectorAll("input:checked").forEach((i) => { i.checked = false })
    this.pathTarget.value = ""
    this.buildChart(plot)
    this.renderInto(plot.id)
    this.lease()
  }

  newPlot() {
    const plot = { id: this.nextId++, series: [], windowS: 30, paused: false, el: null, chart: null }
    const el = document.createElement("article")
    el.className = "panel plot"
    el.innerHTML = `
      <div class="plot-head">
        <h2>Plot ${plot.id}</h2>
        <div class="chips" data-role="chips"></div>
        <label class="hint">Window <select data-role="window">${WINDOWS.map((w) =>
          `<option value="${w}"${w === plot.windowS ? " selected" : ""}>last ${w} s</option>`).join("")}</select></label>
        <button type="button" class="small" data-role="pause">Pause</button>
        <button type="button" class="small" data-role="remove" title="Remove this plot">Remove</button>
      </div>
      <div class="chart" data-role="chart"></div>
      <table class="plot-table" data-role="table" aria-label="Latest values"></table>`
    el.querySelector("[data-role=window]").addEventListener("change", (e) => { plot.windowS = Number(e.target.value); this.draw(plot, true) })
    el.querySelector("[data-role=pause]").addEventListener("click", (e) => {
      plot.paused = !plot.paused
      e.target.textContent = plot.paused ? "Resume" : "Pause"
      el.classList.toggle("paused", plot.paused)
      if (!plot.paused) this.draw(plot, true)
    })
    el.querySelector("[data-role=remove]").addEventListener("click", () => this.removePlot(plot))
    plot.el = el
    this.plotsTarget.appendChild(el)
    this.plots.push(plot)
    this.emptyTarget.hidden = true
    return plot
  }

  removePlot(plot) {
    plot.chart?.destroy()
    plot.el.remove()
    this.plots = this.plots.filter((p) => p !== plot)
    this.emptyTarget.hidden = this.plots.length > 0
    this.forgetUnused()
    this.renderInto()
    this.lease()
  }

  removeSeries(plot, i) {
    plot.series.splice(i, 1)
    if (!plot.series.length) return this.removePlot(plot)
    this.buildChart(plot)
    this.forgetUnused()
    this.lease()
  }

  forgetUnused() {
    const used = new Set(this.plots.flatMap((p) => p.series.map((s) => bufKey(s.target, s.path))))
    for (const k of [...this.buffers.keys()]) if (!used.has(k)) this.buffers.delete(k)
  }

  renderInto(selected = null) {
    const sel = this.intoTarget
    const keep = selected != null ? String(selected) : sel.value
    sel.innerHTML = this.plots.map((p) => `<option value="${p.id}">Plot ${p.id}</option>`).join("") + `<option value="new">a new plot</option>`
    sel.value = [...sel.options].some((o) => o.value === keep) ? keep : "new"
  }

  buildChart(plot) {
    plot.chart?.destroy()
    const box = plot.el.querySelector("[data-role=chart]")
    box.innerHTML = ""
    const chips = plot.el.querySelector("[data-role=chips]")
    chips.innerHTML = plot.series.map((s, i) =>
      `<span class="chip"><span class="swatch line" style="background:${s.color}"></span>${esc(seriesLabel(s))}` +
      ` <button type="button" class="x" data-i="${i}" title="Remove this series" aria-label="Remove ${esc(seriesLabel(s))}">&times;</button></span>`).join("")
    chips.querySelectorAll("button.x").forEach((b) => b.addEventListener("click", () => this.removeSeries(plot, Number(b.dataset.i))))
    const opts = {
      width: Math.max(300, box.clientWidth || 600),
      height: 240,
      legend: { show: true, live: true },
      cursor: { drag: { x: true, y: false } },
      scales: { x: { time: true } },
      axes: [
        { stroke: "#5f6670", grid: { stroke: "#eceff3", width: 1 }, ticks: { stroke: "#dde1e6" } },
        { stroke: "#5f6670", grid: { stroke: "#eceff3", width: 1 }, ticks: { stroke: "#dde1e6" }, size: 60 },
      ],
      series: [{ label: "time" }, ...plot.series.map((s) => ({
        label: seriesLabel(s), stroke: s.color, width: 2, spanGaps: true, points: { show: false },
        value: (u, v) => (v == null ? "-" : fmtNum(v)),
      }))],
    }
    plot.chart = new uPlot(opts, [[], ...plot.series.map(() => [])], box)
    this.draw(plot, true)
  }

  sizeChart(plot) {
    const box = plot.el.querySelector("[data-role=chart]")
    if (plot.chart && box.clientWidth) plot.chart.setSize({ width: box.clientWidth, height: 240 })
  }

  // --------------------------------------------------------------- receive

  received(msg) {
    if (msg.type === "plot_meta") {
      this.metas.set(msg.meta.target, msg.meta)
      if (msg.meta.target === this.browsing) this.renderPicker()
      this.renderStatus()
    } else if (msg.type === "plot") {
      this.addPoints(msg.points || {})
    }
  }

  addPoints(points) {
    for (const [target, p] of Object.entries(points)) {
      this.stats.set(target, { received: p.received, kept: p.kept, errors: p.errors })
      const times = p.t || []
      if (times.length) this.offset = times[times.length - 1] - Date.now()
      for (const [path, values] of Object.entries(p.v || {})) {
        const b = this.buffers.get(bufKey(target, path))
        if (!b) continue
        for (let i = 0; i < times.length; i++) { b.t.push(times[i] / 1000); b.v.push(values[i]) }
        trim(b, times.length ? times[times.length - 1] / 1000 : null)
      }
      if (target === this.browsing) this.renderPicker()
    }
    this.renderStatus()
  }

  renderStatus() {
    const targets = new Set(this.plots.flatMap((p) => p.series.map((s) => s.target)))
    const rows = [...targets].map((t) => {
      const st = this.stats.get(t)
      const m = this.metas.get(t)
      return `${label(t)}: ${m?.error ? m.error : st ? `${st.received} messages, ${st.kept} plotted` : "waiting"}`
    })
    this.statusTarget.textContent = rows.join(" / ")
  }

  // ------------------------------------------------------------------ draw

  redraw() {
    for (const p of this.plots) if (!p.paused) this.draw(p)
  }

  // The series of a plot share one time axis: the union of their times in
  // the window (one target's fields share their times anyway).
  draw(plot, force = false) {
    if (!plot.chart || (plot.paused && !force)) return
    const now = (Date.now() + this.offset) / 1000
    const from = now - plot.windowS
    const cols = plot.series.map((s) => this.buffers.get(bufKey(s.target, s.path)) || { t: [], v: [] })
    const xs = new Set()
    const maps = cols.map((b) => {
      const m = new Map()
      for (let i = 0; i < b.t.length; i++) if (b.t[i] >= from) { m.set(b.t[i], b.v[i]); xs.add(b.t[i]) }
      return m
    })
    const x = [...xs].sort((a, b) => a - b)
    const data = [x, ...maps.map((m) => x.map((t) => (m.has(t) ? m.get(t) : null)))]
    plot.chart.batch(() => {
      plot.chart.setData(data, false)
      plot.chart.setScale("x", { min: from, max: now })
      plot.chart.setScale("y", yRange(data.slice(1)))
    })
    this.renderTable(plot, cols)
  }

  // The latest value of each series, as text (the chart's table view).
  renderTable(plot, cols) {
    const t = plot.el.querySelector("[data-role=table]")
    t.innerHTML = plot.series.map((s, i) => {
      const b = cols[i]
      const v = b.v.length ? b.v[b.v.length - 1] : null
      return `<tr><td><span class="swatch line" style="background:${s.color}"></span> ${esc(seriesLabel(s))}</td>` +
        `<td class="num">${v == null ? "-" : esc(fmtNum(v))}</td><td class="hint">${b.t.length} points kept</td></tr>`
    }).join("")
  }

  // ----------------------------------------------------------------- lease

  wanted() {
    const by = new Map()
    for (const p of this.plots) for (const s of p.series) {
      if (!by.has(s.target)) by.set(s.target, new Set())
      by.get(s.target).add(s.path)
    }
    if (this.browsing && !by.has(this.browsing)) by.set(this.browsing, new Set())
    return [...by].map(([target, fields]) => ({ target, fields: [...fields] }))
  }

  async lease() {
    const wanted = this.wanted()
    try {
      const res = await fetch("/plots/lease", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
        body: JSON.stringify({ page: this.page, wanted }),
      })
      const body = await res.json()
      for (const l of body.leases || []) if (l.meta) this.metas.set(l.target, l.meta)
      this.errorTarget.textContent = (body.errors || []).join("; ")
      this.renderPicker()
      this.renderStatus()
      // The bridge answers on its next sync (0.5 s); ask again soon while
      // the picker has nothing to show.
      if (this.browsing && !this.metas.get(this.browsing)) {
        clearTimeout(this.soon)
        this.soon = setTimeout(() => this.lease(), 1000)
      }
    } catch { /* the next renewal */ }
  }

  release() {
    const body = new FormData()
    body.append("page", this.page)
    body.append("authenticity_token", csrf())
    navigator.sendBeacon?.("/plots/release", body)
  }
}

// --------------------------------------------------------------- helpers

function mergeFields(meta) {
  if (!meta || meta.error) return []
  const out = [...(meta.fields || [])]
  const have = new Set(out.map((f) => f.path))
  for (const f of meta.observed || []) if (!have.has(f.path)) { out.push(f); have.add(f.path) }
  // A sequence seen with elements needs no "[0] of an empty sequence" entry.
  return out.filter((f) => f.kind !== "sequence" || !out.some((g) => g !== f && g.kind !== "sequence" && g.path.startsWith(f.path.replace(/\[0\]$/, "["))))
}

function trim(b, latest) {
  if (latest == null) return
  let drop = 0
  while (drop < b.t.length && b.t[drop] < latest - KEEP_S) drop++
  drop = Math.max(drop, b.t.length - KEEP_POINTS)
  if (drop > 0) { b.t.splice(0, drop); b.v.splice(0, drop) }
}

function yRange(cols) {
  let lo = Infinity
  let hi = -Infinity
  for (const c of cols) for (const v of c) if (v != null) { if (v < lo) lo = v; if (v > hi) hi = v }
  if (lo === Infinity) return { min: -1, max: 1 }
  if (lo === hi) return { min: lo - 1, max: hi + 1 }
  const pad = (hi - lo) * 0.08
  return { min: lo - pad, max: hi + pad }
}

const bufKey = (target, path) => `${target}|${path}`
const label = (target) => target.startsWith("key:") ? target.slice(4) : target.replace(/^r_topic:(\d+)/, (_, d) => (d === "0" ? "" : `[${d}]`))
const seriesLabel = (s) => `${label(s.target)} ${s.path || "(value)"}`

// The same rule as Bridge::Fields.parse.
function validPath(p) {
  if (p === "") return true
  if (p.length > 120) return false
  return p.split(".").every((part) => part !== "" && /^[^.[\]\s]*(\[\d{1,6}\])*$/.test(part))
}

function fmtNum(v) {
  if (typeof v !== "number") return String(v)
  if (Number.isInteger(v)) return String(v)
  const a = Math.abs(v)
  return a !== 0 && (a < 0.001 || a >= 1e6) ? v.toExponential(3) : v.toFixed(4).replace(/\.?0+$/, "")
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
