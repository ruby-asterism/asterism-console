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
// The graph (lib/bridge/graph.rb): by default each node (Asterism, ROS 2,
// this console) is joined to its router by a line that names its role
// (client / peer), and the sessions that carry no node are one "other
// connections" node per router (lib/bridge/connections.rb). "Sessions as
// points" draws each Zenoh session as a point between router and nodes
// instead, for finding out why something does not connect.
// Asterism apps and objects nest in their
// node (compound nodes); ROS 2 services are attributes of their node (a
// badge and the details); ROS 2 topics are edges from publisher to
// subscriber ("topic_link"), or, with "Topics as nodes", nodes between them
// as before. Positions stay where they are: only new nodes are placed
// (next to their neighbours, the others held fixed), and "Lay out again"
// lays out everything.
//
// Colour says which family a thing belongs to, shape says what it is
// (V2.2): blue the routers, purple ROS 2, orange the topics, Ruby red
// Asterism. The three levels of Asterism differ by shape: a node is a white
// box with a red border and a mark before its name for what it runs on
// (data "machine", lib/bridge/marks.rb), an app a grey dashed box, an
// object a small red dot.
//
// Profiles (V2.5, lib/bridge/profiles.rb): a node that tells its profile
// gets its kind (Family mruby, PicoRuby, CRuby, console) from it, and its
// icon (data "icon", /icons/<hash>) before its name in place of the mark;
// the mark of its kind is shown only when it has no icon. Its host and
// display name are in the details, and the display name also goes before
// the ID in the label (G1b). A node without a profile keeps the mark
// by its name (V2.2). The icon is a background image placed left of the
// label (applyIcons), since a label cannot hold an image.
//
// Machines (V2.3, lib/bridge/groups.rb): the ROS 2 nodes that come from the
// same IP address (two or more) are one "r_group" node, folded by default,
// named by its IP or by the machine name an admin gave it. Opening it (its
// details) shows its nodes instead (in a frame, below, not a compound box); the bridge
// sends folded copies of the edges, and an edge shows when both its ends
// show. Which groups are open this browser remembers.
//
// The frame of an open machine (V2.4): a rectangle around its nodes, with
// its name. Not a compound node (V2.1: a box let fcose swallow the
// drawing): a node of its own ("frame" class, kind "frame") that no layout
// sees, drawn under everything, sized and moved here to the bounds of the
// machine's nodes whenever one of them moves (syncFrames). Clicking it
// selects the machine. When a machine opens, and on "Lay out again", its
// nodes are laid out on their own first and kept together (layoutAll,
// openGroup).
//
// The relay registry ("Relay registry", off by default and
// remembered by this browser) adds a mark in the corner of the nodes and
// routers it knows of, and puts the names it has that are not here in one
// "Not connected (registry)" box, with a dashed line to the router the
// registry says they connect to when it tells.
//
// Replay mode (replay: true, the graph rewind of a recording): no
// connection to the bridge, no leases, no watches, no calls; the rewind
// controller hands it graphs (showRecorded) and the differences are applied
// as the live diffs are, so what stays keeps its place.

// The one colour of each family, and the neutral grey of the rest.
const ROUTER_BLUE = "#1f4e99"
const RUBY = "#cc342d"
const GREY = "#8a8f98"

const KINDS = {
  router:    { label: "Router",          shape: "diamond",         color: ROUTER_BLUE, size: 46 },
  session:   { label: "Session",         shape: "ellipse",         color: GREY, size: 22 },
  a_node:    { label: "Asterism node",   shape: "round-rectangle", color: "#ffffff", border: RUBY, size: 38 },
  a_app:     { label: "Asterism app",    shape: "round-rectangle", color: "#ffffff", border: GREY, dashed: true, size: 30 },
  a_object:  { label: "Asterism object", shape: "ellipse",         color: RUBY, size: 14 },
  r_node:    { label: "ROS 2 node",      shape: "round-rectangle", color: "#6a1b9a", size: 36 },
  r_group:   { label: "ROS 2 machine (folded)", shape: "round-rectangle", color: "#6a1b9a", border: "#6a1b9a", double: true, size: 50 },
  r_topic:   { label: "ROS 2 topic",     shape: "tag",             color: "#ef6c00", size: 28 },
  others:    { label: "Other connections", shape: "round-rectangle", color: GREY, size: 20 },
  reg_box:   { label: "Not connected (registry)", shape: "round-rectangle", color: "#f1f3f4", border: "#c4c7cc", size: 30 },
  registered: { label: "Registered, not connected", shape: "round-rectangle", color: "#e8eaed", border: "#9aa0a6", size: 22 },
}

// What an Asterism node runs on (data "machine"): the mark before its name.
// Plain characters of the Geometric Shapes block (no emoji).
// The keys are the profiles' kinds (V2.5; before, "board" and "ruby").
const MACHINES = {
  family_mruby: { mark: "\u25A3", label: "Family mruby (a board, the sim or the browser build)" },
  picoruby:     { mark: "\u25A4", label: "PicoRuby" },
  cruby:        { mark: "\u25C8", label: "CRuby" },
  console:      { mark: "\u25CE", label: "console" },
}
// A kind this console does not know (a profile may tell any word).
const OTHER_MACHINE = { mark: "\u25C7", label: "another Ruby" }
const machineOf = (kind) => MACHINES[kind] || (kind ? { ...OTHER_MACHINE, label: kind } : null)
// How the mark is known (data "machine_by").
const MACHINE_BY = { profile: "told by its profile", name: "guessed from its name: no profile", self: "this console" }
// The size of a profile icon in the graph, and the room between it and the
// name.
const ICON_SIZE = 16
const ICON_GAP = 4
const ICON_PROPS = ["background-image", "background-width", "background-height", "background-fit", "background-clip",
                    "background-image-containment", "background-position-x", "background-position-y",
                    "background-offset-x", "background-offset-y", "bounds-expansion", "background-image-smoothing"]

// Shown only with "Sessions as points" / only without it.
const POINT_KINDS = ["session", "carries", "peer_session"]
const DIRECT_KINDS = ["others", "attach", "peer_link"]
// Shown only with the "Relay registry" layer.
const REGISTRY_KINDS = ["reg_box", "registered", "expect"]
const STORE_POINTS = "asterism.console.sessionPoints"
const STORE_REGISTRY = "asterism.console.registry"
const STORE_OPEN = "asterism.console.openGroups"

// The relay registry over the graph (W2): a mark in the corner of a node or
// router by how it matches the registry (V2.2; before, a coloured halo).
const REGISTRY = {
  registered:   { label: "registered", glyph: "check" },
  disabled:     { label: "disabled in the registry", glyph: "bar" },
  unregistered: { label: "not in the registry", glyph: "?" },
  absent:       { label: "registered, not connected" },
}
const MARK_SIZE = 14

const EDGE_COLORS = {
  session: "#9aa0a6", router_link: ROUTER_BLUE, carries: "#c0c4ca", attach: "#9aa0a6", peer_link: "#5c6bc0",
  peer_session: "#5c6bc0", expect: ROUTER_BLUE,
  publishes: "#ef6c00", subscribes: "#ef6c00", topic_link: "#ef6c00",
}

const BADGE = { services: "#455a64", unmatched: "#ef6c00" }

const STATUS_TEXT = {
  ok: "ok", remote_error: "RemoteError", timeout: "TimeoutError", error: "error",
  expired: "expired", pending: "waiting for the bridge", running: "running", denied: "not permitted",
}

