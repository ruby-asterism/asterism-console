import { Controller } from "@hotwired/stimulus"

// The menu at phone width: one "Menu" button that shows or hides the
// groups (on a wide screen the groups are always shown and the button is
// hidden by the stylesheet).
export default class extends Controller {
  static targets = ["toggle", "menu"]

  toggle() {
    const open = !this.element.classList.contains("open")
    this.element.classList.toggle("open", open)
    this.toggleTarget.setAttribute("aria-expanded", open ? "true" : "false")
  }
}
