import { Controller } from "@hotwired/stimulus"

// Read-only country tinting for the public shared-results page and a
// partner's results page. A trimmed cousin of results_compare_controller.js's
// _paintMap: no click-to-compare (there's no compare panel here — a fixed
// org-scoped survey_results_compare URL wouldn't resolve for an anonymous
// viewer anyway), just colour by response count and a hover tooltip, off the
// same #results-region-map-data JSON contract the owner's page renders — then
// framed on the countries that answered, as the owner's map is (_fitHomeView):
// a partner whose people are all in the UK and Ireland otherwise reads a
// world map with a speck on it.
export default class extends Controller {
  connect() {
    const svg = this.element.querySelector(".world-map")
    const dataEl = document.getElementById("results-region-map-data")
    if (!svg || !dataEl) return

    let mapData
    try { mapData = JSON.parse(dataEl.textContent) } catch (_e) { return }

    const max = Math.max(1, ...Object.values(mapData).map(d => d.count))
    Object.entries(mapData).forEach(([ cc, d ]) => {
      const el = svg.querySelector("#" + cc)
      if (!el) return
      const paths = el.tagName.toLowerCase() === "g" ? el.querySelectorAll("path") : [ el ]
      const alpha = d.count === 0 ? 0.14 : 0.18 + 0.72 * (d.count / max)
      paths.forEach(p => { p.style.fill = `rgba(1,234,203,${alpha.toFixed(2)})` })

      if (d.count > 0) {
        const tip = document.createElementNS("http://www.w3.org/2000/svg", "title")
        tip.textContent = `${d.name}: ${d.count}`
        el.appendChild(tip)
      }
    })

    this._fit(svg, mapData)
  }

  // The owner map's frame, without its animation or its band resizing: the
  // box keeps the whole map's aspect, so the map's height on the page never
  // changes — only what it is looking at. No countries, the whole world.
  _fit(svg, mapData) {
    const full = (svg.getAttribute("viewBox") || "").trim().split(/\s+/).map(Number)
    if (full.length !== 4 || full.some(Number.isNaN)) return

    const boxes = Object.entries(mapData)
      .filter(([ , d ]) => d.count > 0)
      .map(([ cc ]) => svg.querySelector("#" + cc))
      .filter(Boolean)
      .map(el => (el.querySelector(".mainland") || el).getBBox())
      .filter(b => b.width > 0 && b.height > 0)
    if (!boxes.length) return

    let x0 = Math.min(...boxes.map(b => b.x))
    let y0 = Math.min(...boxes.map(b => b.y))
    let x1 = Math.max(...boxes.map(b => b.x + b.width))
    let y1 = Math.max(...boxes.map(b => b.y + b.height))

    // Breathing room, and a floor: one small country fitted tightly is a
    // close-up of a coastline, not a place.
    const pad = Math.max((x1 - x0) * 0.35, (y1 - y0) * 0.35, 30)
    x0 -= pad; x1 += pad; y0 -= pad; y1 += pad
    let w = Math.max(x1 - x0, 150)
    let h = Math.max(y1 - y0, 75)
    const cx = (x0 + x1) / 2
    const cy = (y0 + y1) / 2

    // Grow the short axis to the map's own aspect — growing, never cropping —
    // then keep the box inside the world.
    const [ fx, fy, fw, fh ] = full
    if (w / h < fw / fh) w = h * (fw / fh)
    else h = w / (fw / fh)
    w = Math.min(w, fw)
    h = Math.min(h, fh)
    svg.setAttribute("viewBox", [
      Math.min(Math.max(cx - w / 2, fx), fx + fw - w),
      Math.min(Math.max(cy - h / 2, fy), fy + fh - h),
      w, h
    ].join(" "))
  }
}
