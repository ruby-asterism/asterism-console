import { Controller } from "@hotwired/stimulus"

// A link the page shows only once (an invite link, a room's link): a button
// that copies it, and says so, so it is not lost by leaving the page.
export default class extends Controller {
  static targets = ["source", "button"]

  async copy() {
    const el = this.sourceTarget
    const text = (el.getAttribute("href") || el.textContent).trim()
    try {
      await navigator.clipboard.writeText(text)
    } catch (_e) {
      const range = document.createRange()
      range.selectNodeContents(el)
      const sel = window.getSelection()
      sel.removeAllRanges()
      sel.addRange(range)
      document.execCommand("copy")
    }
    this.buttonTarget.textContent = "Copied"
  }
}
