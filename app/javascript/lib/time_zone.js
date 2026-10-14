// The console's time zone (CONSOLE_TIME_ZONE, 0.2.1): the layout puts it in
// <meta name="console-time-zone"> (an IANA name), and every time the pages
// write in the browser is in it, like the server's pages. A browser that
// does not know the zone falls back to UTC. The zone's name is the
// server's abbreviation ("JST", data-abbr) for times at the server's
// current offset, else what the browser calls it ("GMT+9").

const FALLBACK = "UTC"
const formats = new Map()

export function consoleZone() {
  const zone = document.querySelector('meta[name="console-time-zone"]')?.content || FALLBACK
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone })
    return zone
  } catch (_e) {
    return FALLBACK
  }
}

function parts(ms, withZone = false) {
  const zone = consoleZone()
  const key = `${zone}|${withZone}`
  if (!formats.has(key)) {
    formats.set(key, new Intl.DateTimeFormat("en-US", {
      timeZone: zone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", ...(withZone ? { timeZoneName: "longOffset" } : {}),
    }))
  }
  const out = {}
  for (const p of formats.get(key).formatToParts(new Date(ms))) out[p.type] = p.value
  if (withZone) out.timeZoneName = shortName(out.timeZoneName, zone)
  return out
}

// "GMT+09:00" -> the server's "JST" when that is its offset now, else "GMT+9".
function shortName(longOffset, zone) {
  const m = /^GMT(?:([+-])(\d{2}):(\d{2}))?$/.exec(longOffset || "")
  if (!m) return longOffset || zone
  const offset = m[1] ? (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 3600 + Number(m[3]) * 60) : 0
  const meta = document.querySelector('meta[name="console-time-zone"]')
  if (meta?.content === zone && meta.dataset.abbr && Number(meta.dataset.offset) === offset) return meta.dataset.abbr
  if (!m[1]) return "UTC"
  return `GMT${m[1]}${Number(m[2])}${m[3] === "00" ? "" : `:${m[3]}`}`
}

const toMs = (t) => (t instanceof Date ? t.getTime() : typeof t === "string" ? Date.parse(t) : Number(t))

// "13:04:05.123" (millis: false: "13:04:05"), in the console's zone.
export function clock(t, { millis = true, zone = false } = {}) {
  const ms = toMs(t)
  if (!Number.isFinite(ms)) return ""
  const p = parts(ms, zone)
  const frac = millis ? `.${String(((ms % 1000) + 1000) % 1000).padStart(3, "0")}` : ""
  return `${p.hour}:${p.minute}:${p.second}${frac}${zone ? ` ${p.timeZoneName}` : ""}`
}

// "2026-10-14 21:30 JST" (zone: false leaves the zone out).
export function dateTime(t, { zone = true, seconds = false } = {}) {
  const ms = toMs(t)
  if (!Number.isFinite(ms)) return ""
  const p = parts(ms, zone)
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}${seconds ? `:${p.second}` : ""}${zone ? ` ${p.timeZoneName}` : ""}`
}

// "2026-10-14", in the console's zone.
export function date(t) {
  const ms = toMs(t)
  if (!Number.isFinite(ms)) return ""
  const p = parts(ms)
  return `${p.year}-${p.month}-${p.day}`
}

// The zone's short name at that time ("UTC", "JST", "GMT+9").
export function zoneName(t = Date.now()) {
  return parts(toMs(t), true).timeZoneName || consoleZone()
}