const LAYOUT = {
  name: "fcose", nodeDimensionsIncludeLabels: true, padding: 30,
  nodeRepulsion: () => 7000, edgeElasticity: () => 0.45, nestingFactor: 0.1, gravity: 0.25,
  idealEdgeLength: (e) => e.data("kind") === "topic_link" ? 150 : ["carries", "attach"].includes(e.data("kind")) ? 90 : 70,
  nodeSeparation: 60, numIter: 2500, tilingPaddingVertical: 20, tilingPaddingHorizontal: 20,
}

const LEASE_EVERY = 10000

// The frame of an open machine: the room around its nodes (their labels
// and badges included), and how far other nodes are kept from it.
const FRAME_PAD = 14
const FRAME_CLEAR = 24
const FRAME_COLOR = "#6a1b9a"

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
  static values = { state: Object, watches: Array, replay: Boolean, admin: Boolean }

  connect() {
    this.version = this.stateValue.version || 0
    this.layers = { infra: true, asterism: true, ros: true, registry: loadFlag(STORE_REGISTRY) }
    this.topicsAsNodes = false
    this.showHz = true
    this.hideDebug = true
    this.measureAll = false
    this.sessionPoints = loadFlag(STORE_POINTS)
    this.openGroups = loadList(STORE_OPEN) // keys of the open groups (groupKey)
    const box = this.element.querySelector("input[name=session_points]")
    if (box) box.checked = this.sessionPoints
    const reg = this.element.querySelector("input[data-layer=registry]")
    if (reg) reg.checked = this.layers.registry
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
    this.shownGraph = this.stateValue.graph
    if (this.replayValue) return
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
    this.cy.on("tap", "node", (ev) => this.select(ev.target.hasClass("frame") ? ev.target.data("machine") : ev.target.id()))
    // A machine's frame follows its nodes (dragged, laid out, added).
    this.cy.on("position", "node", (ev) => { if (ev.target.data("group")) this.queueFrames() })
    this.cy.on("tap", "edge[kind = 'topic_link'], edge[kind = 'attach'], edge[kind = 'peer_link']", (ev) => this.select(ev.target.id()))
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
      // An Asterism node: white, a teal border, its name (after the mark of
      // what it runs on) in bold; with apps it holds them.
      { selector: "node[kind = 'a_node']", style: { "font-size": 12, "font-weight": "bold" } },
      { selector: "node[kind = 'a_node']:parent", style: {
          "background-color": "#fff", "background-opacity": 1, padding: 14, "text-valign": "top", "text-margin-y": -4 } },
      // An app: a grey dashed box, no colour; it holds its objects.
      { selector: "node[kind = 'a_app']:parent", style: {
          "background-opacity": 0, padding: 8, "text-valign": "top", "text-margin-y": -3, color: "#5f6368" } },
      { selector: "node[kind = 'a_object']", style: { "font-size": 9, "border-width": 0 } },
      // A machine of ROS 2 nodes, folded: a larger purple box with a second
      // outline around it (several nodes in one), its name in bold.
      { selector: "node[kind = 'r_group']", style: {
          "font-size": 11, "font-weight": "bold", "border-width": 0,
          "outline-width": 2, "outline-color": "#6a1b9a", "outline-offset": 3, "outline-style": "solid" } },
      // The registry's names that are not here, in one box.
      { selector: "node[kind = 'reg_box']", style: {
          padding: 12, "text-valign": "top", "text-margin-y": -3, color: "#5f6368", "font-style": "italic" } },
      { selector: "node[kind = 'registered']", style: { color: "#5f6368", "font-size": 9 } },
      { selector: "node[kind = 'registered'][regkind = 'router']", style: { shape: "diamond" } },
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
      { selector: "edge[kind = 'session'], edge[kind = 'router_link'], edge[kind = 'attach'], edge[kind = 'peer_link'], edge[kind = 'peer_session']",
        style: { "target-arrow-shape": "none" } },
      // A node's line to its router, with the role of its session(s).
      { selector: "edge[kind = 'attach'][label], edge[kind = 'peer_link'], edge[kind = 'peer_session']", style: {
          label: "data(label)", "font-size": 8, color: "#5f6368", "text-background-color": "#fff",
          "text-background-opacity": 0.85, "text-background-padding": 1 } },
      { selector: "edge[kind = 'peer_link'], edge[kind = 'peer_session']", style: { "line-style": "dashed", width: 2, color: "#3949ab" } },
      // Lighter than the topic edges: the topics are what the graph is about.
      { selector: "edge[kind = 'attach']", style: { width: 1.2, "line-opacity": 0.7 } },
      { selector: "edge[kind = 'attach']:selected, edge[kind = 'peer_link']:selected", style: { width: 3 } },
      { selector: "node[kind = 'others']", style: { "font-size": 9, color: "#555" } },
      { selector: "edge[kind = 'router_link']", style: { width: 3 } },
      { selector: "edge[kind = 'router_link'][label]", style: {
          label: "data(label)", "font-size": 9, color: "#1f4e99", "text-background-color": "#fff",
          "text-background-opacity": 1, "text-background-padding": 2 } },
      { selector: "edge[kind = 'topic_link']", style: {
          width: 2, label: "data(label)", "font-size": 8, color: "#8a3c00", "text-wrap": "wrap",
          "text-background-color": "#fff", "text-background-opacity": 0.85, "text-background-padding": 1,
          "control-point-step-size": 50, "arrow-scale": 1 } },
      { selector: "edge[kind = 'topic_link']:selected", style: { width: 4, "line-color": "#ffb300", "target-arrow-color": "#ffb300" } },
      // The registry's mark, in the top right corner (with the layer on).
      { selector: "node.reg-on[regmark]", style: {
          "background-image": "data(regmark)", "background-width": MARK_SIZE, "background-height": MARK_SIZE,
          "background-fit": "none", "background-clip": "none", "background-image-containment": "over",
          "background-position-x": "100%", "background-position-y": "0%", "background-offset-x": MARK_SIZE / 2,
          "background-offset-y": -MARK_SIZE / 2, "bounds-expansion": MARK_SIZE, "background-image-smoothing": "yes" } },
      // Where the registry expects a name that is not here to connect.
      { selector: "edge[kind = 'expect']", style: {
          "line-style": "dashed", width: 1.2, "line-opacity": 0.6, "target-arrow-shape": "triangle", "arrow-scale": 0.7 } },
      { selector: ".flash", style: { "overlay-color": "#ffb300", "overlay-opacity": 0.35, "overlay-padding": 6 } },
      // The frame of an open machine: under everything (edges too), its
      // name above its top left corner.
      { selector: "node.frame", style: {
          shape: "round-rectangle", width: "data(fw)", height: "data(fh)", "corner-radius": 10,
          "background-color": FRAME_COLOR, "background-opacity": 0.04,
          "border-width": 1.5, "border-color": FRAME_COLOR, "border-style": "solid", "border-opacity": 0.8,
          label: "data(label)", color: FRAME_COLOR, "font-size": 12, "font-weight": "bold",
          "text-valign": "top", "text-halign": "right", "text-margin-x": "data(lx)", "text-margin-y": -3,
          "text-max-width": 400, "text-events": "yes", "z-compound-depth": "bottom", "z-index": 0, "overlay-opacity": 0 } },
      { selector: "node.frame.chosen", style: { "border-width": 3, "border-color": "#ffb300", "border-opacity": 1 } },
    ]
    for (const [kind, k] of Object.entries(KINDS)) {
      const style = { shape: k.shape, "background-color": k.color, width: k.size, height: k.size }
      if (k.border && !k.double) Object.assign(style, { "border-width": k.dashed ? 1.5 : 2, "border-color": k.border, "border-style": k.dashed ? "dashed" : "solid" })
      s.splice(1, 0, { selector: `node[kind = '${kind}']`, style })
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
    const depth = (n) => n.kind === "a_object" ? 2 : n.kind === "a_app" || n.kind === "registered" ? 1 : 0
    const nodes = [...(graph.nodes || [])].sort((a, b) => depth(a) - depth(b)).map((n) => this.nodeElement(n))
    const edges = (graph.edges || []).map((e) => this.edgeElement(e))
    return nodes.concat(edges)
  }

  nodeElement(n) {
    let label = n.data?.self ? `${n.label} (this console)` : n.label
    // A display name the node's profile told goes before its ID (G1b): the
    // ID stays in the label, since calls, permissions and the registry use it.
    const shown = n.kind === "a_node" && !n.data?.self && n.data?.profile?.name
    if (shown && shown !== n.label) label = `${shown} (${n.label})`
    const machine = n.kind === "a_node" && machineOf(n.data?.machine)
    // A node's own icon stands for it; the mark is the fallback without one.
    if (machine && !n.data?.icon) label = `${machine.mark} ${label}`
    const data = { id: n.id, kind: n.kind, layer: n.layer, label, name: n.label, self: !!n.data?.self, info: n.data }
    if (n.parent) data.parent = n.parent
    if (n.data?.registry) data.registry = n.data.registry
    if (REGISTRY[n.data?.registry]?.glyph) data.regmark = registryMark(n.data.registry)
    if (n.kind === "registered") data.regkind = n.data?.peer?.kind
    if (n.kind === "r_node" || n.kind === "r_group") Object.assign(data, badgeOf(n.data, this.hideDebug))
    if (n.data?.group) data.group = n.data.group
    if (n.kind === "a_node" && n.data?.icon) data.icon = n.data.icon
    if (n.kind === "r_topic") data.label = this.topicNodeLabel(n.id, n.label)
    return { group: "nodes", data, classes: `layer-${n.layer}` }
  }

  edgeElement(e) {
    const data = { id: e.id, kind: e.kind, layer: e.layer, source: e.source, target: e.target }
    if (e.label) data.label = e.label
    if (e.sessions) Object.assign(data, { sessions: e.sessions, roles: e.roles, shared: e.shared })
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
        el.data({ label: fresh.label, name: fresh.name, info: fresh.info, self: fresh.self })
        for (const key of ["registry", "regmark", "regkind", "group", "icon"]) {
          if (fresh[key] === undefined) el.removeData(key)
          else el.data(key, fresh[key])
        }
        const parent = el.parent().nonempty() ? el.parent().id() : null
        if ((fresh.parent || null) !== parent && (!fresh.parent || cy.getElementById(fresh.parent).nonempty())) {
          el.move({ parent: fresh.parent || null })
        }
        if (fresh.kind === "r_node" || fresh.kind === "r_group") this.setBadge(el)
      }
      for (const e of diff.add_edges) {
        if (cy.getElementById(e.source).nonempty() && cy.getElementById(e.target).nonempty()) cy.add(this.edgeElement(e))
      }
      for (const e of diff.change_edges || []) {
        const el = cy.getElementById(e.id)
        if (el.empty()) continue
        const fresh = this.edgeElement(e).data
        el.data({ label: fresh.label, topics: fresh.topics, sessions: fresh.sessions, roles: fresh.roles, shared: fresh.shared })
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

  // Replay mode: shows a recorded graph. The first one is laid out from
  // scratch; after that only the difference is applied (new nodes flash).
  showRecorded(graph, version) {
    const diff = graphDiff(this.shownGraph, graph)
    this.shownGraph = graph
    this.version = version || 0
    if (this.cy.nodes().empty()) {
      this.cy.add(this.elementsOf(graph))
      this.applyView()
      this.layoutAll()
      this.updateCounts()
      return
    }
    this.applyDiff(diff)
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

  // What is drawn and laid out (the machines' frames are not laid out).
  visible() {
    return this.cy.elements().not(".off").not(".frame")
  }

  // Everything from scratch ("Lay out again", the first graph). An open
  // machine is kept together: its nodes are laid out on their own first;
  // then the whole graph is laid out with the machine folded, its box as
  // large as its nodes need (so the layout keeps the others out of that
  // room); then its nodes go where the box went.
  layoutAll() {
    const open = this.openMembers()
    const shapes = new Map()
    for (const [gid, members] of open) shapes.set(gid, this.layoutMembers(members))
    const keys = [...open.keys()].map((gid) => this.groupKey(this.cy.getElementById(gid)))
    if (keys.length) {
      this.openGroups = this.openGroups.filter((k) => !keys.includes(k))
      this.applyView()
      this.cy.batch(() => {
        for (const [gid, sh] of shapes) this.cy.getElementById(gid).style({ width: sh.w, height: sh.h, label: "" })
      })
    }
    const eles = this.visible()
    if (!eles.empty()) {
      try {
        eles.layout({ ...LAYOUT, quality: "default", randomize: true, animate: false, fit: !keys.length }).run()
      } catch (e) {
        console.warn("layout", e)
        eles.layout({ name: "cose", animate: false, fit: !keys.length, nodeDimensionsIncludeLabels: true }).run()
      }
      eles.nodes().forEach((n) => this.placed.add(n.id()))
    }
    if (!keys.length) return
    this.openGroups = [...new Set(this.openGroups.concat(keys))]
    this.cy.batch(() => {
      for (const [gid, sh] of shapes) {
        const g = this.cy.getElementById(gid)
        g.removeStyle("width height label")
        const c = g.position()
        for (const [m, off] of sh.offsets) { m.position({ x: c.x + off.x, y: c.y + off.y }); this.placed.add(m.id()) }
      }
    })
    this.applyView()
    for (const gid of open.keys()) this.clearFrame(gid)
    this.settle()
    this.cy.fit(this.visible(), 30)
  }

  // The nodes shown of each open machine: Map(group id => nodes).
  openMembers() {
    const out = new Map()
    if (!this.layers.ros) return out
    this.cy.nodes("[kind = 'r_group']").forEach((g) => {
      if (!this.isOpen(g.id())) return
      const members = this.cy.nodes().filter((n) => n.data("group") === g.id() && !n.hasClass("off"))
      if (members.nonempty()) out.set(g.id(), members)
    })
    return out
  }

  // A machine's nodes laid out on their own (the edges among them only),
  // around (0, 0): { w, h, offsets: [[node, offset from the middle]] }.
  layoutMembers(members) {
    const r = Math.max(90, members.length * 22)
    members.forEach((n, i) => {
      const a = (2 * Math.PI * i) / members.length
      n.position({ x: r * Math.cos(a), y: r * Math.sin(a) })
    })
    const inner = members.union(members.edgesWith(members).not(".off"))
    try {
      inner.layout({ ...LAYOUT, quality: "default", randomize: false, animate: false, fit: false,
                     idealEdgeLength: (e) => e.data("kind") === "topic_link" ? 110 : 70 }).run()
    } catch (e) {
      console.warn("layout", e)
    }
    const bb = this.frameBounds(members)
    const c = { x: (bb.x1 + bb.x2) / 2, y: (bb.y1 + bb.y2) / 2 }
    return { w: bb.x2 - bb.x1, h: bb.y2 - bb.y1,
             offsets: members.map((n) => [n, { x: n.position().x - c.x, y: n.position().y - c.y }]) }
  }

  // ------------------------------------------------------- machine frames

  // The bounds a frame draws around: each node's shape and label, its
  // badge, and FRAME_PAD of room (not the badge's bounds-expansion, which is
  // there for the renderer only).
  frameBounds(members) {
    let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity
    members.forEach((n) => {
      const p = n.position()
      const w = n.outerWidth() / 2
      const h = n.outerHeight() / 2
      const lb = n.boundingBox({ includeNodes: false, includeEdges: false, includeLabels: true, includeOverlays: false })
      const badge = n.data("badge") ? Number(n.data("badgeW") || 0) : 0
      x1 = Math.min(x1, p.x - w, Number.isFinite(lb.x1) ? lb.x1 : Infinity)
      x2 = Math.max(x2, p.x + w, p.x - w + 24 + badge, Number.isFinite(lb.x2) ? lb.x2 : -Infinity)
      y1 = Math.min(y1, p.y - h - (badge ? 9 : 0), Number.isFinite(lb.y1) ? lb.y1 : Infinity)
      y2 = Math.max(y2, p.y + h, Number.isFinite(lb.y2) ? lb.y2 : -Infinity)
    })
    return { x1: x1 - FRAME_PAD, y1: y1 - FRAME_PAD, x2: x2 + FRAME_PAD, y2: y2 + FRAME_PAD }
  }

  // Redraws the frames on the next frame of the browser (a drag moves a
  // node many times).
  queueFrames() {
    if (this.framesQueued) return
    this.framesQueued = true
    requestAnimationFrame(() => { this.framesQueued = false; this.syncFrames() })
  }

  // A frame for each open machine with nodes shown, around them; the
  // others' frames removed.
  syncFrames() {
    if (!this.cy || this.cy.destroyed()) return
    const open = this.openMembers()
    this.cy.batch(() => {
      this.cy.nodes(".frame").forEach((f) => { if (!open.has(f.data("machine"))) f.remove() })
      for (const [gid, members] of open) {
        const g = this.cy.getElementById(gid)
        const bb = this.frameBounds(members)
        const fw = bb.x2 - bb.x1
        const fh = bb.y2 - bb.y1
        const info = g.data("info") || {}
        const label = `${info.name || info.ip} (${members.length} ROS 2 nodes)`
        let f = this.cy.getElementById(`frame:${gid}`)
        if (f.empty()) {
          f = this.cy.add({ group: "nodes", data: { id: `frame:${gid}`, kind: "frame", machine: gid },
                            classes: "frame", selectable: false, grabbable: false })
        }
        f.data({ fw, fh, lx: 6 - fw, label })
        f.position({ x: (bb.x1 + bb.x2) / 2, y: (bb.y1 + bb.y2) / 2 })
        f.toggleClass("chosen", this.selected === gid)
      }
    })
  }

  // Moves the nodes that sit in a machine's frame (with FRAME_CLEAR of
  // room) out of it, each the shorter way out from the middle, and on in
  // that direction until it overlaps nothing else. Asterism nodes move with
  // their apps and objects; the machine's nodes and other machines' nodes
  // stay. only: move these (top-level) nodes only.
  clearFrame(gid, only = null) {
    const members = this.cy.nodes().filter((n) => n.data("group") === gid && !n.hasClass("off"))
    if (members.empty()) return
    const b0 = this.frameBounds(members)
    const R = { x1: b0.x1 - FRAME_CLEAR, y1: b0.y1 - FRAME_CLEAR - 16, x2: b0.x2 + FRAME_CLEAR, y2: b0.y2 + FRAME_CLEAR }
    const c = { x: (R.x1 + R.x2) / 2, y: (R.y1 + R.y2) / 2 }
    const hit = (a, b) => a.x2 > b.x1 && a.x1 < b.x2 && a.y2 > b.y1 && a.y1 < b.y2
    const tops = this.visible().nodes().filter((n) => n.parent().empty())
    const boxOf = (top) => {
      const b = top.boundingBox({ includeLabels: true, includeOverlays: false })
      return { x1: b.x1, y1: b.y1, x2: b.x2, y2: b.y2 }
    }
    const boxes = new Map(tops.map((t) => [t.id(), boxOf(t)]))
    tops.filter((n) => !n.data("group") && (!only || only.contains(n))).forEach((top) => {
      const b = boxes.get(top.id())
      if (!hit(b, R)) return
      const dx = (b.x1 + b.x2) / 2 - c.x
      const dy = (b.y1 + b.y2) / 2 - c.y
      const mx = dx >= 0 ? R.x2 - b.x1 : R.x1 - b.x2
      const my = dy >= 0 ? R.y2 - b.y1 : R.y1 - b.y2
      const horizontal = Math.abs(mx) <= Math.abs(my)
      const move = horizontal ? { x: mx, y: 0 } : { x: 0, y: my }
      const step = horizontal ? { x: Math.sign(mx) * 20, y: 0 } : { x: 0, y: Math.sign(my) * 20 }
      const at = () => ({ x1: b.x1 + move.x, y1: b.y1 + move.y, x2: b.x2 + move.x, y2: b.y2 + move.y })
      for (let i = 0; i < 60; i++) {
        const nb = at()
        const clash = [...boxes].some(([id, o]) => id !== top.id() && hit(nb, o))
        if (!clash) break
        move.x += step.x
        move.y += step.y
      }
      const leaves = top.isChildless() ? top : top.descendants().filter((x) => x.isChildless())
      this.cy.batch(() => leaves.forEach((k) => { const q = k.position(); k.position({ x: q.x + move.x, y: q.y + move.y }) }))
      boxes.set(top.id(), at())
    })
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
      // A new node is not put in an open machine's frame (it is not one of
      // its nodes): moved out of it.
      const tops = fresh.map((n) => n.ancestors().last().nonempty() ? n.ancestors().last() : n)
      for (const gid of this.openMembers().keys()) this.clearFrame(gid, this.cy.collection(tops))
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
    const layer = ev.target.dataset.layer
    this.layers[layer] = ev.target.checked
    this.applyView()
    this.settle()
    this.updateCounts()
    if (layer === "registry") {
      saveFlag(STORE_REGISTRY, this.layers.registry)
      this.renderLegend()
      if (this.selected) this.refreshDetails()
    }
  }

  // "Sessions as points": each Zenoh session as a point (V2's drawing), or
  // the nodes joined to their router directly (the default). Remembered by
  // this browser.
  toggleSessionPoints(ev) {
    this.sessionPoints = ev.target.checked
    saveFlag(STORE_POINTS, this.sessionPoints)
    this.applyView()
    this.settle()
    this.updateCounts()
    this.renderLegend()
    if (this.selected) this.refreshDetails()
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
    this.cy.batch(() => this.cy.nodes("[kind = 'r_node'], [kind = 'r_group']").forEach((n) => this.setBadge(n)))
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
    const folded = (gid) => !this.isOpen(gid)
    this.cy.batch(() => {
      this.cy.nodes().forEach((n) => {
        if (n.hasClass("frame")) return
        let shown = this.layers[n.data("layer")]
        if (n.data("kind") === "r_group") shown = shown && folded(n.id())
        if (n.data("group")) shown = shown && !folded(n.data("group"))
        if (n.data("kind") === "r_topic" && shown) shown = !this.insideFolded(n)
        if (REGISTRY_KINDS.includes(n.data("kind"))) shown = shown && this.layers.registry
        if (n.data("kind") === "r_topic") shown = shown && this.topicsAsNodes && !(this.hideDebug && isDebugTopic(n.id()))
        if (POINT_KINDS.includes(n.data("kind"))) shown = shown && this.sessionPoints
        if (DIRECT_KINDS.includes(n.data("kind"))) shown = shown && !this.sessionPoints
        n.toggleClass("off", !shown)
        n.toggleClass("reg-on", this.layers.registry)
      })
      this.applyIcons()
      this.cy.edges().forEach((e) => {
        const k = e.data("kind")
        let shown = true
        if (k === "topic_link") shown = ros && !this.topicsAsNodes && this.shownTopics(e.data("topics")).length > 0
        if (k === "publishes" || k === "subscribes") shown = ros && this.topicsAsNodes
        if (POINT_KINDS.includes(k)) shown = this.sessionPoints
        if (DIRECT_KINDS.includes(k)) shown = !this.sessionPoints
        if (REGISTRY_KINDS.includes(k)) shown = this.layers.registry
        if (e.source().hasClass("off") || e.target().hasClass("off")) shown = false
        e.toggleClass("off", !shown)
      })
    })
    this.syncFrames()
  }

  // ---------------------------------------------------------------- machines

  // What the open state of a group is remembered by: its machine name when
  // it has one (the IP may change), else its IP.
  groupKey(group) {
    const info = group.data("info") || {}
    return info.name_id ? `name:${info.name_id}` : `ip:${info.ip}`
  }

  // Whether a group is open (its nodes shown). A member whose group is not
  // in the graph shows.
  isOpen(gid) {
    const g = this.cy.getElementById(gid)
    if (g.empty()) return true
    return this.openGroups.includes(this.groupKey(g))
  }

  // A topic (as a node) whose publishers and subscribers are all in one
  // folded group: inside it, so not drawn (as the topic edges inside).
  insideFolded(topic) {
    const info = topic.data("info") || {}
    const ends = [...(info.publishers || []), ...(info.subscribers || [])]
    if (!ends.length) return false
    const groups = new Set(ends.map((id) => this.cy.getElementById(id).data("group") || id))
    if (groups.size !== 1) return false
    const gid = [...groups][0]
    return gid.startsWith("r_group:") && !this.isOpen(gid)
  }

  // Opens or folds a group (from its details, or a member's).
  toggleGroup(gid, open) {
    const g = this.cy.getElementById(gid)
    if (g.empty()) return
    const key = this.groupKey(g)
    this.openGroups = this.openGroups.filter((k) => k !== key)
    if (open) this.openGroups.push(key)
    saveList(STORE_OPEN, this.openGroups)
    const members = this.cy.nodes().filter((n) => n.data("group") === gid)
    if (open) this.openGroup(members.filter((n) => !this.placed.has(n.id())), g)
    else if (!this.placed.has(gid) && members.some((n) => this.placed.has(n.id()))) {
      // Folded for the first time here: where its nodes were.
      const ps = members.filter((n) => this.placed.has(n.id())).map((n) => n.position())
      g.position({ x: ps.reduce((a, p) => a + p.x, 0) / ps.length, y: ps.reduce((a, p) => a + p.y, 0) / ps.length })
      this.placed.add(gid)
    }
    this.applyView()
    this.settle()
    this.updateCounts()
    // The view follows when the nodes now shown go past it (the nodes
    // themselves stay where they are).
    const bb = this.visible().boundingBox()
    const ext = this.cy.extent()
    if (bb.x1 < ext.x1 || bb.x2 > ext.x2 || bb.y1 < ext.y1 || bb.y2 > ext.y2) this.cy.fit(this.visible(), 30)
    this.select(gid)
  }

  // A group's nodes, opened for the first time: laid out on their own
  // (kept together) where the group was, and what else sits there moved
  // out of their frame. The other nodes keep their places.
  openGroup(nodes, group) {
    if (nodes.empty()) return
    const c = this.placed.has(group.id()) ? { ...group.position() } : null
    if (!c) return // nothing to go by: settle places them
    nodes.removeClass("off")
    nodes.connectedEdges().forEach((e) => { if (nodes.contains(e.source()) && nodes.contains(e.target())) e.removeClass("off") })
    const sh = this.layoutMembers(nodes)
    this.cy.batch(() => {
      for (const [m, off] of sh.offsets) m.position({ x: c.x + off.x, y: c.y + off.y })
    })
    nodes.forEach((n) => this.placed.add(n.id()))
    this.applyView()
    this.clearFrame(group.id())
  }

  // The name of a group (admins): a new one, or a new name for the one it
  // has (its node names taken again). Empty: the name is removed.
  async saveName(gid, name) {
    const g = this.cy.getElementById(gid)
    if (g.empty()) return
    const info = g.data("info") || {}
    const status = this.detailsTarget.querySelector("[data-role=name-status]")
    const say = (t) => { if (status) status.textContent = t }
    name = String(name || "").trim()
    if (!name) return info.name_id ? this.removeName(gid) : null
    const body = JSON.stringify({ name, members: info.member_names || [] })
    const url = info.name_id ? `/machine_names/${info.name_id}` : "/machine_names"
    say("saving...")
    try {
      const res = await fetch(url, {
        method: info.name_id ? "PATCH" : "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
        body,
      })
      const out = await res.json().catch(() => ({}))
      if (!res.ok) return say((out.errors || [`not saved (${res.status})`]).join(", "))
      // The open state goes with the name from now on.
      this.rekeyOpen(g, `name:${out.id}`)
      say("saved: the graph shows it within a few seconds")
    } catch (e) {
      say(String(e))
    }
  }

  async removeName(gid) {
    const g = this.cy.getElementById(gid)
    const info = g.data("info") || {}
    if (!info.name_id) return
    const status = this.detailsTarget.querySelector("[data-role=name-status]")
    const res = await fetch(`/machine_names/${info.name_id}`, { method: "DELETE", headers: { "X-CSRF-Token": csrf() } })
    if (res.ok) this.rekeyOpen(g, `ip:${info.ip}`)
    if (status) status.textContent = res.ok ? "removed: the graph shows the IP within a few seconds" : `not removed (${res.status})`
  }

  // Keeps a group open (or folded) when the key it is remembered by changes.
  rekeyOpen(group, key) {
    const was = this.groupKey(group)
    if (!this.openGroups.includes(was)) return
    this.openGroups = this.openGroups.filter((k) => k !== was).concat([key])
    saveList(STORE_OPEN, this.openGroups)
  }

  updateCounts() {
    const by = {}
    let services = 0
    this.cy.nodes().forEach((n) => {
      if (["others", "reg_box", "frame"].includes(n.data("kind"))) return
      if (n.data("kind") === "r_group" && !this.layers.ros) return
      if (n.data("kind") === "registered" && !this.layers.registry) return
      by[n.data("kind")] = (by[n.data("kind")] || 0) + 1
      if (n.data("kind") === "r_node") services += (n.data("info").services || []).length
    })
    const parts = Object.keys(KINDS).filter((k) => by[k]).map((k) => `${KINDS[k].label}: ${by[k]}`)
    if (services) parts.push(`ROS 2 service: ${services}`)
    this.countsTarget.textContent = `v${this.version}  ${parts.join("  ")}`
  }

  // The profile icons (V2.5): left of each Asterism node's name, above the
  // box when it holds apps (the name is above it), below it otherwise. A
  // style bypass, because the position depends on the label's width and
  // the registry's corner mark (also a background image) has to go in the
  // same arrays.
  applyIcons() {
    this.cy.nodes("[kind = 'a_node']").forEach((n) => {
      const icon = n.data("icon")
      if (!icon) {
        if (n.scratch("iconStyled")) {
          n.removeStyle(ICON_PROPS.join(" "))
          n.removeScratch("iconStyled")
        }
        return
      }
      const w = labelWidth(n.data("label"))
      const top = n.isParent()
      const img = { url: icon, x: "50%", y: top ? "0%" : "100%", dx: -(w / 2 + ICON_GAP + ICON_SIZE / 2),
                    dy: top ? -(ICON_SIZE + 4) : ICON_SIZE + 3, size: ICON_SIZE }
      const imgs = [img]
      if (n.hasClass("reg-on") && n.data("regmark")) {
        imgs.push({ url: n.data("regmark"), x: "100%", y: "0%", dx: MARK_SIZE / 2, dy: -MARK_SIZE / 2, size: MARK_SIZE })
      }
      const side = Math.max(MARK_SIZE, w / 2 + ICON_GAP + ICON_SIZE + 4 - n.width() / 2)
      n.style({
        "background-image": imgs.map((i) => i.url), "background-width": imgs.map((i) => i.size),
        "background-height": imgs.map((i) => i.size), "background-fit": imgs.map(() => "none"),
        "background-clip": imgs.map(() => "none"), "background-image-containment": imgs.map(() => "over"),
        "background-position-x": imgs.map((i) => i.x), "background-position-y": imgs.map((i) => i.y),
        "background-offset-x": imgs.map((i) => i.dx), "background-offset-y": imgs.map((i) => i.dy),
        "bounds-expansion": [ICON_SIZE + 6, side], "background-image-smoothing": imgs.map(() => "yes"),
      })
      n.scratch("iconStyled", true)
    })
  }

  renderLegend() {
    const badge = (c, t) => `<span class="pill" style="background:${c}">${t}</span>`
    const kinds = Object.entries(KINDS).filter(([kind]) => kind !== (this.sessionPoints ? "others" : "session") &&
                                                (this.layers.registry || !REGISTRY_KINDS.includes(kind))).map(([, k]) => k)
    const lines = this.sessionPoints
      ? `<span class="key"><span class="swatch line" style="background:${EDGE_COLORS.session}"></span>session at a router</span>` +
        `<span class="key"><span class="swatch line dashed-line" style="border-color:${EDGE_COLORS.carries}"></span>what a session carries</span>`
      : `<span class="key"><span class="swatch line" style="background:${EDGE_COLORS.attach}"></span>connection to the router (client / peer)</span>` +
        `<span class="key"><span class="swatch line dashed-line" style="border-color:${EDGE_COLORS.peer_link}"></span>peer to peer, no router</span>`
    const registry = this.layers.registry
      ? `<span class="key"><span class="swatch line dashed-line" style="border-color:${EDGE_COLORS.expect}"></span>expected router (from the registry)</span>` +
        Object.entries(REGISTRY).filter(([, r]) => r.glyph).map(([key, r]) =>
          `<span class="key"><img class="mark" src="${registryMark(key)}" alt="">${r.label}</span>`).join("")
      : ""
    this.legendTarget.innerHTML = kinds.map((k) =>
      `<span class="key">${swatch(k)}${k.label}</span>`
    ).join("") +
      Object.values(MACHINES).map((m) => `<span class="key"><span class="mark-text">${m.mark}</span>${m.label}</span>`).join("") +
      `<span class="key"><span class="mark-text">${OTHER_MACHINE.mark}</span>another kind a profile told</span>` +
      `<span class="key">an icon before a name: the node's own (its profile), in place of the mark</span>` +
      lines +
      `<span class="key"><span class="swatch line" style="background:${EDGE_COLORS.topic_link}"></span>topic, publisher to subscriber</span>` +
      `<span class="key">${badge(BADGE.services, "7")} services</span>` +
      `<span class="key">${badge(BADGE.unmatched, "2")} topics with no counterpart</span>` +
      registry
  }

  // ----------------------------------------------------------------- rates

  // Asks the bridge to go on measuring (RateLease): all topics while the
  // box is ticked, and the topics of the selected node or edge.
  renewLeases() {
    if (this.replayValue) return
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
      ["Last", r.text != null ? `<span class="hint">${esc(ago)}</span><br>${imageTag(r.image)}<code class="wrap">${esc(shorten(r.text, 300))}</code>` : esc(ago), true],
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
    this.cy.nodes(".frame").forEach((f) => f.toggleClass("chosen", f.data("machine") === id))
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
    let html = `<h2>${swatch(k)}${esc(kind === "r_group" ? "ROS 2 machine" : k.label)}</h2>`
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
        const m = machineOf(info.machine)
        const pr = info.profile || {}
        rows.push(["ID", info.node],
                  ["Runs on", m ? `${esc(m.mark)} ${esc(m.label)}` +
                    (MACHINE_BY[info.machine_by] ? ` <span class="hint">(${MACHINE_BY[info.machine_by]})</span>` : "") : null, true],
                  ["Name", pr.name || null],
                  ["Host", pr.host || null],
                  ["Icon", info.icon ? `<img class="node-icon" src="${esc(info.icon)}" alt=""> <span class="hint">${esc(pr.icon_hash)}</span>`
                    : (pr.icon_hash ? `<span class="hint">${esc(pr.icon_hash)} (not fetched yet)</span>` : null), true],
                  ["Apps", el.children().map((a) =>
                    `${this.link(a.id(), a.data("name"))}: ${a.children().map((o) => this.link(o.id(), o.data("name"))).join(", ")}`
                  ).join("<br>") || "none", true],
                  ["Connection", this.connectionsHtml(info.connections, id), true])
        break
      case "others":
        rows.push(["Router", this.link(info.router, this.cy.getElementById(info.router).data("label") || info.router), true],
                  ["Sessions", this.sessionListHtml(info.sessions), true])
        break
      case "reg_box": {
        const entries = el.children().map((c) => {
          const to = c.data("info")?.expect
          return `${this.link(c.id(), c.data("name"))} <span class="hint">${esc(c.data("info")?.peer?.kind || "")}` +
            `${to ? `, expected at router ${esc(to)}` : ""}</span>`
        })
        rows.push(["Entries", entries.join("<br>") || "none", true],
                  ["Cloud router", info.cloud])
        html += `<p class="hint">Names in the relay registry that are not on the network now. A dashed line goes to the
          router the registry says one connects to: the cloud router, for an enabled router or client with a valid
          certificate (the registry is the cloud router's list). The others only sit here.</p>`
        break
      }
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
        const group = info.group && this.cy.getElementById(info.group)
        rows.push(["Name", info.name], ["Domain", info.domain],
                  ["Machine", group?.nonempty() ? `${this.link(info.group, group.data("name"))} ` +
                    `<button type="button" class="small" data-group-toggle="${esc(info.group)}" data-open="0">Fold</button>` : null, true],
                  ["Machine", info.gateway ? `not known: ${esc(info.gateway.ip)} is a gateway ` +
                    `<span class="hint">(${info.gateway.how === "detected"
                      ? "this console's bridge comes through it too: a NAT, such as Docker's published port"
                      : "given as one: ASTERISM_GATEWAY_IPS, or for an older recording the one the console sees today"}).
                      Every machine behind it comes from this address, so this node is not folded with the others from there.</span>` : null, true],
                  ["Connection", this.connectionsHtml(info.connections, id, info.zid), true],
                  ["Publishes", topicList("publishers", "subscribers"), true],
                  ["Subscribes", topicList("subscribers", "publishers"), true])
        break
      }
      case "r_group": {
        const open = this.isOpen(id)
        const n = (info.members || []).length
        rows.push(["IP address", info.ip],
                  ["Name", info.name ? esc(info.name) + this.nameMatchHtml(info) : `<span class="hint">none (shown by its IP)</span>`, true],
                  ["Nodes", (info.members || []).map((m) => this.link(m, nodeLabel(m))).join("<br>"), true],
                  ["Sessions", this.sessionListHtml(info.connections), true],
                  ["Topics inside", (info.internal_topics || []).filter((t) => !(this.hideDebug && isDebugTopic(t)))
                    .map((t) => this.link(t, this.cy.getElementById(t).data("name") || t)).join(", ") || null, true])
        html += `<p class="hint">${n} ROS 2 nodes whose sessions come from ${esc(info.ip)}: one machine, as far as the
          network tells (ROS 2 does not say which machine a node runs on). ${open ? "Open: its nodes are drawn." :
          "Folded: one box; topics among its own nodes are not drawn."}</p>`
        html += `<p class="actions"><button type="button" data-group-toggle="${esc(id)}" data-open="${open ? "0" : "1"}">${open ? "Fold" : "Open"}</button></p>`
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
    if (["a_node", "router", "registered"].includes(kind) && info.registry && this.layers.registry) {
      const p = info.peer || {}
      const r = REGISTRY[info.registry]
      const parts = [r ? r.label : info.registry]
      if (p.kind) parts.push(p.kind)
      if (p.name) parts.push(p.in_acl ? "in the ACL" : "not in the ACL")
      if (p.expires) parts.push(`certificate until ${p.expires.slice(0, 10)}`)
      rows.push(["Registry", (r?.glyph ? `<img class="mark" src="${registryMark(info.registry)}" alt=""> ` : "") +
                 esc(parts.join(", ")) + (p.name ? ` <a href="/relay/peers">registry</a>` : ""), true])
      if (info.via) rows.push(["Through", String(info.via).startsWith("router ") ? info.via : `router ${info.via}`])
      if (kind === "registered") {
        rows.push(["Expected at", info.expect ? `router ${info.expect}`
          : "the registry does not tell (the cloud router itself, or left out of its ACL: disabled or no valid certificate)"])
        if (p.description) rows.push(["Description", p.description])
      }
    }
    html += dl(rows)
    if (kind === "r_group") html += this.nameFormHtml(info)
    if (kind === "r_group") html += this.rosNodeExtras(info)
    if (kind === "r_node") html += `<p class="actions"><a class="button" href="/logs?node=${encodeURIComponent(loggerName(info.name))}" target="_blank" rel="noopener">Show its logs</a></p>`
    if (kind === "r_node") html += this.rosNodeExtras(info)
    if (kind === "a_object") html += `<div class="methods" data-role="methods"><p class="hint">Reading the exposed methods...</p></div><div class="results" data-role="results"></div>`
    if (kind === "r_topic") html += `<div class="row actions"><button type="button" data-watch="${esc(`${info.domain}${info.name}/**`)}">Watch its values</button>` +
      `${plotLink(id)}</div>`
    this.renderDetails(html)
    if (kind === "a_object") this.loadMeta(info.path)
  }

  // How a group's name was matched: the node names it was given for.
  nameMatchHtml(info) {
    const now = new Set(info.member_names || [])
    const then = info.named_members || []
    const same = then.filter((m) => now.has(m)).length
    return ` <span class="hint">(given for ${then.length} node names, ${same} of them here now)</span>`
  }

  // The name form of a group: admins give, change or remove the name.
  nameFormHtml(info) {
    if (this.replayValue) {
      return `<p class="hint">Names are given on the live graph; the rewind shows today's names.</p>`
    }
    if (!this.adminValue) {
      return `<p class="hint">An admin can give this machine a name (shared by every user).</p>`
    }
    return `<form class="name-form" data-role="name-form">
      <label for="machine-name">Name this machine</label>
      <div class="row"><input id="machine-name" type="text" name="name" maxlength="64" value="${esc(info.name || "")}" placeholder="${esc(info.ip)}">
      <button type="submit">Save</button>${info.name_id ? `<button type="button" data-role="name-remove">Remove</button>` : ""}</div>
      <p class="hint" data-role="name-status">Kept with the names of its ${(info.member_names || []).length} nodes, not the IP:
        the machine keeps it when its address changes, while at least half of the nodes are the same.</p></form>`
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

  // A node's sessions (data "connections", lib/bridge/connections.rb): Zenoh
  // ID, role, address, link and router, and the other nodes on the same one.
  connectionsHtml(list, id, zid = null) {
    if (!list) return zid ? `${esc(zid)}<br><span class="hint">(this recording has no connection details)</span>` : ""
    if (!list.length) return `<span class="hint">not seen at a router${zid ? ` (Zenoh ID ${esc(zid)})` : ""}</span>`
    return list.map((c) => {
      const router = c.router ? this.link(c.router, c.router_label || c.router) : "no router"
      const others = (c.nodes || []).filter((n) => n !== id)
      return dl([["Zenoh ID", c.zid], ["Role", c.role], ["Address", c.address], ["Link", c.protocol],
                 ["Certificate", c.protocol === "tls" ? (c.cert_name || "(the router does not show it)") : null],
                 ["Router", router, true],
                 ["Also on it", others.length ? others.map((n) => this.link(n, this.cy.getElementById(n).data("name") || n)).join(", ") : null, true]]) +
        (c.self ? `<p class="hint">a session of this console</p>` : "")
    }).join("")
  }

  // The sessions of an "other connections" node.
  sessionListHtml(list) {
    if (!list?.length) return "none"
    return `<table class="sessions"><tr><th>Role</th><th>Zenoh ID</th><th>Address</th></tr>${list.map((c) =>
      `<tr><td>${esc(c.role)}${c.self ? " (this console)" : ""}</td><td><code title="${esc(c.zid)}">${esc(String(c.zid).slice(0, 8))}</code></td>` +
      `<td>${esc(c.address || "")}${c.protocol ? ` <span class="hint">${esc(c.protocol)}</span>` : ""}</td></tr>`).join("")}</table>`
  }

  // A node's line to its router (or to a peer): the sessions behind it.
  connectionDetails(el) {
    const a = el.source(), b = el.target()
    let html = `<h2><span class="swatch line" style="background:${EDGE_COLORS[el.data("kind")]}"></span>${el.data("kind") === "peer_link" ? "Peer to peer" : "Connection"}</h2>`
    html += `<p class="name">${this.link(a.id(), a.data("name"))} &ndash; ${this.link(b.id(), b.data("name"))}</p>`
    const zids = new Set(el.data("sessions") || [])
    const source = a.data("kind") === "others" ? a.data("info").sessions : (a.data("info").connections || [])
    const list = source.filter((c) => el.data("kind") === "peer_link" || zids.has(c.zid))
    html += a.data("kind") === "others" ? this.sessionListHtml(list) : this.connectionsHtml(list, a.id())
    if (el.data("shared") > 1) html += `<p class="hint">One session carries ${el.data("shared")} nodes (one process): each has its own line.</p>`
    this.renderDetails(html)
  }

  // A topic edge: the topics from one node to the other, each with its
  // rate and last value (like rqt_topic).
  edgeDetails(el) {
    if (el.data("kind") !== "topic_link") return this.connectionDetails(el)
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
    if (this.replayValue) {
      // Recorded: nothing to watch or call.
      this.detailsTarget.querySelectorAll("[data-watch], [data-role=methods], [data-role=results]").forEach((e) => e.remove())
    }
    this.detailsTarget.querySelectorAll("[data-select]").forEach((a) => a.addEventListener("click", (ev) => {
      ev.preventDefault()
      this.select(a.dataset.select)
    }))
    this.detailsTarget.querySelectorAll("[data-watch]").forEach((b) => b.addEventListener("click", () => this.watchKey(b.dataset.watch)))
    this.detailsTarget.querySelectorAll("[data-group-toggle]").forEach((b) => b.addEventListener("click", () =>
      this.toggleGroup(b.dataset.groupToggle, b.dataset.open === "1")))
    const form = this.detailsTarget.querySelector("[data-role=name-form]")
    if (form) {
      const gid = this.selected
      form.addEventListener("submit", (ev) => { ev.preventDefault(); this.saveName(gid, form.querySelector("[name=name]").value) })
      form.querySelector("[data-role=name-remove]")?.addEventListener("click", () => this.removeName(gid))
    }
  }

  async loadMeta(path) {
    if (this.replayValue) return
    const box = () => this.detailsTarget.querySelector("[data-role=methods]")
    let rules = []
    try {
      const res = await fetch(`/permissions?path=${encodeURIComponent(path)}`, { headers: { Accept: "application/json" } })
      if (res.ok) rules = await res.json()
    } catch (_e) { /* treated as none */ }
    if (this.selected !== `a_object:${path}` || !box()) return
    if (rules.length === 0) {
      box().innerHTML = `<p class="hint">No call permission covers this object, so its methods are not read or called.
        ${this.adminValue ? `<a href="/admin/call_permissions">Call permissions</a>` : "An admin can allow it."}</p>`
      return
    }
    const allowed = (name) => rules.some((r) => globMatch(r.method, name))
    const req = await this.request({ kind: "meta", path, timeout_s: 3 })
    if (this.selected !== `a_object:${path}` || !box()) return
    if (req.status !== "ok") {
      box().innerHTML = `<p class="error">meta: ${esc(STATUS_TEXT[req.status] || req.status)} ${esc(req.error_class || "")} ${esc(req.error_message || req.errors || "")}</p>`
      return
    }
    // Protocol 1's meta: {"methods": [{"name", "arity"}, ...]}
    const methods = (req.result?.methods || []).map((m) => (m && typeof m === "object" && !Array.isArray(m)) ? [m.name, m.arity ?? -1] : (Array.isArray(m) ? m : [m, -1]))
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
    else text = `${STATUS_TEXT[req.status] || req.status}: ${req.error_kind ? `[${req.error_kind}] ` : ""}${req.error_class || ""} ${req.error_message || ""}`
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
      (list.length ? `${imageTag(list[0].image)}<ol class="samples">${list.map((s) =>
        `<li><span class="at">${esc(s.at)}</span> <code class="k" title="${esc(s.key)}">${esc(shorten(s.key, 48))}</code> <span class="fmt">${esc(s.format)}</span> <span class="v">${esc(s.text)}</span></li>`).join("")}</ol>`
        : `<p class="hint">Nothing yet.</p>`)
    div.querySelector("button").addEventListener("click", () => this.removeWatch(id))
  }
}

