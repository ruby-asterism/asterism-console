import { Controller } from "@hotwired/stimulus"
import cytoscape from "cytoscape"
import fcose from "cytoscape-fcose"
import { createConsumer } from "@rails/actioncable"

cytoscape.use(fcose)

// The console page: the graph (cytoscape), the details of the selected
// node or edge, calls to exposed methods, topic rates and the watched keys.
// The first graph comes with the page; afterwards the bridge's diffs and
// rates arrive on ConsoleChannel. Requests (meta, call), rate leases and
// watches go out over HTTP.
//
// The graph (lib/bridge/graph.rb): Asterism apps and objects nest in their
// node (compound nodes); ROS 2 services are attributes of their node (a
// badge and the details); ROS 2 topics are edges from publisher to
// subscriber ("topic_link"), or, with "Topics as nodes", nodes between them
// as before. Positions stay where they are: only new nodes are placed
// (next to their neighbours, the others held fixed), and "Lay out again"
// lays out everything.

const KINDS = {
  router:    { label: "Router",          shape: "diamond",         color: "#1f4e99", size: 46 },
  session:   { label: "Session",         shape: "ellipse",         color: "#8a8f98", size: 22 },
  a_node:    { label: "Asterism node",   shape: "round-rectangle", color: "#2e7d32", size: 38 },
  a_app:     { label: "Asterism app",    shape: "hexagon",         color: "#00897b", size: 30 },
  a_object:  { label: "Asterism object", shape: "ellipse",         color: "#7cb342", size: 24 },
  r_node:    { label: "ROS 2 node",      shape: "round-rectangle", color: "#6a1b9a", size: 36 },
  r_topic:   { label: "ROS 2 topic",     shape: "tag",             color: "#ef6c00", size: 28 },
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
  publishes: "#ef6c00", subscribes: "#ef6c00", topic_link: "#ef6c00",
}

const BADGE = { services: "#c2185b", unmatched: "#ef6c00" }

const STATUS_TEXT = {
  ok: "ok", remote_error: "RemoteError", timeout: "TimeoutError", error: "error",
  expired: "expired", pending: "waiting for the bridge", running: "running", denied: "not permitted",
}

const LAYOUT = {
  name: "fcose", nodeDimensionsIncludeLabels: true, padding: 30,
  nodeRepulsion: () => 7000, edgeElasticity: () => 0.45, nestingFactor: 0.1, gravity: 0.25,
  idealEdgeLength: (e) => e.data("kind") === "topic_link" ? 150 : e.data("kind") === "carries" ? 90 : 70,
  nodeSeparation: 60, numIter: 2500, tilingPaddingVertical: 20, tilingPaddingHorizontal: 20,
}

const LEASE_EVERY = 10000

// Topics every rclcpp node has, hidden by default (rqt_graph's "Hide debug").
const DEBUG_TOPICS = ["/rosout", "/parameter_events"]
const isDebugTopic = (tid) => DEBUG_TOPICS.includes(String(tid).replace(/^r_topic:\d+/, ""))

