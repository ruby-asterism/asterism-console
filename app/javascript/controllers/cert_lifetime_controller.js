import { Controller } from "@hotwired/stimulus"

// A member row's certificate lifetime (relay/peers/_form, new and edit):
// while "No expiry" is ticked, the certificate days are not used, so their
// field is greyed and cannot be edited; unticking gives it back. The field
// is made read-only rather than disabled, so the form still sends its value
// (a new row keeps its default days for when "No expiry" is unticked later).
// Without this script the field stays as it is and the console ignores the
// days of a row without an end.
export default class extends Controller {
  static targets = ["days", "noExpiry"]

  connect() {
    this.toggle()
  }

  toggle() {
    if (!this.hasDaysTarget || !this.hasNoExpiryTarget) return
    const off = this.noExpiryTarget.checked
    this.daysTarget.readOnly = off
    this.daysTarget.setAttribute("aria-disabled", String(off))
    this.daysTarget.tabIndex = off ? -1 : 0
    this.daysTarget.closest("label")?.classList.toggle("unused", off)
  }
}
