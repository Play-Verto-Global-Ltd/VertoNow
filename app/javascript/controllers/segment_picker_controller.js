import { Controller } from "@hotwired/stimulus"

// Keeps the results page's segment picker open across the visit a pill click
// starts, so a combination can be built pill by pill: click Austria, and the
// panel is still there for Male, and then for 25–34.
//
// Each pill is a link to a whole page — the filters decide what every card
// counts, so a change is a full render (see _results_header) — and a
// navigation closes every <details> on the page. This reopens the one the
// click came from. Only a pill inside the panel sets the flag, and only when
// it leaves something selected: Overall is "I am done", and a panel that
// reopened over the numbers it had just been asked for would be in the way.
//
// sessionStorage rather than a URL parameter: the flag is about this tab's
// gesture, not the page, and a bookmarked or shared results link should open
// with the panel shut. Wrapped, because storage can be refused (a private
// window with site data blocked) and a picker that throws on click is worse
// than one that closes.
const KEY = "results:segment-picker-open"
// The gap kept between the panel and the window's edge when it is pulled back.
const EDGE_PX = 16

export default class extends Controller {
  connect() {
    // Turbo shows a cached preview of a previously visited URL before the
    // fresh render lands; both connect a controller, and consuming the flag
    // on the preview would open the copy that is about to be thrown away.
    if (document.documentElement.hasAttribute("data-turbo-preview")) return

    let reopen = false
    try {
      reopen = sessionStorage.getItem(KEY) === "1"
      sessionStorage.removeItem(KEY)
    } catch {}
    this._onToggle = () => this._fit()
    this.element.addEventListener("toggle", this._onToggle)
    if (reopen) this.element.open = true
  }

  disconnect() {
    this.element.removeEventListener("toggle", this._onToggle)
  }

  // The panel hangs from the picker's start edge and is as wide as its widest
  // row, up to 760px — and the picker sits a good way along the header, so a
  // long row (six countries, or the five integrity bands) used to run it off
  // the right of the window. Pulled back by exactly the overhang, never past
  // the window's start; the CSS's own max-width still keeps it narrower than
  // the window. Measured on every open, because rows differ page to page.
  _fit() {
    const panel = this.element.querySelector(".rh-segments-panel")
    if (!panel) return
    panel.style.removeProperty("inset-inline-start")
    if (!this.element.open) return

    const box  = panel.getBoundingClientRect()
    const rtl  = getComputedStyle(panel).direction === "rtl"
    const over = rtl ? EDGE_PX - box.left : box.right - (window.innerWidth - EDGE_PX)
    if (over <= 0) return

    const room = rtl ? window.innerWidth - EDGE_PX - box.right : box.left - EDGE_PX
    panel.style.setProperty("inset-inline-start", `-${Math.max(0, Math.min(over, room))}px`)
  }

  // click->segment-picker#remember on the <details>: a pill inside the panel
  // leads to a page with something selected iff its href carries a segment.
  remember(event) {
    const pill = event.target.closest("a.rh-seg")
    if (!pill || !this.element.contains(pill)) return

    let keep = false
    try { keep = new URL(pill.href, location.href).searchParams.has("segment") } catch {}
    try { sessionStorage.setItem(KEY, keep ? "1" : "0") } catch {}
  }
}
