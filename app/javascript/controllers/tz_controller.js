import { Controller } from "@hotwired/stimulus"

// A time typed into a datetime-local field is the browser's local time;
// this tells the console the browser's offset from UTC (G1.5b, "Apply at
// this time"), and says which zone the field is in.
export default class extends Controller {
  static targets = ["offset", "time", "zone"]

  connect() {
    this.offsetTarget.value = String(new Date().getTimezoneOffset())
    let zone = ""
    try { zone = Intl.DateTimeFormat().resolvedOptions().timeZone || "" } catch (e) { zone = "" }
    if (this.hasZoneTarget) this.zoneTarget.textContent = zone ? `(your time, ${zone})` : "(your time)"
  }
}
