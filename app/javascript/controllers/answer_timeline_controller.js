import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// The results page's "over time" tab: click an answer row on a result card
// and a panel docks beside the feed showing how every answer to that question
// moved over time, the clicked one emphasised, with the page's own date
// presets or a From/To of the reader's.
//
// One shell on the page, outside the results-feed frame (which auto-refresh
// replaces); each row carries its own URL, key and labels as Stimulus params.
// The series come from SurveyTimelinesController as counts per period; share
// is divided here, so Share % / Count and the emphasised answer switch without
// another request. The date range does ask again — it changes the buckets.
//
// The chart is built with DOM calls and textContent throughout: every label
// in it is a respondent-facing option or a card's question, which is data,
// never markup.
const SVG_NS = "http://www.w3.org/2000/svg"
const ACCENT = "#01EACB"
const MUTED  = "rgba(255,255,255,0.28)"
const H = 170, TOP = 12, BOTTOM = 146, LEFT = 34, RIGHT_PAD = 42

export default class extends Controller {
  static targets = [ "panel", "label", "question", "rangeBtn", "custom", "from", "to",
                     "nowLabel", "now", "changeLabel", "change", "peak", "peakWhen",
                     "chart", "status", "legend", "modeBtn" ]
  static values  = { range: { type: String, default: "all" } }

  connect() {
    this.range = this.rangeValue || "all"
    this.mode  = "share"
    this._data  = null
    this._seq  = 0
  }

  // From a row: url is the card's timeline endpoint (with the page's segment
  // already on it), key the row's answer, label and question what to say.
  open(event) {
    const { url, key, label, question } = event.params
    if (!url) return
    this.url  = url
    this.key  = String(key ?? "")
    this._rows = event.currentTarget.closest(".rc-card")
    this._markRow(event.currentTarget)
    this.labelTarget.textContent    = label || ""
    this.questionTarget.textContent = question || ""
    this.panelTarget.hidden = false
    this._paintRange()
    this._paintMode()
    this._load()
  }

  close() {
    this._seq++
    this.panelTarget.hidden = true
    this._markRow(null)
  }

  closeOnEsc() {
    if (!this.panelTarget.hidden) this.close()
  }

  setRange(event) {
    const range = event.params.range
    if (!range) return
    this.range = range
    this._paintRange()
    if (range === "custom") {
      // Start the reader from the window they were just looking at.
      if (this._data) {
        if (!this.fromTarget.value) this.fromTarget.value = this._data.from
        if (!this.toTarget.value)   this.toTarget.value   = this._data.to
      }
      this.fromTarget.focus()
    }
    this._load()
  }

  applyCustom() {
    if (this.range !== "custom") return
    this._load()
  }

  setMode(event) {
    this.mode = event.params.mode === "count" ? "count" : "share"
    this._paintMode()
    this._render()
  }

