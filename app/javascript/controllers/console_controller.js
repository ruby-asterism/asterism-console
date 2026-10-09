import { Controller } from "@hotwired/stimulus"
import cytoscape from "cytoscape"
import { createConsumer } from "@rails/actioncable"

// The console page: the graph (cytoscape), the details of the selected
// node, calls to exposed methods and the watched keys. The first graph
// comes with the page; afterwards the bridge's diffs arrive on
// ConsoleChannel. Requests (meta, call) and watches go out over HTTP.

const KINDS = {
  router:    { label: "Router",          shape: "diamond",         color: "#1f4e99", size: 46 },
  session:   { label: "Session",         shape: "ellipse",         color: "#8a8f98", size: 22 },
  a_node:    { label: "Asterism node",   shape: "round-rectangle", color: "#2e7d32", size: 38 },
  a_app:     { label: "Asterism app",    shape: "hexagon",         color: "#00897b", size: 30 },
  a_object:  { label: "Asterism object", shape: "ellipse",         color: "#7cb342", size: 26 },
  r_node:    { label: "ROS 2 node",      shape: "round-rectangle", color: "#6a1b9a", size: 36 },
  r_topic:   { label: "ROS 2 topic",     shape: "tag",             color: "#ef6c00", size: 30 },
  r_service: { label: "ROS 2 service",   shape: "round-triangle",  color: "#c2185b", size: 30 },
  registered: { label: "Registered, not here", shape: "round-rectangle", color: "#c9ced6", size: 30 },
}

// The relay registry over the graph (W2): a halo by how a node matches it.
const REGISTRY = {
  registered:   { label: "registered, here",          color: "#2e7d32" },
  disabled:     { label: "here, disabled in registry", color: "#ef6c00" },
  unregistered: { label: "not in the registry",       color: "#d32f2f" },
  absent:       { label: "registered, not here",      color: "#8a8f98" },
}

const EDGE_COLORS = {
  session: "#9aa0a6", router_link: "#1f4e99", carries: "#c0c4ca",
  has_app: "#2e7d32", exposes: "#7cb342",
  publishes: "#ef6c00", subscribes: "#ef6c00", serves: "#c2185b", calls: "#c2185b",
}

const STATUS_TEXT = {
  ok: "ok", remote_error: "RemoteError", timeout: "Timeout", error: "error",
  expired: "expired", pending: "waiting for the bridge", running: "running", denied: "not permitted",
}

