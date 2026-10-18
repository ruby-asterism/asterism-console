import { Controller } from "@hotwired/stimulus"

// The invite link's page (0.3.5): the link carries its secret in the
// fragment (/invite#invite=<secret>), which no server sees. This takes it
// out of the address bar and hands it to the console in the form's body.
export default class extends Controller {
  static targets = ["form", "secret"]

  connect() {
    const m = window.location.hash.match(/(?:^#|&)invite=([A-Za-z0-9_-]+)/)
    if (!m) return
    window.history.replaceState(null, "", window.location.pathname + window.location.search)
    this.secretTarget.value = m[1]
    this.formTarget.requestSubmit()
  }
}
