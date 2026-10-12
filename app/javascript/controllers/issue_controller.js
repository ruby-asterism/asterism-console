import { Controller } from "@hotwired/stimulus"

// Issuing a relay certificate with the key made in this browser (W4).
// Web Crypto makes an ECDSA P-256 key pair; only the public key
// (SubjectPublicKeyInfo, DER, base64) is sent; the console has the signer
// sign a certificate for it and answers with the certificate and the CA.
// The private key (PKCS#8 PEM) is shown here, once, next to them. It is
// never sent, stored or shown again: leaving the page loses it.
export default class extends Controller {
  static targets = ["button", "insecure", "result", "facts", "key", "cert", "ca", "config", "command", "error"]
  static values = { url: String, name: String }

  connect() {
    if (!window.isSecureContext || !window.crypto?.subtle) {
      this.insecureTarget.hidden = false
      this.buttonTarget.disabled = true
    }
    this.guard = (ev) => { if (this.holdsKey) { ev.preventDefault(); ev.returnValue = "" } }
    window.addEventListener("beforeunload", this.guard)
    this.leave = (ev) => {
      if (this.holdsKey && !confirm("The private key is shown only on this page. Leave and lose it?")) ev.preventDefault()
    }
    document.addEventListener("turbo:before-visit", this.leave)
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.guard)
    document.removeEventListener("turbo:before-visit", this.leave)
    this.wipe()
  }

  async issue() {
    if (this.holdsKey && !confirm("A key is shown below. Issue another and lose this one?")) return
    this.errorTarget.hidden = true
    this.buttonTarget.disabled = true
    try {
      const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
      const spki = b64(await crypto.subtle.exportKey("spki", pair.publicKey))
      const res = await fetch(this.urlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
        body: JSON.stringify({ spki }),
        cache: "no-store",
        credentials: "same-origin"
      })
      const ans = await res.json().catch(() => ({}))
      if (!res.ok) throw new Error(ans.error || `the console said ${res.status}`)
      const key = pem("PRIVATE KEY", await crypto.subtle.exportKey("pkcs8", pair.privateKey))
      this.keyTarget.value = key
      this.certTarget.value = ans.certificate
      this.caTarget.value = ans.ca
      this.configTarget.value = ans.zenoh_config
      this.factsTarget.innerHTML = ""
      for (const [k, v] of [["Serial", ans.serial], ["Until", ans.not_after], ["Fingerprint (SHA-256)", ans.fingerprint]]) {
        const dt = document.createElement("dt"); dt.textContent = k
        const dd = document.createElement("dd"); dd.textContent = v
        this.factsTarget.append(dt, dd)
      }
      this.commandTarget.textContent = `A CRuby node with these files: ${ans.command}`
      this.resultTarget.hidden = false
      this.holdsKey = true
    } catch (e) {
      this.errorTarget.textContent = `Not issued: ${e.message}`
      this.errorTarget.hidden = false
    } finally {
      this.buttonTarget.disabled = false
    }
  }

  async copy({ params: { which } }) {
    const el = this[`${which}Target`]
    try {
      await navigator.clipboard.writeText(el.value)
    } catch (_e) {
      el.select()
      document.execCommand("copy")
    }
  }

  save({ params: { which, file } }) {
    const blob = new Blob([this[`${which}Target`].value], { type: "application/octet-stream" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = file
    document.body.append(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }

  wipe() {
    if (this.hasKeyTarget) this.keyTarget.value = ""
    this.holdsKey = false
  }
}

function b64(buf) {
  let s = ""
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b)
  return btoa(s)
}

function pem(label, buf) {
  const body = b64(buf).match(/.{1,64}/g).join("\n")
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----\n`
}

function csrf() {
  return document.querySelector("meta[name=csrf-token]")?.content || ""
}