// What changed from one graph (Bridge::Graph#to_h) to another, in the
// shape of the bridge's diffs (Bridge::Graph.diff).
function graphDiff(oldG, newG) {
  const out = {}
  for (const part of ["nodes", "edges"]) {
    const a = new Map((oldG?.[part] || []).map((x) => [x.id, x]))
    const b = new Map((newG?.[part] || []).map((x) => [x.id, x]))
    out[`add_${part}`] = [...b.values()].filter((x) => !a.has(x.id))
    out[`remove_${part}`] = [...a.keys()].filter((id) => !b.has(id))
    out[`change_${part}`] = [...b.values()].filter((x) => a.has(x.id) && JSON.stringify(a.get(x.id)) !== JSON.stringify(x))
  }
  return out
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

// The legend's and the details' sample of a kind: its shape, fill and border.
// The width of an Asterism node's label in the graph (bold 12 px, the
// a_node style), for placing its icon.
let labelCanvas = null
function labelWidth(text) {
  labelCanvas ||= document.createElement("canvas").getContext("2d")
  labelCanvas.font = 'bold 12px "Helvetica Neue", Helvetica, sans-serif'
  return labelCanvas.measureText(String(text || "")).width
}

function swatch(k) {
  const border = k.double ? `;outline:1.5px solid ${k.border};outline-offset:1.5px`
    : k.border ? `;border:${k.dashed ? "1.5px dashed" : "2px solid"} ${k.border}` : ""
  return `<span class="swatch shape-${k.shape}" style="background:${k.color}${border}"></span>`
}

// The registry's corner mark (an SVG image): a dark grey disc with a white
// check (registered), bar (disabled) or question mark (not in the registry).
function registryMark(state) {
  const glyph = REGISTRY[state]?.glyph
  if (!glyph) return null
  const inner = glyph === "check"
    ? `<path d="M4 7.3 L6.1 9.4 L10.2 4.9" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>`
    : glyph === "bar"
      ? `<path d="M4 7 L10 7" stroke="#fff" stroke-width="2" stroke-linecap="round"/>`
      : `<text x="7" y="10.6" font-family="sans-serif" font-size="10" font-weight="bold" fill="#fff" text-anchor="middle">?</text>`
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">` +
    `<circle cx="7" cy="7" r="6.3" fill="#455a64" stroke="#fff" stroke-width="1"/>${inner}</svg>`
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
}

// "Plot this topic": the plot page, in a tab of its own (the graph keeps its layout).
function plotLink(tid, small = false) {
  return `<a class="button${small ? " small" : ""}" href="/plots?topic=${encodeURIComponent(tid)}" target="_blank" rel="noopener">Plot this topic</a>`
}

// The logger name rclcpp gives a node: /ns/talker -> ns.talker.
function loggerName(node) {
  return String(node || "").replace(/^\//, "").replace(/\//g, ".")
}

// A remembered setting of this browser (storage may be refused: then the default).
function loadFlag(key) {
  try { return localStorage.getItem(key) === "1" } catch (_e) { return false }
}

function loadList(key) {
  try {
    const v = JSON.parse(localStorage.getItem(key) || "[]")
    return Array.isArray(v) ? v.map(String) : []
  } catch (_e) { return [] }
}

function saveList(key, list) {
  try { localStorage.setItem(key, JSON.stringify(list)) } catch (_e) { /* not remembered */ }
}

function saveFlag(key, on) {
  try { localStorage.setItem(key, on ? "1" : "0") } catch (_e) { /* not remembered */ }
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