// Same rule as CallPermission.match? (Ruby): * matches any run of characters.
function globMatch(pattern, value) {
  const re = new RegExp("^" + String(pattern).replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*") + "$")
  return re.test(String(value))
}

export default class extends Controller {
  static targets = ["graph", "details", "bridge", "counts", "watchList", "watchError", "legend"]
  static values = { state: Object, watches: Array }

  connect() {
    this.version = this.stateValue.version || 0
    this.layers = { infra: true, asterism: true, ros: true, registry: true }
    this.pending = new Map()   // request id -> handler
    this.samples = new Map()   // watch id -> [sample, ...]
    this.watches = new Map()
    this.selected = null
    this.lastBeat = 0
    this.setupGraph(this.stateValue.graph)
    this.showBridge(this.stateValue.bridge || {})
    this.watchesValue.forEach((w) => this.watches.set(w.id, w))
    this.renderWatches()
    this.renderLegend()
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create("ConsoleChannel", {
      received: (msg) => this.received(msg),
      connected: () => this.refetch(),
    })
    this.beatTimer = setInterval(() => this.checkBeat(), 2000)
  }

  disconnect() {
    clearInterval(this.beatTimer)
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.cy?.destroy()
  }

  // ------------------------------------------------------------------ graph

  setupGraph(graph) {
    this.cy = cytoscape({
      container: this.graphTarget,
      elements: this.elementsOf(graph),
      style: this.graphStyle(),
      layout: { name: "preset" },
    })
    this.cy.on("tap", "node", (ev) => this.select(ev.target.id()))
    this.cy.on("tap", (ev) => { if (ev.target === this.cy) this.select(null) })
    this.layout(true)
    this.updateCounts()
    window.consoleGraph = this.cy // for the headless checks
  }

  graphStyle() {
    const s = [
      { selector: "node", style: {
          label: "data(label)", "font-size": 10, color: "#222", "text-valign": "bottom", "text-margin-y": 4,
          "text-wrap": "ellipsis", "text-max-width": 140, "border-width": 1, "border-color": "#fff" } },
      { selector: "node[?self]", style: { "border-width": 3, "border-style": "dashed", "border-color": "#333" } },
      { selector: "node:selected", style: { "border-width": 4, "border-color": "#ffb300" } },
      { selector: "edge", style: {
          width: 1.5, "curve-style": "bezier", "target-arrow-shape": "triangle", "arrow-scale": 0.8,
          "line-color": "#bbb", "target-arrow-color": "#bbb" } },
      { selector: "edge[kind = 'carries']", style: { "line-style": "dashed", width: 1 } },
      { selector: "edge[kind = 'session'], edge[kind = 'router_link']", style: { "target-arrow-shape": "none" } },
      { selector: "edge[kind = 'router_link']", style: { width: 3 } },
      { selector: "edge[kind = 'router_link'][label]", style: {
          label: "data(label)", "font-size": 9, color: "#1f4e99", "text-background-color": "#fff",
          "text-background-opacity": 1, "text-background-padding": 2 } },
      { selector: "node[registry = 'registered'], node[registry = 'disabled'], node[registry = 'unregistered']",
        style: { "underlay-opacity": 0.8, "underlay-padding": 8, "underlay-shape": "ellipse" } },
      { selector: "node[registry = 'registered']", style: { "underlay-color": REGISTRY.registered.color } },
      { selector: "node[registry = 'disabled']", style: { "underlay-color": REGISTRY.disabled.color } },
      { selector: "node[registry = 'unregistered']", style: { "underlay-color": REGISTRY.unregistered.color } },
      { selector: "node[kind = 'registered']", style: {
          "border-width": 2, "border-style": "dashed", "border-color": "#6b7280", "background-opacity": 0.5, color: "#555" } },
      { selector: "node.reg-off", style: { "underlay-opacity": 0 } },
      { selector: ".flash", style: { "overlay-color": "#ffb300", "overlay-opacity": 0.35, "overlay-padding": 6 } },
    ]
    for (const [kind, k] of Object.entries(KINDS)) {
      s.push({ selector: `node[kind = '${kind}']`,
               style: { shape: k.shape, "background-color": k.color, width: k.size, height: k.size } })
    }
    for (const [kind, c] of Object.entries(EDGE_COLORS)) {
      s.push({ selector: `edge[kind = '${kind}']`, style: { "line-color": c, "target-arrow-color": c } })
    }
    return s
  }

  elementsOf(graph) {
    const nodes = (graph.nodes || []).map((n) => this.nodeElement(n))
    const edges = (graph.edges || []).map((e) => this.edgeElement(e))
    return nodes.concat(edges)
  }

  nodeElement(n) {
    let label = n.data?.self ? `${n.label} (this console)` : n.label
    if (n.kind === "registered") label = `${n.label} (registered, not here)`
    const data = { id: n.id, kind: n.kind, layer: n.layer, label, self: !!n.data?.self, info: n.data }
    if (n.data?.registry) data.registry = n.data.registry
    return { group: "nodes", data, classes: `layer-${n.layer}` }
  }

  edgeElement(e) {
    const data = { id: e.id, kind: e.kind, layer: e.layer, source: e.source, target: e.target }
    if (e.label) data.label = e.label
    return { group: "edges", data }
  }

  applyDiff(diff) {
    const cy = this.cy
    let structural = false
    cy.batch(() => {
      for (const id of diff.remove_edges) cy.getElementById(id).remove()
      for (const id of diff.remove_nodes) { cy.getElementById(id).remove(); structural = true }
      const added = []
      for (const n of diff.add_nodes) {
        const el = cy.add(this.nodeElement(n))
        added.push(el)
        structural = true
      }
      for (const n of diff.change_nodes) {
        const el = cy.getElementById(n.id)
        const fresh = this.nodeElement(n).data
        el.data({ label: fresh.label, info: fresh.info, self: fresh.self, registry: fresh.registry })
      }
      for (const e of diff.add_edges) {
        if (cy.getElementById(e.source).nonempty() && cy.getElementById(e.target).nonempty()) {
          cy.add(this.edgeElement(e))
          structural = true
        }
      }
      // New nodes start next to a neighbour, so the layout moves them a little.
      for (const el of added) {
        const near = el.neighborhood("node").filter((x) => !added.includes(x)).first()
        const p = near.nonempty() ? near.position() : { x: 0, y: 0 }
        el.position({ x: p.x + (Math.random() - 0.5) * 80, y: p.y + (Math.random() - 0.5) * 80 })
        el.addClass("flash")
        setTimeout(() => el.removeClass("flash"), 1500)
      }
    })
    this.applyLayers()
    if (structural) this.layout(false)
    this.updateCounts()
    if (this.selected) {
      if (cy.getElementById(this.selected).empty()) this.showGone(this.selected)
      else if (diff.change_nodes.some((n) => n.id === this.selected) || structural) this.refreshDetails()
    }
  }

  replaceGraph(payload) {
    this.version = payload.version
    this.cy.elements().remove()
    this.cy.add(this.elementsOf(payload.graph))
    this.applyLayers()
    this.layout(true)
    this.updateCounts()
    this.showBridge(payload.bridge || {})
    if (this.selected) this.refreshDetails()
  }

  async refetch() {
    try {
      const res = await fetch("/graph", { headers: { Accept: "application/json" } })
      if (!res.ok) return
      const payload = await res.json()
      if (payload.version !== this.version) this.replaceGraph(payload)
      else this.showBridge(payload.bridge || {})
    } catch (_e) { /* the next diff tries again */ }
  }

  layout(fit) {
    const visible = this.cy.elements(":visible")
    if (visible.empty()) return
    visible.layout({
      name: "cose", animate: !fit, animationDuration: 400, randomize: fit, fit: fit, padding: 30,
      nodeDimensionsIncludeLabels: true, idealEdgeLength: () => 70, nodeRepulsion: () => 9000,
      componentSpacing: 60,
    }).run()
  }

  relayout() {
    this.layout(true)
  }

  toggleLayer(ev) {
    this.layers[ev.target.dataset.layer] = ev.target.checked
    this.applyLayers()
    this.layout(true)
    this.updateCounts()
  }

  applyLayers() {
    this.cy.batch(() => {
      this.cy.nodes().forEach((n) => {
        let shown = this.layers[n.data("layer")]
        if (n.data("kind") === "registered") shown = shown && this.layers.registry
        n.style("display", shown ? "element" : "none")
        if (this.layers.registry) n.removeClass("reg-off")
        else n.addClass("reg-off")
      })
    })
  }

  updateCounts() {
    const by = {}
    this.cy.nodes().forEach((n) => { by[n.data("kind")] = (by[n.data("kind")] || 0) + 1 })
    const parts = Object.keys(KINDS).filter((k) => by[k]).map((k) => `${KINDS[k].label}: ${by[k]}`)
    this.countsTarget.textContent = `v${this.version}  ${parts.join("  ")}`
  }

  renderLegend() {
    this.legendTarget.innerHTML = Object.values(KINDS).map((k) =>
      `<span class="key"><span class="swatch shape-${k.shape}" style="background:${k.color}"></span>${k.label}</span>`
    ).join("") + `<span class="key"><span class="swatch dashed"></span>this console</span>` +
      Object.values(REGISTRY).filter((r) => r !== REGISTRY.absent).map((r) =>
        `<span class="key"><span class="swatch halo" style="box-shadow: 0 0 0 3px ${r.color}"></span>${r.label}</span>`).join("")
  }

  // ----------------------------------------------------------------- cable

  received(msg) {
    switch (msg.type) {
      case "graph_diff":
        if (msg.version <= this.version) return
        if (msg.version !== this.version + 1) return this.refetch()
        this.version = msg.version
        this.applyDiff(msg.diff)
        break
      case "bridge":
        this.showBridge(msg.bridge)
        if (msg.version > this.version) this.refetch()
        break
      case "request": {
        const h = this.pending.get(msg.request.id)
        if (h) { this.pending.delete(msg.request.id); h(msg.request) }
        break
      }
      case "sample": this.addSample(msg); break
      case "watch": this.watches.set(msg.watch.id, msg.watch); this.renderWatches(); break
      case "unwatch": this.watches.delete(msg.watch.id); this.samples.delete(msg.watch.id); this.renderWatches(); break
    }
  }

  showBridge(b) {
    if (b.alive) this.lastBeat = Date.now()
    const el = this.bridgeTarget
    el.classList.toggle("down", !b.alive)
    el.textContent = b.alive ? `bridge: ${b.node || "?"} on ${b.router || "?"}` : "bridge: not running (start bin/bridge)"
  }

  checkBeat() {
    if (this.lastBeat && Date.now() - this.lastBeat > 10000) this.showBridge({ alive: false })
  }

  // --------------------------------------------------------------- details

  select(id) {
    this.selected = id
    this.metaFor = null
    this.refreshDetails()
  }

  showGone(id) {
    this.detailsTarget.innerHTML = `<h2>Details</h2><p class="hint">${esc(id)} has left the network.</p>`
  }

  refreshDetails() {
    const id = this.selected
    if (!id) {
      this.detailsTarget.innerHTML = `<h2>Details</h2><p class="hint">Click a node in the graph.</p>`
      return
    }
    const el = this.cy.getElementById(id)
    if (el.empty()) return this.showGone(id)
    const kind = el.data("kind")
    const info = el.data("info") || {}
    const k = KINDS[kind]
    let html = `<h2><span class="swatch" style="background:${k.color}"></span>${esc(k.label)}</h2>`
    html += `<p class="name">${esc(el.data("label"))}</p>`
    const rows = []
    const names = (sel) => el.connectedEdges(sel).map((e) => e.source().id() === id ? e.target() : e.source())
    switch (kind) {
      case "router":
        rows.push(["ID", info.zid], ["Name", info.name], ["Version", info.version],
                  ["Locators", (info.locators || []).join(", ")],
                  ["Plugins", (info.plugins || []).join(", ")], ["Sessions", info.sessions],
                  ["Certificate", info.cert_name ? `${info.cert_name} (seen by the bridge)` : null],
                  ["Router links", (info.router_links || []).map((l) => {
                    const peer = this.cy.getElementById(`router:${String(l.peer).replace(/^0+/, "")}`)
                    const who = peer.empty() ? String(l.peer).slice(0, 8) : peer.data("label")
                    const ends = (l.links || []).map((k) => `${k.src} -> ${k.dst}`).join("<br>")
                    return `${esc(l.protocol || "?")} to ${esc(who)}<br><span class="hint">${esc(ends)}</span>`
                  }).join("<br>") || null, true])
        break
      case "session":
        rows.push(["ID", info.zid], ["Kind", info.whatami], ["Link", info.protocol],
                  ["Certificate", info.protocol === "tls" ? (info.cert_name || "(the router does not show it)") : null],
                  ["Address", info.address],
                  ["Links", (info.links || []).map((l) => `${l.dst} -> ${l.src}`).join("<br>"), true],
                  ["Carries", names("[kind = 'carries']").map((n) => esc(n.data("label"))).join(", "), true])
        break
      case "a_node":
        rows.push(["ID", info.node], ["Apps", names("[kind = 'has_app']").map((n) => esc(n.data("label"))).join(", "), true],
                  ["Session", names("[kind = 'carries']").map((n) => esc(n.data("label"))).join(", "), true])
        break
      case "a_app":
        rows.push(["Node", info.node], ["Objects", names("[kind = 'exposes']").map((n) => esc(n.data("label"))).join(", "), true])
        break
      case "a_object":
        rows.push(["Path", info.path])
        break
      case "r_node":
        rows.push(["Name", info.name], ["Session ID", info.zid], ["Domain", info.domain],
                  ["Publishes", names("[kind = 'publishes']").map((n) => esc(n.data("label"))).join(", "), true],
                  ["Subscribes", names("[kind = 'subscribes']").map((n) => esc(n.data("label"))).join(", "), true],
                  ["Serves", names("[kind = 'serves']").map((n) => esc(n.data("label"))).join(", "), true])
        break
      case "r_topic":
      case "r_service": {
        const out = kind === "r_topic" ? "publishes" : "calls"
        const inn = kind === "r_topic" ? "subscribes" : "serves"
        rows.push(["Type", info.type], ["Domain", info.domain],
                  [kind === "r_topic" ? "Publishers" : "Clients",
                   names(`[kind = '${out}']`).map((n) => esc(n.data("label"))).join("<br>") || "none", true],
                  [kind === "r_topic" ? "Subscribers" : "Servers",
                   names(`[kind = '${inn}']`).map((n) => esc(n.data("label"))).join("<br>") || "none", true])
        break
      }
    }
    if (["a_node", "router", "registered"].includes(kind) && info.registry) {
      const p = info.peer || {}
      const r = REGISTRY[info.registry]
      const parts = [r ? r.label : info.registry]
      if (p.kind) parts.push(p.kind)
      if (p.name) parts.push(p.in_acl ? "in the ACL" : "not in the ACL")
      if (p.expires) parts.push(`certificate until ${p.expires.slice(0, 10)}`)
      rows.push(["Registry", `<span class="swatch halo" style="box-shadow: 0 0 0 3px ${r ? r.color : "#999"}"></span> ` +
                 esc(parts.join(", ")) + (p.name ? ` <a href="/relay/peers">registry</a>` : ""), true])
      if (info.via) rows.push(["Through", `router ${info.via}`])
      if (kind === "registered" && p.description) rows.push(["Description", p.description])
    }
    html += `<dl>${rows.filter(([, b]) => b !== null).map(([a, b, raw]) => `<dt>${esc(a)}</dt><dd>${raw ? (b || "") : esc(b ?? "")}</dd>`).join("")}</dl>`
    if (kind === "a_object") html += `<div class="methods" data-role="methods"><p class="hint">Reading the exposed methods...</p></div><div class="results" data-role="results"></div>`
    if (kind === "r_topic") html += `<button type="button" data-role="watch-topic">Watch its values</button>`
    this.detailsTarget.innerHTML = html
    if (kind === "a_object") this.loadMeta(info.path)
    if (kind === "r_topic") {
      this.detailsTarget.querySelector("[data-role=watch-topic]").addEventListener("click", () => {
        this.watchKey(`${info.domain}${info.name}/**`)
      })
    }
  }

  async loadMeta(path) {
    const box = () => this.detailsTarget.querySelector("[data-role=methods]")
    let rules = []
    try {
      const res = await fetch(`/call_permissions.json?path=${encodeURIComponent(path)}`, { headers: { Accept: "application/json" } })
      if (res.ok) rules = await res.json()
    } catch (_e) { /* treated as none */ }
    if (this.selected !== `a_object:${path}` || !box()) return
    if (rules.length === 0) {
      box().innerHTML = `<p class="hint">No call permission covers this object, so its methods are not read or called.
        <a href="/call_permissions">Call permissions</a></p>`
      return
    }
    const allowed = (name) => rules.some((r) => globMatch(r.method, name))
    const req = await this.request({ kind: "meta", path, timeout_s: 3 })
    if (this.selected !== `a_object:${path}` || !box()) return
    if (req.status !== "ok") {
      box().innerHTML = `<p class="error">meta: ${esc(STATUS_TEXT[req.status] || req.status)} ${esc(req.error_class || "")} ${esc(req.error_message || req.errors || "")}</p>`
      return
    }
    const methods = (req.result?.methods || []).map((m) => Array.isArray(m) ? m : [m, -1])
    let html = `<h3>Exposed methods</h3>`
    for (const [name, arity] of methods) {
      const hint = arity >= 0 ? `${arity} argument${arity === 1 ? "" : "s"}` : "any arguments"
      const example = name === "say" ? '["hello from the console"]' : "[]"
      const ok = allowed(name)
      html += `<form class="call${ok ? "" : " not-allowed"}" data-method="${esc(name)}">
        <label><code>${esc(name)}</code> <span class="hint">${hint}${ok ? "" : ", not permitted"}</span></label>
        <div class="row"><input type="text" name="args" value='${esc(example)}' aria-label="Arguments of ${esc(name)} (JSON array)"${ok ? "" : " disabled"}>
        <button type="submit"${ok ? "" : " disabled"}>Call</button></div></form>`
    }
    html += `<details><summary>Another method (not in the list)</summary>
      <form class="call" data-method="">
        <div class="row"><input type="text" name="method" placeholder="name" aria-label="Method name" required>
        <input type="text" name="args" value="[]" aria-label="Arguments (JSON array)">
        <button type="submit">Call</button></div></form></details>`
    box().innerHTML = html
    box().querySelectorAll("form.call").forEach((f) => f.addEventListener("submit", (ev) => {
      ev.preventDefault()
      const name = f.dataset.method || f.querySelector("[name=method]").value.trim()
      this.call(path, name, f.querySelector("[name=args]").value)
    }))
  }

  async call(path, name, argsText) {
    const results = this.detailsTarget.querySelector("[data-role=results]")
    const row = document.createElement("div")
    row.className = "result running"
    row.innerHTML = `<code>${esc(name)}(${esc(argsText)})</code> <span class="status">sending</span>`
    results?.prepend(row)
    const req = await this.request({ kind: "call", path, method_name: name, args: argsText, timeout_s: 3 })
    row.className = `result ${req.status || "error"}`
    let text
    if (req.errors) text = `not sent: ${req.errors.join(", ")}`
    else if (req.status === "ok") text = `=> ${JSON.stringify(req.result)}`
    else text = `${STATUS_TEXT[req.status] || req.status}: ${req.error_class || ""} ${req.error_message || ""}`
    const took = req.took_ms != null ? ` <span class="took">${req.took_ms} ms</span>` : ""
    row.innerHTML = `<code>${esc(name)}(${esc(argsText)})</code> <span class="status">${esc(text)}</span>${took}`
  }

  // Sends a request; resolves with its answer (from the channel, or by
  // asking again when the channel stays quiet).
  async request(body) {
    let res
    try {
      res = await fetch("/bridge_requests", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
        body: JSON.stringify(body),
      })
    } catch (e) {
      return { status: "error", error_message: String(e) }
    }
    const created = await res.json()
    if (res.status === 403 && created.status === "denied") return created
    if (!res.ok) return { errors: created.errors || ["rejected"], status: "error" }
    if (["ok", "remote_error", "timeout", "error", "expired", "denied"].includes(created.status)) return created
    return new Promise((resolve) => {
      this.pending.set(created.id, resolve)
      const limit = Date.now() + (body.timeout_s + 35) * 1000
      const poll = async () => {
        if (!this.pending.has(created.id)) return
        try {
          const r = await (await fetch(`/bridge_requests/${created.id}`, { headers: { Accept: "application/json" } })).json()
          if (!["pending", "running"].includes(r.status)) { this.pending.delete(created.id); return resolve(r) }
        } catch (_e) { /* try again */ }
        if (Date.now() > limit) { this.pending.delete(created.id); return resolve({ ...created, status: "expired" }) }
        setTimeout(poll, 2000)
      }
      setTimeout(poll, (body.timeout_s + 1) * 1000)
    })
  }

  // ---------------------------------------------------------------- watches

  addWatch(ev) {
    ev.preventDefault()
    const input = ev.target.querySelector("[name=key]")
    this.watchKey(input.value.trim()).then((ok) => { if (ok) input.value = "" })
  }

  async watchKey(key) {
    this.watchErrorTarget.textContent = ""
    if (!key) return false
    const res = await fetch("/watches", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
      body: JSON.stringify({ key }),
    })
    const w = await res.json()
    if (!res.ok) { this.watchErrorTarget.textContent = (w.errors || ["rejected"]).join(", "); return false }
    this.watches.set(w.id, w)
    this.renderWatches()
    return true
  }

  async removeWatch(id) {
    await fetch(`/watches/${id}`, { method: "DELETE", headers: { "X-CSRF-Token": csrf() } })
    this.watches.delete(id)
    this.samples.delete(id)
    this.renderWatches()
  }

  addSample(msg) {
    const list = this.samples.get(msg.watch_id) || []
    list.unshift(msg)
    list.length = Math.min(list.length, 12)
    this.samples.set(msg.watch_id, list)
    this.renderWatch(msg.watch_id)
  }

  renderWatches() {
    this.watchListTarget.innerHTML = ""
    for (const w of this.watches.values()) {
      const div = document.createElement("div")
      div.className = "watch"
      div.dataset.watchId = w.id
      this.watchListTarget.append(div)
      this.renderWatch(w.id)
    }
  }

  renderWatch(id) {
    const w = this.watches.get(id)
    const div = this.watchListTarget.querySelector(`[data-watch-id="${id}"]`)
    if (!w || !div) return
    const list = this.samples.get(id) || []
    const dropped = list[0]?.dropped ? ` <span class="hint">(${list[0].dropped} skipped)</span>` : ""
    div.innerHTML = `<div class="watch-head"><code>${esc(w.key)}</code>${dropped}
        <button type="button" class="small" aria-label="Stop watching ${esc(w.key)}">Stop</button></div>` +
      (w.error ? `<p class="error">${esc(w.error)}</p>` : "") +
      (list.length ? `<ol class="samples">${list.map((s) =>
        `<li><span class="at">${esc(s.at)}</span> <code class="k" title="${esc(s.key)}">${esc(shorten(s.key, 48))}</code> <span class="fmt">${esc(s.format)}</span> <span class="v">${esc(s.text)}</span></li>`).join("")}</ol>`
        : `<p class="hint">Nothing yet.</p>`)
    div.querySelector("button").addEventListener("click", () => this.removeWatch(id))
  }
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
