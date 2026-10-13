// The credentials of one peer as one uncompressed tar (O1), made in the
// browser that made the key: the private key never goes to the console, so
// the archive cannot be made there either. "Save all (.tar)" on the
// certificate page saves it as <name>.tar, which extracts to <name>/:
//
//   <name>.key     the private key (PKCS#8 PEM)          0600
//   <name>.pem     the certificate                       0644
//   ca.pem         the CA                                0644
//   zenoh.json5    the example configuration (a home router's, or a client's)  0644
//   asterism.json  name, kind, the cloud router, until, the console that issued it  0644
//
// CRuby connects with the file as it is (the asterism gem's credentials:);
// a home router runs `zenohd -c zenoh.json5` in the extracted directory.
// The format is POSIX ustar (what tar, Ruby's Gem::Package::TarReader and
// Python's tarfile read), no dependencies.

const BLOCK = 512

export function credentialsFiles({ name, key, cert, ca, config, info }) {
  return [
    { name: `${name}.key`, mode: 0o600, text: key },
    { name: `${name}.pem`, mode: 0o644, text: cert },
    { name: "ca.pem", mode: 0o644, text: ca },
    { name: "zenoh.json5", mode: 0o644, text: config },
    { name: "asterism.json", mode: 0o644, text: JSON.stringify(info, null, 2) + "\n" },
  ]
}

// The tar (a Uint8Array) of the credentials, under the directory <name>/.
export function credentialsTar(parts, mtime = Math.floor(Date.now() / 1000)) {
  const dir = parts.name
  const entries = [{ name: `${dir}/`, mode: 0o755, dir: true }]
  for (const f of credentialsFiles(parts)) entries.push({ ...f, name: `${dir}/${f.name}` })
  return makeTar(entries, mtime)
}

// entries: [{ name, mode, text | bytes, dir }] -> Uint8Array.
export function makeTar(entries, mtime = Math.floor(Date.now() / 1000)) {
  const enc = new TextEncoder()
  const chunks = []
  for (const e of entries) {
    const body = e.dir ? new Uint8Array(0) : (e.bytes || enc.encode(e.text ?? ""))
    chunks.push(header(e.name, e.mode, body.length, mtime, e.dir ? "5" : "0"))
    chunks.push(body)
    const pad = (BLOCK - (body.length % BLOCK)) % BLOCK
    if (pad) chunks.push(new Uint8Array(pad))
  }
  chunks.push(new Uint8Array(BLOCK * 2))
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0))
  let at = 0
  for (const c of chunks) { out.set(c, at); at += c.length }
  return out
}

function header(name, mode, size, mtime, type) {
  const enc = new TextEncoder()
  const nameBytes = enc.encode(name)
  if (nameBytes.length > 100) throw new Error(`name too long for a tar header: ${name}`)
  const h = new Uint8Array(BLOCK)
  const put = (at, bytes) => h.set(bytes, at)
  const octal = (n, width) => enc.encode(n.toString(8).padStart(width - 1, "0") + "\0")
  put(0, nameBytes)
  put(100, octal(mode, 8))
  put(108, octal(0, 8))           // uid
  put(116, octal(0, 8))           // gid
  put(124, octal(size, 12))
  put(136, octal(mtime, 12))
  put(148, enc.encode("        ")) // the checksum counts as spaces while it is summed
  put(156, enc.encode(type))
  put(257, enc.encode("ustar\0"))
  put(263, enc.encode("00"))
  let sum = 0
  for (const b of h) sum += b
  put(148, enc.encode(sum.toString(8).padStart(6, "0") + "\0 "))
  return h
}