// Same rule as CallPermission.match? (Ruby): * matches any run of characters.
function globMatch(pattern, value) {
  const re = new RegExp("^" + String(pattern).replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*") + "$")
  return re.test(String(value))
}

export default class extends Controller {
  static targets = ["graph", "details", "bridge", "counts", "watchList", "watchError", "legend", "rateStatus"]
  static values = { state: Object, watches: Array }

  connect() {
    this.version = this.stateValue.version || 0
    this.layers = { infra: true, asterism: true, ros: true, registry: true }
    this.topicsAsNodes = false
    this.showHz = true
    this.hideDebug = true
    this.measureAll = false
    this.rates = new Map(Object.entries(this.stateValue.rates || {}))
    this.rateState = null
    this.placed = new Set()      // node ids that have a position of their own
    this.pending = new Map()     // request id -> handler
    this.samples = new Map()     // watch id -> [sample, ...]
    this.watches = new Map()
    this.selected = null
    this.lastBeat = 0
    // The bars first: the graph is fitted to the room they leave.
    this.renderLegend()
    this.renderRateStatus()
    this.setupGraph(this.stateValue.graph)
    this.showBridge(this.stateValue.bridge || {})
    this.watchesValue.forEach((w) => this.watches.set(w.id, w))
    this.renderWatches()
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create("ConsoleChannel", {
      received: (msg) => this.received(msg),
      connected: () => this.refetch(),
    })
    this.beatTimer = setInterval(() => this.checkBeat(), 2000)
    this.leaseTimer = setInterval(() => this.renewLeases(), LEASE_EVERY)
  }

  disconnect() {
    clearInterval(this.beatTimer)
    clearInterval(this.leaseTimer)
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.cy?.destroy()
  }

  // ------------------------------------------------------------------ graph

  setupGraph(graph) {
    this.cy = cytoscape({
      container: this.graphTarget,
      elements: [],
      style: this.graphStyle(),
      layout: { name: "preset" },
    })
    this.cy.add(this.elementsOf(graph))
    this.cy.on("tap", "node", (ev) => this.select(ev.target.id()))
    this.cy.on("tap", "edge[kind = 'topic_link']", (ev) => this.select(ev.target.id()))
    this.cy.on("tap", (ev) => { if (ev.target === this.cy) this.select(null) })
    this.applyView()
    this.layoutAll()
    this.updateCounts()
    window.consoleGraph = this.cy // for the headless checks
    window.consoleController = this
  }

  graphStyle() {
    const s = [
      { selector: "node", style: {
          label: "data(label)", "font-size": 10, color: "#222", "text-valign": "bottom", "text-margin-y": 4,
          "text-wrap": "ellipsis", "text-max-width": 150, "border-width": 1, "border-color": "#fff" } },
      { selector: ".off", style: { display: "none" } },
      // Compound nodes: an Asterism node holds its apps, an app its objects.
      { selector: "node[kind = 'a_node']:parent", style: {
          "background-color": KINDS.a_node.color, "background-opacity": 0.07, "border-width": 2,
          "border-color": KINDS.a_node.color, padding: 14, "text-valign": "top", "text-margin-y": -4,
          "font-weight": "bold", color: "#1b5e20" } },
      { selector: "node[kind = 'a_app']:parent", style: {
          "background-color": KINDS.a_app.color, "background-opacity": 0.1, "border-width": 1.5,
          "border-style": "dashed", "border-color": KINDS.a_app.color, padding: 8, "text-valign": "top",
          "text-margin-y": -3, color: "#00695c", shape: "round-rectangle" } },
      { selector: "node[kind = 'a_object']", style: { "font-size": 9 } },
      { selector: "node[?self]", style: { "border-width": 3, "border-style": "dashed", "border-color": "#333" } },
      // A ROS 2 node's badge: its services, and its topics with no counterpart.
      { selector: "node[badge]", style: {
          "background-image": "data(badge)", "background-width": "data(badgeW)", "background-height": 14,
          "background-fit": "none", "background-clip": "none", "background-image-containment": "over",
          "background-position-x": "0%", "background-position-y": "0%", "background-offset-x": 24,
          "background-offset-y": -9, "bounds-expansion": 40, "background-image-smoothing": "yes" } },
      { selector: "node:selected", style: { "border-width": 4, "border-color": "#ffb300", "border-style": "solid" } },
      { selector: "edge", style: {
          width: 1.5, "curve-style": "bezier", "target-arrow-shape": "triangle", "arrow-scale": 0.8,
          "line-color": "#bbb", "target-arrow-color": "#bbb" } },
      { selector: "edge[kind = 'carries']", style: { "line-style": "dashed", width: 1 } },
      { selector: "edge[kind = 'session'], edge[kind = 'router_link']", style: { "target-arrow-shape": "none" } },
      { selector: "edge[kind = 'router_link']", style: { width: 3 } },
      { selector: "edge[kind = 'router_link'][label]", style: {
          label: "data(label)", "font-size": 9, color: "#1f4e99", "text-background-color": "#fff",
          "text-background-opacity": 1, "text-background-padding": 2 } },
      { selector: "edge[kind = 'topic_link']", style: {
          width: 2, label: "data(label)", "font-size": 8, color: "#8a3c00", "text-wrap": "wrap",
          "text-background-color": "#fff", "text-background-opacity": 0.85, "text-background-padding": 1,
          "control-point-step-size": 50, "arrow-scale": 1 } },
      { selector: "edge[kind = 'topic_link']:selected", style: { width: 4, "line-color": "#ffb300", "target-arrow-color": "#ffb300" } },
      { selector: "node[registry = 'registered'], node[registry = 'disabled'], node[registry = 'unregistered']",
        style: { "underlay-opacity": 0.8, "underlay-padding": 8, "underlay-shape": "ellipse" } },
      { selector: "node[registry = 'registered']", style: { "underlay-color": REGISTRY.registered.color } },
      { selector: "node[registry = 'disabled']", style: { "underlay-color": REGISTRY.disabled.color } },
      { selector: "node[registry = 'unregistered']", style: { "underlay-color": REGISTRY.unregistered.color } },
      // A compound node shows its registry mark as its border (the halo would
      // cover its contents).
      { selector: "node:parent[registry = 'registered'], node:parent[registry = 'disabled'], node:parent[registry = 'unregistered']",
        style: { "underlay-opacity": 0, "border-width": 4 } },
      { selector: "node:parent[registry = 'registered']", style: { "border-color": REGISTRY.registered.color } },
      { selector: "node:parent[registry = 'disabled']", style: { "border-color": REGISTRY.disabled.color } },
      { selector: "node:parent[registry = 'unregistered']", style: { "border-color": REGISTRY.unregistered.color } },
      { selector: "node[kind = 'registered']", style: {
          "border-width": 2, "border-style": "dashed", "border-color": "#6b7280", "background-opacity": 0.5, color: "#555" } },
      { selector: "node.reg-off", style: { "underlay-opacity": 0 } },
      { selector: "node:parent.reg-off", style: { "border-width": 2, "border-color": KINDS.a_node.color } },
      { selector: ".flash", style: { "overlay-color": "#ffb300", "overlay-opacity": 0.35, "overlay-padding": 6 } },
    ]
    for (const [kind, k] of Object.entries(KINDS)) {
      s.splice(1, 0, { selector: `node[kind = '${kind}']`,
                       style: { shape: k.shape, "background-color": k.color, width: k.size, height: k.size } })
    }
    for (const [kind, c] of Object.entries(EDGE_COLORS)) {
      s.push({ selector: `edge[kind = '${kind}']`, style: { "line-color": c, "target-arrow-color": c } })
    }
    // Last, so they win over the kinds' colours.
    s.push({ selector: "edge[kind = 'topic_link']:selected", style: { "line-color": "#ffb300", "target-arrow-color": "#ffb300" } })
    return s
  }

  // Parents before their children (cytoscape needs the parent to exist).
  elementsOf(graph) {
    const depth = (n) => n.kind === "a_object" ? 2 : n.kind === "a_app" ? 1 : 0
    const nodes = [...(graph.nodes || [])].sort((a, b) => depth(a) - depth(b)).map((n) => this.nodeElement(n))
    const edges = (graph.edges || []).map((e) => this.edgeElement(e))
    return nodes.concat(edges)
  }

  nodeElement(n) {
    let label = n.data?.self ? `${n.label} (this console)` : n.label
    if (n.kind === "registered") label = `${n.label} (registered, not here)`
    const data = { id: n.id, kind: n.kind, layer: n.layer, label, name: n.label, self: !!n.data?.self, info: n.data }
    if (n.parent) data.parent = n.parent
    if (n.data?.registry) data.registry = n.data.registry
    if (n.kind === "r_node") Object.assign(data, badgeOf(n.data, this.hideDebug))
    if (n.kind === "r_topic") data.label = this.topicNodeLabel(n.id, n.label)
    return { group: "nodes", data, classes: `layer-${n.layer}` }
  }

  edgeElement(e) {
    const data = { id: e.id, kind: e.kind, layer: e.layer, source: e.source, target: e.target }
    if (e.label) data.label = e.label
    if (e.topics) {
      data.topics = e.topics
      data.label = this.topicEdgeLabel(e.topics)
    }
    return { group: "edges", data }
  }

  // A topic edge's label: its topics' names, with their rates.
  topicEdgeLabel(topics) {
    return this.shownTopics(topics).map((tid) => {
      const name = tid.replace(/^r_topic:\d+/, "")
      return this.showHz && this.rates.get(tid)?.hz != null ? `${name}  ${fmtHz(this.rates.get(tid).hz)}` : name
    }).join("\n")
  }

  shownTopics(topics) {
    return (topics || []).filter((t) => !(this.hideDebug && isDebugTopic(t)))
  }

  topicNodeLabel(tid, name) {
    const r = this.rates.get(tid)
    return this.showHz && r?.hz != null ? `${name} ${fmtHz(r.hz)}` : name
  }

  // Labels that carry rates, after the rates or the Hz setting changed.
  refreshRateLabels(tids = null) {
    const want = tids ? new Set(tids) : null
    this.cy.batch(() => {
      this.cy.edges("[kind = 'topic_link']").forEach((e) => {
        if (!want || e.data("topics").some((t) => want.has(t))) e.data("label", this.topicEdgeLabel(e.data("topics")))
      })
      this.cy.nodes("[kind = 'r_topic']").forEach((n) => {
        if (!want || want.has(n.id())) n.data("label", this.topicNodeLabel(n.id(), n.data("name")))
      })
    })
  }

  applyDiff(diff) {
    const cy = this.cy
    const added = []
    cy.batch(() => {
      for (const id of diff.remove_edges) cy.getElementById(id).remove()
      for (const id of diff.remove_nodes) { cy.getElementById(id).remove(); this.placed.delete(id) }
      for (const el of this.elementsOf({ nodes: diff.add_nodes })) {
        if (el.data.parent && cy.getElementById(el.data.parent).empty()) delete el.data.parent
        added.push(cy.add(el))
      }
      for (const n of diff.change_nodes) {
        const el = cy.getElementById(n.id)
        if (el.empty()) continue
        const fresh = this.nodeElement(n).data
        el.data({ label: fresh.label, name: fresh.name, info: fresh.info, self: fresh.self, registry: fresh.registry })
        if (fresh.kind === "r_node") this.setBadge(el)
      }
      for (const e of diff.add_edges) {
        if (cy.getElementById(e.source).nonempty() && cy.getElementById(e.target).nonempty()) cy.add(this.edgeElement(e))
      }
      for (const e of diff.change_edges || []) {
        const el = cy.getElementById(e.id)
        if (el.empty()) continue
        const fresh = this.edgeElement(e).data
        el.data({ label: fresh.label, topics: fresh.topics })
      }
    })
    this.applyView()
    for (const el of added) {
      el.addClass("flash")
      setTimeout(() => el.removeClass("flash"), 1500)
    }
    this.settle()
    this.updateCounts()
    if (this.selected) {
      const sel = cy.getElementById(this.selected)
      // An object's details hold its methods and call results: redrawn only
      // when the object itself changed.
      if (sel.empty()) this.showGone(this.selected)
      else if (sel.data("kind") !== "a_object" || diff.change_nodes.some((n) => n.id === this.selected)) this.refreshDetails()
    }
  }

  // The whole graph again (the page missed a diff): what is still there
  // keeps its place.
  replaceGraph(payload) {
    this.version = payload.version
    const keep = new Map()
    this.cy.nodes().forEach((n) => { if (this.placed.has(n.id())) keep.set(n.id(), { ...n.position() }) })
    this.cy.elements().remove()
    this.placed.clear()
    this.cy.add(this.elementsOf(payload.graph))
    for (const [id, p] of keep) {
      const n = this.cy.getElementById(id)
      if (n.nonempty() && n.isChildless()) { n.position(p); this.placed.add(id) }
    }
    this.applyView()
    if (this.placed.size === 0) this.layoutAll()
    else this.settle()
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

  visible() {
    return this.cy.elements().not(".off")
  }

  // Everything from scratch ("Lay out again", the first graph).
  layoutAll() {
    const eles = this.visible()
    if (eles.empty()) return
    try {
      eles.layout({ ...LAYOUT, quality: "default", randomize: true, animate: false, fit: true }).run()
    } catch (e) {
      console.warn("layout", e)
      eles.layout({ name: "cose", animate: false, fit: true, nodeDimensionsIncludeLabels: true }).run()
    }
    eles.nodes().forEach((n) => this.placed.add(n.id()))
  }

  relayout() {
    this.layoutAll()
  }

  // Places the visible nodes that have no place yet: next to the placed
  // nodes they connect to (or their parent's other children), then a short
  // layout that holds every placed node where it is.
  settle() {
    const eles = this.visible()
    const fresh = eles.nodes().filter((n) => !this.placed.has(n.id()))
    if (fresh.empty()) return
    const placed = eles.nodes().filter((n) => this.placed.has(n.id()) && n.isChildless())
    if (placed.empty()) return this.layoutAll()
    // Nodes given a place in this pass count as placed for the ones after
    // them: a whole board that comes back (node, app and objects in one
    // diff) is put together in one spot instead of each object on its own.
    const now = new Set()
    const isPlaced = (x) => this.placed.has(x.id()) || now.has(x.id())
    const spots = new Map() // outermost box => where its first child went
    const grids = new Map() // first child of a box new as a whole => [[node, offset]]
    fresh.filter((n) => n.isChildless()).forEach((n) => {
      now.add(n.id())
      // In a box with placed siblings: next to them, inside the box.
      const siblings = n.parent().nonempty() ? n.parent().children().filter((x) => x !== n && isPlaced(x)) : n.parent()
      if (siblings.nonempty() && siblings.every((x) => now.has(x.id()))) {
        // A box that is new as a whole: two to a row, as fcose draws them.
        const k = siblings.length
        const off = { x: (k % 2) * 50, y: Math.floor(k / 2) * 55 }
        const first = siblings.first()
        const p0 = first.position()
        n.position({ x: p0.x + off.x, y: p0.y + off.y })
        if (!grids.has(first.id())) grids.set(first.id(), [[first, { x: 0, y: 0 }]])
        grids.get(first.id()).push([n, off])
        return
      }
      if (siblings.nonempty()) {
        const bb = siblings.boundingBox({ includeLabels: false })
        n.position({ x: bb.x2 + 18, y: (bb.y1 + bb.y2) / 2 })
        return
      }
      let near = n.neighborhood("node").filter((x) => isPlaced(x) && !x.hasClass("off"))
      if (near.empty() && n.parent().nonempty()) near = n.parent().descendants().filter((x) => x !== n && isPlaced(x))
      if (near.empty()) near = n.ancestors().neighborhood("node").filter((x) => isPlaced(x) && x.isChildless())
      const box = n.ancestors().last()
      let p
      if (near.nonempty()) {
        const xs = near.map((x) => x.position())
        p = { x: xs.reduce((a, q) => a + q.x, 0) / xs.length, y: xs.reduce((a, q) => a + q.y, 0) / xs.length }
      } else if (box.nonempty() && spots.has(box.id())) {
        p = spots.get(box.id())
      } else {
        // Nothing to go next to: beside the drawing, but inside the view
        // (the view does not move, so a node placed past it is not seen).
        const bb = placed.boundingBox()
        const ext = this.cy.extent()
        p = { x: Math.max(Math.min(bb.x2 + 80, ext.x2 - 120), ext.x1 + 60), y: (bb.y1 + bb.y2) / 2 }
      }
      if (box.nonempty() && !spots.has(box.id())) spots.set(box.id(), p)
      n.position({ x: p.x + (Math.random() - 0.5) * 60, y: p.y + (Math.random() - 0.5) * 60 })
    })
    const fixed = placed.map((n) => ({ nodeId: n.id(), position: { ...n.position() } }))
    try {
      eles.layout({ ...LAYOUT, quality: "proof", randomize: false, animate: false, fit: false,
                    fixedNodeConstraint: fixed, initialEnergyOnIncremental: 0.3 }).run()
      // fcose may move the whole drawing a little: move it back, so the
      // placed nodes stay exactly where they were.
      let dx = 0, dy = 0
      for (const f of fixed) {
        const p = this.cy.getElementById(f.nodeId).position()
        dx += p.x - f.position.x
        dy += p.y - f.position.y
      }
      dx /= fixed.length
      dy /= fixed.length
      this.cy.batch(() => {
        fresh.filter((n) => n.isChildless()).forEach((n) => { const p = n.position(); n.position({ x: p.x - dx, y: p.y - dy }) })
        for (const f of fixed) this.cy.getElementById(f.nodeId).position(f.position)
        // fcose spreads the children of a new box apart (nothing holds
        // them): keep the box where fcose put it, its children in the grid.
        for (const members of grids.values()) {
          const c = { x: 0, y: 0 }
          for (const [m, off] of members) { c.x += m.position().x - off.x; c.y += m.position().y - off.y }
          c.x /= members.length
          c.y /= members.length
          for (const [m, off] of members) m.position({ x: c.x + off.x, y: c.y + off.y })
        }
      })
      this.keepInView(fresh)
    } catch (e) {
      console.warn("layout", e)
    }
    fresh.forEach((n) => this.placed.add(n.id()))
  }

  // A new node (or box) that fcose pushed past the view is moved back
  // into it: the view does not follow, so it would not be seen. (After the
  // batch, where the boxes' bounds are up to date.)
  keepInView(fresh) {
    const e0 = this.cy.extent()
    const ext = { x1: e0.x1 + 20, x2: e0.x2 - 20, y1: e0.y1 + 20, y2: e0.y2 - 20, w: e0.w - 40, h: e0.h - 40 }
    const groups = new Map()
    fresh.filter((n) => n.isChildless()).forEach((n) => {
      const top = n.ancestors().last().nonempty() ? n.ancestors().last() : n
      groups.set(top.id(), top)
    })
    for (const top of groups.values()) {
      // Only what is new as a whole: a box with a placed node inside stays.
      if (top.descendants().some((x) => this.placed.has(x.id())) || this.placed.has(top.id())) continue
      const bb = top.boundingBox()
      const mx = bb.w > ext.w ? 0 : Math.min(0, ext.x2 - bb.x2) + Math.max(0, ext.x1 - bb.x1)
      const my = bb.h > ext.h ? 0 : Math.min(0, ext.y2 - bb.y2) + Math.max(0, ext.y1 - bb.y1)
      if (mx || my) {
        const kids = top.isChildless() ? top : top.descendants().filter((x) => x.isChildless())
        kids.forEach((k) => { const q = k.position(); k.position({ x: q.x + mx, y: q.y + my }) })
      }
    }
  }

  toggleLayer(ev) {
    this.layers[ev.target.dataset.layer] = ev.target.checked
    this.applyView()
    this.settle()
    this.updateCounts()
  }

  toggleTopicNodes(ev) {
    this.topicsAsNodes = ev.target.checked
    this.applyView()
    this.settle()
    this.updateCounts()
    if (this.selected) this.refreshDetails()
  }

  toggleDebug(ev) {
    this.hideDebug = ev.target.checked
    this.cy.batch(() => this.cy.nodes("[kind = 'r_node']").forEach((n) => this.setBadge(n)))
    this.refreshRateLabels()
    this.applyView()
    this.settle()
    if (this.selected) this.refreshDetails()
  }

  setBadge(n) {
    const b = badgeOf(n.data("info"), this.hideDebug)
    if (b.badge) n.data(b)
    else n.removeData("badge badgeW")
  }

  toggleHz(ev) {
    this.showHz = ev.target.checked
    this.refreshRateLabels()
  }

  toggleMeasure(ev) {
    this.measureAll = ev.target.checked
    this.renewLeases()
    this.renderRateStatus()
  }

  // Which elements show: the layers, the registry halo, and topics as
  // edges (between nodes) or as nodes.
  applyView() {
    const ros = this.layers.ros
    this.cy.batch(() => {
      this.cy.nodes().forEach((n) => {
        let shown = this.layers[n.data("layer")]
        if (n.data("kind") === "registered") shown = shown && this.layers.registry
        if (n.data("kind") === "r_topic") shown = shown && this.topicsAsNodes && !(this.hideDebug && isDebugTopic(n.id()))
        n.toggleClass("off", !shown)
        n.toggleClass("reg-off", !this.layers.registry)
      })
      this.cy.edges().forEach((e) => {
        const k = e.data("kind")
        let shown = true
        if (k === "topic_link") shown = ros && !this.topicsAsNodes && this.shownTopics(e.data("topics")).length > 0
        if (k === "publishes" || k === "subscribes") shown = ros && this.topicsAsNodes
        if (e.source().hasClass("off") || e.target().hasClass("off")) shown = false
        e.toggleClass("off", !shown)
      })
    })
  }

  updateCounts() {
    const by = {}
    let services = 0
    this.cy.nodes().forEach((n) => {
      by[n.data("kind")] = (by[n.data("kind")] || 0) + 1
      if (n.data("kind") === "r_node") services += (n.data("info").services || []).length
    })
    const parts = Object.keys(KINDS).filter((k) => by[k]).map((k) => `${KINDS[k].label}: ${by[k]}`)
    if (services) parts.push(`ROS 2 service: ${services}`)
    this.countsTarget.textContent = `v${this.version}  ${parts.join("  ")}`
  }

  renderLegend() {
    const badge = (c, t) => `<span class="pill" style="background:${c}">${t}</span>`
    this.legendTarget.innerHTML = Object.values(KINDS).map((k) =>
      `<span class="key"><span class="swatch shape-${k.shape}" style="background:${k.color}"></span>${k.label}</span>`
    ).join("") +
      `<span class="key"><span class="swatch line" style="background:${EDGE_COLORS.topic_link}"></span>topic, publisher to subscriber</span>` +
      `<span class="key">${badge(BADGE.services, "7")} services</span>` +
      `<span class="key">${badge(BADGE.unmatched, "2")} topics with no counterpart</span>` +
      `<span class="key"><span class="swatch dashed"></span>this console</span>` +
      Object.values(REGISTRY).filter((r) => r !== REGISTRY.absent).map((r) =>
        `<span class="key"><span class="swatch halo" style="box-shadow: 0 0 0 3px ${r.color}"></span>${r.label}</span>`).join("")
  }

  // ----------------------------------------------------------------- rates

  // Asks the bridge to go on measuring (RateLease): all topics while the
  // box is ticked, and the topics of the selected node or edge.
  renewLeases() {
    const keys = new Set(this.selectedTopics())
    if (this.measureAll) keys.add("*")
    for (const topic of keys) {
      fetch("/rates", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
        body: JSON.stringify({ topic }),
      }).catch(() => {})
    }
  }

  selectedTopics() {
    const el = this.selected && this.cy.getElementById(this.selected)
    if (!el || el.empty()) return []
    if (el.data("kind") === "r_topic") return [el.id()]
    // The debug topics only while they are shown: measuring a hidden
    // topic costs its traffic for nothing.
    if (el.data("kind") === "topic_link") return this.shownTopics(el.data("topics"))
    return []
  }

  receivedRates(msg) {
    const changed = Object.keys(msg.rates || {})
    for (const [tid, r] of Object.entries(msg.rates || {})) this.rates.set(tid, r)
    if (msg.status) this.rateState = msg.status
    this.renderRateStatus()
    if (changed.length) this.refreshRateLabels(changed)
    const sel = this.selected && this.cy.getElementById(this.selected)
    if (sel && sel.nonempty() && ["r_topic", "topic_link"].includes(sel.data("kind")) &&
        this.selectedTopics().some((t) => changed.includes(t))) this.refreshDetails()
  }

  renderRateStatus() {
    if (!this.hasRateStatusTarget) return
    const s = this.rateState
    let text
    if (s?.paused_s > 0) text = `all topics paused for ${s.paused_s} s (over ${fmtBytes(s.limit_bps)}/s)`
    else if (s?.measuring?.length) text = `measuring ${s.measuring.join(", ")} (${s.topics} topics)`
    else if (this.measureAll) text = "asking the bridge..."
    else text = this.rates.size ? "rates as last measured" : ""
    this.rateStatusTarget.textContent = text
  }

  rateRows(tid) {
    const r = this.rates.get(tid)
    if (!r) return [["Rate", "not measured (tick \"Measure all topics\", or keep this open)"]]
    const ago = r.at ? `${fmtAgo(Date.now() - r.at)} ago` : ""
    return [
      ["Rate", r.hz != null ? fmtHz(r.hz) : "..."],
      ["Bandwidth", r.bps != null ? `${fmtBytes(r.bps)}/s` : "..."],
      ["Messages", `${r.count}${r.size != null ? `, last ${fmtBytes(r.size)}` : ""}`],
      ["Last", r.text != null ? `<span class="hint">${esc(ago)}</span><br><code class="wrap">${esc(shorten(r.text, 300))}</code>` : esc(ago), true],
    ]
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
      case "rates": this.receivedRates(msg); break
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
    el.textContent = b.alive ? `bridge: ${b.node || "?"} on ${b.router || "?"}${b.connections === 0 ? " (no router connected)" : ""}` : "bridge: not running (start bin/bridge)"
  }

  checkBeat() {
    if (this.lastBeat && Date.now() - this.lastBeat > 10000) this.showBridge({ alive: false })
  }

  // --------------------------------------------------------------- details

  select(id) {
    this.selected = id
    this.refreshDetails()
    if (this.selectedTopics().length) this.renewLeases()
  }

  showGone(id) {
    this.detailsTarget.innerHTML = `<h2>Details</h2><p class="hint">${esc(id)} has left the network.</p>`
  }

  // A link that selects a node or edge (topics, nodes) in the details.
  link(id, text) {
    return `<a href="#" data-select="${esc(id)}">${esc(text)}</a>`
  }

  topicsOf(id, role) {
    return this.cy.nodes("[kind = 'r_topic']").filter((t) => (t.data("info")[role] || []).includes(id))
  }

  refreshDetails() {
    const id = this.selected
    if (!id) {
      this.detailsTarget.innerHTML = `<h2>Details</h2><p class="hint">Click a node or a topic edge in the graph.</p>`
      return
    }
    const el = this.cy.getElementById(id)
    if (el.empty()) return this.showGone(id)
    if (el.isEdge()) return this.edgeDetails(el)
    const kind = el.data("kind")
    const info = el.data("info") || {}
    const k = KINDS[kind]
    let html = `<h2><span class="swatch" style="background:${k.color}"></span>${esc(k.label)}</h2>`
    html += `<p class="name">${esc(el.data("name") || el.data("label"))}</p>`
    const rows = []
    const names = (sel) => el.connectedEdges(sel).map((e) => e.source().id() === id ? e.target() : e.source())
    const nodeLabel = (nid) => this.cy.getElementById(nid).data("name") || nid
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
                  ["Carries", names("[kind = 'carries']").map((n) => this.link(n.id(), n.data("name"))).join(", "), true])
        break
      case "a_node":
        rows.push(["ID", info.node],
                  ["Apps", el.children().map((a) =>
                    `${this.link(a.id(), a.data("name"))}: ${a.children().map((o) => this.link(o.id(), o.data("name"))).join(", ")}`
                  ).join("<br>") || "none", true],
                  ["Session", names("[kind = 'carries']").map((n) => esc(n.data("label"))).join(", "), true])
        break
      case "a_app":
        rows.push(["Node", info.node],
                  ["Objects", el.children().map((n) => this.link(n.id(), n.data("name"))).join(", "), true])
        break
      case "a_object":
        rows.push(["Path", info.path])
        break
      case "r_node": {
        const topicList = (role, other) => this.topicsOf(id, role).filter((t) => !(this.hideDebug && isDebugTopic(t.id()))).map((t) => {
          const peers = (t.data("info")[other] || []).filter((x) => x !== id).map(nodeLabel)
          const r = this.rates.get(t.id())
          return `${this.link(t.id(), t.data("name"))}${r?.hz != null ? ` <span class="hint">${esc(fmtHz(r.hz))}</span>` : ""}` +
            (peers.length ? ` <span class="hint">${role === "publishers" ? "to" : "from"} ${esc(peers.join(", "))}</span>`
                          : ` <span class="hint">(no ${role === "publishers" ? "subscriber" : "publisher"})</span>`)
        }).join("<br>") || "none"
        rows.push(["Name", info.name], ["Session ID", info.zid], ["Domain", info.domain],
                  ["Session", names("[kind = 'carries']").map((n) => esc(n.data("label"))).join(", "), true],
                  ["Publishes", topicList("publishers", "subscribers"), true],
                  ["Subscribes", topicList("subscribers", "publishers"), true])
        break
      }
      case "r_topic": {
        rows.push(["Type", info.type], ["Domain", info.domain],
                  ["Publishers", (info.publishers || []).map((n) => this.link(n, nodeLabel(n))).join("<br>") || "none", true],
                  ["Subscribers", (info.subscribers || []).map((n) => this.link(n, nodeLabel(n))).join("<br>") || "none", true],
                  ...this.rateRows(id))
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
    html += dl(rows)
    if (kind === "r_node") html += `<p class="actions"><a class="button" href="/logs?node=${encodeURIComponent(loggerName(info.name))}" target="_blank" rel="noopener">Show its logs</a></p>`
    if (kind === "r_node") html += this.rosNodeExtras(info)
    if (kind === "a_object") html += `<div class="methods" data-role="methods"><p class="hint">Reading the exposed methods...</p></div><div class="results" data-role="results"></div>`
    if (kind === "r_topic") html += `<div class="row actions"><button type="button" data-watch="${esc(`${info.domain}${info.name}/**`)}">Watch its values</button>` +
      `${plotLink(id)}</div>`
    this.renderDetails(html)
    if (kind === "a_object") this.loadMeta(info.path)
  }

  // A ROS 2 node's attributes: topics nobody is at the other end of, the
  // services it serves (the parameter ones folded) and calls.
  rosNodeExtras(info) {
    let html = ""
    const all = info.unmatched || []
    const unmatched = all.filter((u) => !(this.hideDebug && isDebugTopic(u.topic)))
    const hidden = all.filter((u) => !unmatched.includes(u))
    if (unmatched.length) {
      html += `<h3><span class="pill" style="background:${BADGE.unmatched}">${unmatched.length}</span> Topics with no counterpart</h3><ul class="plain">` +
        unmatched.map((u) => `<li>${u.role} ${this.link(u.topic, u.name)} <span class="hint">${esc(u.type || "")}</span></li>`).join("") + "</ul>"
    }
    if (hidden.length) {
      html += `<p class="hint">Also ${hidden.map((u) => `${u.role} ${this.link(u.topic, u.name)}`).join(", ")} (debug topics, hidden).</p>`
    }
    const services = info.services || []
    const own = services.filter((s) => !s.parameter)
    const params = services.filter((s) => s.parameter)
    html += `<h3><span class="pill" style="background:${BADGE.services}">${services.length}</span> Services</h3>`
    html += own.length ? `<ul class="plain">${own.map((s) => `<li><code>${esc(s.name)}</code> <span class="hint">${esc(s.type)}</span></li>`).join("")}</ul>`
                       : `<p class="hint">${services.length ? "Only the parameter services." : "None."}</p>`
    if (params.length) {
      html += `<details><summary>Parameter services (${params.length})</summary><ul class="plain">` +
        params.map((s) => `<li><code>${esc(s.name)}</code> <span class="hint">${esc(s.type)}</span></li>`).join("") + "</ul></details>"
    }
    const clients = info.clients || []
    if (clients.length) {
      html += `<h3>Calls</h3><ul class="plain">${clients.map((s) => `<li><code>${esc(s.name)}</code> <span class="hint">${esc(s.type)}</span></li>`).join("")}</ul>`
    }
    return html
  }

  // A topic edge: the topics from one node to the other, each with its
  // rate and last value (like rqt_topic).
  edgeDetails(el) {
    const from = el.source().data("name")
    const to = el.target().data("name")
    let html = `<h2><span class="swatch line" style="background:${EDGE_COLORS.topic_link}"></span>Topics</h2>`
    html += `<p class="name">${this.link(el.source().id(), from)} &rarr; ${this.link(el.target().id(), to)}</p>`
    const shown = this.shownTopics(el.data("topics"))
    for (const tid of shown) {
      const t = this.cy.getElementById(tid)
      const info = t.data("info") || {}
      html += `<h3>${this.link(tid, t.data("name") || tid)}</h3>`
      html += dl([["Type", info.type], ...this.rateRows(tid)])
      const pubs = (info.publishers || []).length
      // rmw_zenoh's data keys do not name the publisher, so a topic's rate
      // is of all its publishers, not of this edge's alone.
      if (pubs > 1) html += `<p class="hint">Rate and messages count all ${pubs} publishers of the topic.</p>`
      html += `<div class="row actions"><button type="button" class="small" data-watch="${esc(`${info.domain}${info.name}/**`)}">Watch its values</button>${plotLink(tid, true)}</div>`
    }
    const hidden = el.data("topics").filter((tid) => !shown.includes(tid))
    if (hidden.length) {
      html += `<p class="hint">Also ${hidden.map((tid) => this.link(tid, this.cy.getElementById(tid).data("name") || tid)).join(", ")} (debug topics, hidden).</p>`
    }
    this.renderDetails(html)
  }

  renderDetails(html) {
    this.detailsTarget.innerHTML = html
    this.detailsTarget.querySelectorAll("[data-select]").forEach((a) => a.addEventListener("click", (ev) => {
      ev.preventDefault()
      this.select(a.dataset.select)
    }))
    this.detailsTarget.querySelectorAll("[data-watch]").forEach((b) => b.addEventListener("click", () => this.watchKey(b.dataset.watch)))
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

// The badge of a ROS 2 node (an SVG image in the node's corner): the number
// of services it serves and of its topics with no counterpart.
function badgeOf(info, hideDebug) {
  const items = []
  const s = (info?.services || []).length
  const u = (info?.unmatched || []).filter((x) => !(hideDebug && isDebugTopic(x.topic))).length
  if (s) items.push([String(s), BADGE.services])
  if (u) items.push([String(u), BADGE.unmatched])
  if (!items.length) return {}
  let x = 0
  const parts = items.map(([text, color]) => {
    const w = 10 + 6.5 * text.length
    const svg = `<rect x="${x}" y="0" width="${w}" height="14" rx="7" fill="${color}" stroke="#fff" stroke-width="1"/>` +
      `<text x="${x + w / 2}" y="10.5" font-family="sans-serif" font-size="10" font-weight="bold" fill="#fff" text-anchor="middle">${text}</text>`
    x += w + 2
    return svg
  })
  const width = x - 2
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="14" viewBox="0 0 ${width} 14">${parts.join("")}</svg>`
  return { badge: `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`, badgeW: width }
}

// "Plot this topic": the plot page, in a tab of its own (the graph keeps its layout).
function plotLink(tid, small = false) {
  return `<a class="button${small ? " small" : ""}" href="/plots?topic=${encodeURIComponent(tid)}" target="_blank" rel="noopener">Plot this topic</a>`
}

// The logger name rclcpp gives a node: /ns/talker -> ns.talker.
function loggerName(node) {
  return String(node || "").replace(/^\//, "").replace(/\//g, ".")
}

function dl(rows) {
  return `<dl>${rows.filter(([, b]) => b !== null && b !== undefined).map(([a, b, raw]) =>
    `<dt>${esc(a)}</dt><dd>${raw ? (b || "") : esc(b ?? "")}</dd>`).join("")}</dl>`
}

function fmtHz(hz) {
  return hz >= 100 ? `${Math.round(hz)} Hz` : hz >= 10 ? `${hz.toFixed(1)} Hz` : `${hz.toFixed(2)} Hz`
}

function fmtBytes(n) {
  if (n == null) return "?"
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)} MB`
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)} KB`
  return `${n} B`
}

function fmtAgo(ms) {
  const s = Math.max(0, ms / 1000)
  if (s < 60) return `${s.toFixed(1)} s`
  if (s < 3600) return `${Math.round(s / 60)} min`
  return `${Math.round(s / 3600)} h`
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
