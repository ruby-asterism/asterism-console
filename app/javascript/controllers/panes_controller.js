import { Controller } from "@hotwired/stimulus"

// The graph page's panes: the Details column on the right and the watched
// keys' panel at the bottom. Their borders can be dragged (or moved with the
// arrow keys) to change the column's width and the panel's height, and the
// panel can be collapsed to one line. The sizes and the collapsed state are
// remembered by this browser (localStorage; nothing breaks without it).
// The sizes go into CSS variables (--side-w, --dock-h): the stylesheet
// decides when they apply (not at phone width, not while the panel has no
// watches or is collapsed).
const STORE_SIDE = "asterism.console.sideWidth"
const STORE_DOCK = "asterism.console.dockHeight"
const STORE_COLLAPSED = "asterism.console.dockCollapsed"
const SIDE_MIN = 260
const DOCK_MIN = 90
const GRAPH_MIN = 160 // what the graph keeps in either direction
const KEY_STEP = 24

export default class extends Controller {
  static targets = ["side", "dock", "toggle"]

  connect() {
    const w = Number(load(STORE_SIDE))
    if (w > 0) this.setSide(w, false)
    const h = Number(load(STORE_DOCK))
    if (h > 0) this.setDock(h, false)
    this.setCollapsed(load(STORE_COLLAPSED) === "1", false)
    this.element.querySelectorAll(".splitter").forEach((s) => {
      s.tabIndex = 0
      s.addEventListener("keydown", (ev) => this.key(ev, s))
    })
  }

  // ------------------------------------------------------------ dragging

  startSide(ev) {
    this.drag(ev, (e) => this.setSide(this.element.getBoundingClientRect().right - e.clientX, false),
              () => save(STORE_SIDE, this.sideWidth))
  }

  startDock(ev) {
    if (this.dockTarget.classList.contains("empty")) return
    if (this.collapsed) this.setCollapsed(false)
    this.drag(ev, (e) => this.setDock(this.element.getBoundingClientRect().bottom - e.clientY, false),
              () => save(STORE_DOCK, this.dockHeight))
  }

  drag(ev, move, done) {
    if (ev.button !== 0) return
    ev.preventDefault()
    const bar = ev.currentTarget
    bar.setPointerCapture(ev.pointerId)
    bar.classList.add("dragging")
    document.body.classList.add("resizing")
    const onMove = (e) => move(e)
    const onUp = () => {
      bar.classList.remove("dragging")
      document.body.classList.remove("resizing")
      bar.removeEventListener("pointermove", onMove)
      bar.removeEventListener("pointerup", onUp)
      bar.removeEventListener("pointercancel", onUp)
      done()
    }
    bar.addEventListener("pointermove", onMove)
    bar.addEventListener("pointerup", onUp)
    bar.addEventListener("pointercancel", onUp)
  }

  key(ev, bar) {
    const side = bar.classList.contains("splitter-x")
    const grow = side ? { ArrowLeft: 1, ArrowRight: -1 } : { ArrowUp: 1, ArrowDown: -1 }
    const d = grow[ev.key]
    if (!d) return
    ev.preventDefault()
    if (side) {
      this.setSide(this.sideWidth + d * KEY_STEP, false)
      save(STORE_SIDE, this.sideWidth)
    } else if (!this.dockTarget.classList.contains("empty")) {
      if (this.collapsed) this.setCollapsed(false)
      this.setDock(this.dockHeight + d * KEY_STEP, false)
      save(STORE_DOCK, this.dockHeight)
    }
  }

  // ------------------------------------------------------------- sizes

  get sideWidth() { return this.sideTarget.getBoundingClientRect().width }

  get dockHeight() { return this.dockTarget.getBoundingClientRect().height }

  setSide(px, remember = true) {
    const max = Math.max(SIDE_MIN, this.element.getBoundingClientRect().width - GRAPH_MIN)
    const w = Math.round(Math.min(max, Math.max(SIDE_MIN, px)))
    this.element.style.setProperty("--side-w", `${w}px`)
    if (remember) save(STORE_SIDE, w)
  }

  setDock(px, remember = true) {
    const max = Math.max(DOCK_MIN, this.element.getBoundingClientRect().height - GRAPH_MIN)
    const h = Math.round(Math.min(max, Math.max(DOCK_MIN, px)))
    this.element.style.setProperty("--dock-h", `${h}px`)
    if (remember) save(STORE_DOCK, h)
  }

  // ---------------------------------------------------------- collapse

  toggleDock() {
    this.setCollapsed(!this.collapsed)
  }

  setCollapsed(on, remember = true) {
    this.collapsed = on
    this.dockTarget.classList.toggle("collapsed", on)
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", on ? "false" : "true")
      this.toggleTarget.setAttribute("aria-label", on ? "Expand the watched keys" : "Collapse the watched keys")
      this.toggleTarget.innerHTML = on ? "&#9656;" : "&#9662;"
    }
    if (remember) save(STORE_COLLAPSED, on ? "1" : "0")
  }
}

function load(key) {
  try { return localStorage.getItem(key) } catch (_e) { return null }
}

function save(key, value) {
  try { localStorage.setItem(key, String(value)) } catch (_e) { /* not remembered */ }
}
