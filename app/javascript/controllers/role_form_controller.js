import { Controller } from "@hotwired/stimulus"

// The role form's "App name" helper (Admin > Relay > Roles, new and edit):
// an app name fills the four templates with the usual pattern for one app,
// and suggests a name and a description. Only empty fields are filled,
// unless the admin agrees to overwrite the others. Nothing is sent: the
// form is saved as usual.
const APP = /^[A-Za-z0-9_.-]{1,64}$/

export default class extends Controller {
  static targets = ["app", "name", "description", "rw", "read", "ask", "watch", "message"]

  fill(ev) {
    ev?.preventDefault()
    const app = this.appTarget.value.trim()
    if (!APP.test(app)) {
      this.say("Type an app name first: letters, digits, '.', '-' and '_' (for example demo).", true)
      this.appTarget.focus()
      return
    }
    const values = suggestions(app)
    const fields = Object.keys(values).filter((k) => this[`has${cap(k)}Target`])
    const filled = fields.filter((k) => {
      const v = this[`${k}Target`].value.trim()
      return v !== "" && v !== values[k]
    })
    let overwrite = false
    if (filled.length) {
      const names = filled.map((k) => this[`${k}Target`].dataset.label || k).join(", ")
      overwrite = window.confirm(`These fields already have something: ${names}.\n\nOverwrite them with the pattern for "${app}"? (Cancel fills only the empty fields.)`)
    }
    let changed = 0
    for (const k of fields) {
      const el = this[`${k}Target`]
      if (el.value.trim() !== "" && !overwrite) continue
      if (el.value === values[k]) continue
      el.value = values[k]
      el.dispatchEvent(new Event("input", { bubbles: true }))
      changed++
    }
    const kept = overwrite ? 0 : filled.length
    this.say(changed
      ? `Filled ${changed} field${changed === 1 ? "" : "s"} for "${app}"${kept ? ` (kept ${kept} that had something)` : ""}. Check them, then save.`
      : `Nothing to fill: the fields already have something${kept ? "" : " for this app"}.`, false)
  }

  // Enter in the app name fills in (instead of submitting the form).
  key(ev) {
    if (ev.key === "Enter") this.fill(ev)
  }

  say(text, bad) {
    if (!this.hasMessageTarget) return
    this.messageTarget.textContent = text
    this.messageTarget.classList.toggle("error", bad)
    this.messageTarget.classList.toggle("hint", !bad)
  }
}

// The usual pattern for one app: its own place both ways, every node's
// app to read, calls in its own name only, and the liveliness watch.
function suggestions(app) {
  return {
    name: app.toLowerCase().replace(/[^a-z0-9_-]/g, "-").replace(/^[^a-z0-9]+/, "").slice(0, 41) || "app",
    description: `For the ${app} app: reads and writes its own ${app} keys, reads every node's ${app} keys, ` +
      `calls others' ${app} objects in its own name.`,
    rw: `asterism/\${node}/${app}/**`,
    read: `asterism/*/${app}/**`,
    ask: `asterism/*/${app}/*/call/\${node}`,
    watch: "asterism/**",
  }
}

function cap(s) {
  return s.charAt(0).toUpperCase() + s.slice(1)
}
