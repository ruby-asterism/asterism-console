import { Controller } from "@hotwired/stimulus"

// When to apply (relay/applies/new): one form, a choice and one button.
// The time field is required only while "at a time" is chosen, so "now"
// and "when nobody is connected" never ask for it (the console ignores a
// time given with them); going to the field chooses "at a time". The button
// says what it does, and "now" asks for a confirmation (the restart cuts
// every link). Without this script nothing is required, and the console
// checks the time for "at" only.
export default class extends Controller {
  static targets = ["time", "submit"]
  static values = { confirm: String }

  static labels = {
    now: "Write the configuration and restart the cloud router now",
    idle: "Apply when nobody is connected",
    at: "Apply at this time"
  }

  connect() {
    this.pick()
  }

  pick() {
    const mode = this.element.querySelector("input[name=mode]:checked")?.value || "now"
    const at = mode === "at"
    this.timeTarget.required = at
    this.submitTarget.textContent = this.constructor.labels[mode]
    if (mode === "now") {
      this.element.dataset.turboConfirm = this.confirmValue
    } else {
      delete this.element.dataset.turboConfirm
    }
  }

  // Going to the time field means "at a time".
  chooseAt() {
    const at = this.element.querySelector("input[name=mode][value=at]")
    if (at && !at.checked) {
      at.checked = true
      this.pick()
    }
  }
}