  // From the legend: emphasise another answer. The row on the card follows,
  // so the two never disagree about which answer the tab is about.
  pick(event) {
    const key = String(event.params.key ?? "")
    const series = this._data?.series.find(s => s.key === key)
    if (!series) return
    this.key = key
    this.labelTarget.textContent = series.label
    const row = this._rows?.querySelector(`.rc-row[data-answer-timeline-key-param="${cssEscape(key)}"]`)
    if (row) this._markRow(row)
    this._render()
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  async _load() {
    if (!this.url) return
    if (this.range === "custom") {
      const from = this.fromTarget.value, to = this.toTarget.value
      if (!from || !to || from > to) return
    }
    const seq = ++this._seq
    const url = new URL(this.url, window.location.origin)
    url.searchParams.delete("range"); url.searchParams.delete("from"); url.searchParams.delete("to")
    if (this.range === "custom") {
      url.searchParams.set("from", this.fromTarget.value)
      url.searchParams.set("to", this.toTarget.value)
    } else {
      url.searchParams.set("range", this.range)
    }

    this.statusTarget.textContent = t("results.timeline_loading")
    // Refetch keeps the frame: the previous chart stays, dimmed, until the new
    // one lands — no blank, no jump.
    this.chartTarget.classList.add("is-stale")
    try {
      const res  = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      const data = await res.json()
      if (seq !== this._seq) return
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`)
      this._data = data
      if (!data.series.some(s => s.key === this.key)) this.key = data.series[0]?.key ?? ""
      this._render()
    } catch {
      if (seq === this._seq) this.statusTarget.textContent = t("results.timeline_error")
    } finally {
      if (seq === this._seq) this.chartTarget.classList.remove("is-stale")
    }
  }

  // ── Rendering ──────────────────────────────────────────────────────────────

  _render() {
    const d = this._data
    if (!d) return
    const { series, periods } = d
    const idx = Math.max(0, series.findIndex(s => s.key === this.key))
    // Per series, per period: null where the period's counts are withheld.
    const shares = series.map((_, s) => periods.map(p => p.counts ? (p.n ? p.counts[s] / p.n * 100 : 0) : null))
    const values = this.mode === "count"
      ? series.map((_, s) => periods.map(p => p.counts ? p.counts[s] : null))
      : shares

    this._renderStats(shares[idx], periods, d.granularity)
    this._renderChart(values, idx, periods, d)
    this._renderLegend(series, idx)
    this.statusTarget.textContent = periods.some(p => p.counts) ? "" : t("results.timeline_empty")
  }

  // Three figures for the emphasised answer, always in share: the latest
  // period with numbers, its change against the (up to) four before it, and
  // the peak. Withheld periods take no part.
  _renderStats(share, periods, granularity) {
    const known = share.map((v, i) => (v == null ? null : i)).filter(i => i != null)
    this.nowLabelTarget.textContent = t("results.timeline_latest")
    if (!known.length) {
      this.nowTarget.textContent = "–"
      this.changeLabelTarget.textContent = t("results.timeline_change", { n: 0 })
      this.changeTarget.textContent = "–"
      this.changeTarget.style.color = ""
      this.peakTarget.textContent = "–"
      this.peakWhenTarget.textContent = ""
      return
    }
    const last  = known[known.length - 1]
    const prev  = known.slice(-5, -1)
    const mean  = prev.length ? prev.reduce((a, i) => a + share[i], 0) / prev.length : null
    const delta = mean == null ? null : Math.round(share[last] - mean)
    const peak  = known.reduce((best, i) => (share[i] > share[best] ? i : best), known[0])

    this.nowTarget.textContent = Math.round(share[last]) + "%"
    this.changeLabelTarget.textContent = t("results.timeline_change", { n: prev.length })
    this.changeTarget.textContent = delta == null ? "–" : t("results.timeline_pts", { n: (delta > 0 ? "+" : "") + delta })
    this.changeTarget.style.color = delta > 0 ? ACCENT : delta < 0 ? "#FF6FA0" : ""
    this.peakTarget.textContent = Math.round(share[peak]) + "%"
    this.peakWhenTarget.textContent = this._periodName(periods[peak], granularity)
  }

  _renderChart(values, idx, periods, data) {
    const box = this.chartTarget
    box.replaceChildren()
    const W = Math.max(240, box.clientWidth || 300)
    const R = W - RIGHT_PAD
    const n = periods.length
    const flat = values.flat().filter(v => v != null)
    const rawMax = flat.length ? Math.max(...flat) : 0
    const yMax = this.mode === "count" ? niceMax(rawMax) : (rawMax > 80 ? 100 : rawMax > 60 ? 80 : rawMax > 40 ? 60 : 40)
    const x = i => (n <= 1 ? (LEFT + R) / 2 : LEFT + ((R - LEFT) * i) / (n - 1))
    const y = v => BOTTOM - ((BOTTOM - TOP) * v) / yMax
    const fmt = v => (this.mode === "count" ? String(Math.round(v)) : Math.round(v) + "%")

    const svg = el("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img" })
    svg.setAttribute("aria-label", `${data.series[idx]?.label ?? ""} — ${this.questionTarget.textContent}`)

    // Recessive grid: the baseline, the midpoint and the top, with their values.
    for (const f of [ 0, 0.5, 1 ]) {
      const yy = BOTTOM - (BOTTOM - TOP) * f
      svg.append(el("line", { x1: LEFT, y1: yy, x2: R, y2: yy, stroke: f === 0 ? "rgba(255,255,255,0.14)" : "rgba(255,255,255,0.08)", "stroke-width": 1 }))
      svg.append(text(LEFT - 6, yy + 4, fmt(yMax * f), "end"))
    }
    if (n) {
      svg.append(text(LEFT, 164, periods[0].label, "start"))
      if (n > 2) svg.append(text((LEFT + R) / 2, 164, periods[Math.floor((n - 1) / 2)].label, "middle"))
      if (n > 1) svg.append(text(R, 164, periods[n - 1].label, "end"))
    }

    // Every other answer, grey and thin, under the one the tab is about.
    values.forEach((vals, s) => {
      if (s === idx) return
      const d = pathOf(vals, x, y)
      if (d) svg.append(el("path", { d, fill: "none", stroke: MUTED, "stroke-width": 1.5, "stroke-linejoin": "round", "stroke-linecap": "round" }))
    })

    const mine = values[idx] || []
    for (const run of runs(mine)) {
      svg.append(el("path", { d: areaOf(run, mine, x, y), fill: ACCENT, "fill-opacity": 0.12 }))
    }
    const lineD = pathOf(mine, x, y)
    if (lineD) svg.append(el("path", { d: lineD, fill: "none", stroke: ACCENT, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }))
    // A point with no neighbour draws no line, so it gets a dot of its own.
    mine.forEach((v, i) => {
      if (v == null) return
      const alone = (i === 0 || mine[i - 1] == null) && (i === n - 1 || mine[i + 1] == null)
      if (alone) svg.append(el("circle", { cx: x(i), cy: y(v), r: 3.5, fill: ACCENT, stroke: "#232A47", "stroke-width": 2 }))
    })
    const last = lastIndex(mine)
    if (last >= 0) {
      svg.append(el("circle", { cx: x(last), cy: y(mine[last]), r: 4, fill: ACCENT, stroke: "#232A47", "stroke-width": 2 }))
      svg.append(text(R + 8, y(mine[last]) + 4, fmt(mine[last]), "start", "#ffffff"))
    }

    // The hover layer: a crosshair that snaps to the nearest period, and a
    // tooltip listing every answer's value there.
    const cross = el("g", { opacity: 0 })
    const vline = el("line", { x1: 0, y1: TOP, x2: 0, y2: BOTTOM, stroke: "rgba(255,255,255,0.35)", "stroke-width": 1 })
    const dot   = el("circle", { cx: 0, cy: 0, r: 5, fill: ACCENT, stroke: "#232A47", "stroke-width": 2 })
    cross.append(vline, dot)
    svg.append(cross)

    const tip = document.createElement("div")
    tip.className = "rc-timeline-tip"
    tip.hidden = true

    const hit = el("rect", { x: LEFT - 10, y: 0, width: R - LEFT + 20, height: 152, fill: "transparent" })
    hit.style.cursor = "crosshair"
    hit.addEventListener("pointermove", (e) => {
      if (!n) return
      const rect = svg.getBoundingClientRect()
      const px = ((e.clientX - rect.left) * W) / rect.width
      let i = Math.round(((px - LEFT) / Math.max(1, R - LEFT)) * (n - 1))
      i = Math.max(0, Math.min(n - 1, i))
      const v = mine[i]
      vline.setAttribute("x1", x(i)); vline.setAttribute("x2", x(i))
      if (v == null) { dot.setAttribute("opacity", 0) } else { dot.setAttribute("opacity", 1); dot.setAttribute("cx", x(i)); dot.setAttribute("cy", y(v)) }
      cross.setAttribute("opacity", 1)
      this._paintTip(tip, i, values, idx, periods, data, fmt)
      const left = x(i) + 12 + 160 > W ? x(i) - 172 : x(i) + 12
      const top  = Math.max(0, Math.min((v == null ? 60 : y(v)) - 30, H - 24))
      tip.style.left = `${Math.max(0, left)}px`
      tip.style.top  = `${top}px`
      tip.hidden = false
    })
    hit.addEventListener("pointerleave", () => { cross.setAttribute("opacity", 0); tip.hidden = true })
    svg.append(hit)

    box.append(svg, tip)
  }

  _paintTip(tip, i, values, idx, periods, data, fmt) {
    tip.replaceChildren()
    const title = document.createElement("div")
    title.className = "rc-timeline-tip-title"
    title.textContent = this._periodName(periods[i], data.granularity)
    tip.append(title)
    if (!periods[i].counts) {
      const row = document.createElement("div")
      row.className = "rc-timeline-tip-row"
      row.textContent = t("results.timeline_thin", { count: data.min_answers })
      tip.append(row)
      return
    }
    data.series.forEach((s, k) => {
      const row = document.createElement("div")
      row.className = "rc-timeline-tip-row" + (k === idx ? " is-on" : "")
      const key = document.createElement("span")
      key.className = "rc-timeline-key" + (k === idx ? " is-on" : "")
      const label = document.createElement("span")
      label.className = "rc-timeline-tip-label"
      label.textContent = s.label
      const value = document.createElement("b")
      value.textContent = fmt(values[k][i])
      row.append(key, label, value)
      tip.append(row)
    })
  }

  _renderLegend(series, idx) {
    const box = this.legendTarget
    box.replaceChildren()
    series.forEach((s, k) => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "rc-timeline-lg" + (k === idx ? " is-on" : "")
      btn.dataset.action = "click->answer-timeline#pick"
      btn.dataset.answerTimelineKeyParam = s.key
      btn.setAttribute("aria-pressed", String(k === idx))
      const key = document.createElement("span")
      key.className = "rc-timeline-key" + (k === idx ? " is-on" : "")
      const label = document.createElement("span")
      label.textContent = s.label
      btn.append(key, label)
      box.append(btn)
    })
  }

  _periodName(period, granularity) {
    return granularity === "week" ? t("results.timeline_wc", { date: period.label }) : period.label
  }

  _paintRange() {
    this.rangeBtnTargets.forEach(b => {
      const on = b.dataset.range === this.range
      b.classList.toggle("is-on", on)
      b.setAttribute("aria-pressed", String(on))
    })
    this.customTarget.hidden = this.range !== "custom"
  }

  _paintMode() {
    this.modeBtnTargets.forEach(b => {
      const on = b.dataset.mode === this.mode
      b.classList.toggle("is-on", on)
      b.setAttribute("aria-pressed", String(on))
    })
  }

  _markRow(row) {
    document.querySelectorAll(".rc-row.is-picked").forEach(r => r.classList.remove("is-picked"))
    if (row) row.classList.add("is-picked")
  }
}

// ── SVG helpers ──────────────────────────────────────────────────────────────

function el(name, attrs) {
  const node = document.createElementNS(SVG_NS, name)
  for (const [ k, v ] of Object.entries(attrs)) node.setAttribute(k, v)
  return node
}

function text(x, y, content, anchor, fill = "rgba(255,255,255,0.45)") {
  const node = el("text", { x, y, "text-anchor": anchor, "font-size": 10, fill, "font-family": "Alata, sans-serif" })
  node.textContent = content
  return node
}

// A path through the known points; a withheld period lifts the pen, so a gap
// is drawn as a gap rather than a line pretending to know.
function pathOf(vals, x, y) {
  let d = "", pen = false
  vals.forEach((v, i) => {
    if (v == null) { pen = false; return }
    d += (pen ? " L" : " M") + x(i).toFixed(1) + "," + y(v).toFixed(1)
    pen = true
  })
  return d.trim()
}

// [first, last] index pairs of each run of known points at least two long.
function runs(vals) {
  const out = []
  let cur = null
  vals.forEach((v, i) => {
    if (v == null) { if (cur) out.push(cur); cur = null; return }
    if (!cur) cur = [ i, i ]
    cur[1] = i
  })
  if (cur) out.push(cur)
  return out.filter(r => r[1] > r[0])
}

function areaOf([ a, b ], vals, x, y) {
  let d = ""
  for (let i = a; i <= b; i++) d += (i === a ? "M" : " L") + x(i).toFixed(1) + "," + y(vals[i]).toFixed(1)
  return d + ` L${x(b).toFixed(1)},${BOTTOM} L${x(a).toFixed(1)},${BOTTOM} Z`
}

function lastIndex(vals) {
  for (let i = vals.length - 1; i >= 0; i--) if (vals[i] != null) return i
  return -1
}

function niceMax(v) {
  if (v <= 0) return 5
  const step = v > 200 ? 100 : v > 100 ? 50 : v > 50 ? 20 : v > 20 ? 10 : 5
  return Math.ceil(v / step) * step
}

function cssEscape(value) {
  return (window.CSS && CSS.escape) ? CSS.escape(value) : value.replace(/["\\]/g, "\\$&")
}
