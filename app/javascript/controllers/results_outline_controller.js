import { Controller } from "@hotwired/stimulus"

// The results feed's scroll position, and the two things that read it.
//
// ONE controller for both jobs on purpose: the outline's "where am I" and the
// header's condense-on-scroll are the same measurement taken twice, and two
// controllers would mean two scroll listeners on the same node, two rAF
// schedulers and two chances to disagree about where the reader is.
//
// The page itself never scrolls — the shell is a fixed-height flex column and
// the div inside .results-stage is what moves (see results.html.erb) — so
// every measurement here is against that element, not the window.
const CONDENSE_ON  = 64   // px scrolled before the header gives its space back
const CONDENSE_OFF = 24   // …and before it takes it back, so a scroll that
                          // hovers on the threshold doesn't flap
const READING_LINE = 120  // the card under this point is the one you're reading

export default class extends Controller {
  static targets = [ "scroller", "header", "outline", "list", "item", "count" ]

  connect() {
    this._cards = []
    this._current = -1
    this._condensed = false
    this._scrollHeight = 0

    this._onScroll = () => this._schedule()
    this.scrollerTarget.addEventListener("scroll", this._onScroll, { passive: true })

    this._onResize = () => { this._measure(); this._update() }
    window.addEventListener("resize", this._onResize)

    // Auto-refresh replaces the results-feed frame with fresh counts, and the
    // wave/leaderboard cards above the questions can change height with it.
    this._onFrame = () => { this._syncCounts(); this._measure(); this._update() }
    document.addEventListener("turbo:frame-render", this._onFrame)

    this._measure()
    this._update()
    // The map band sizes itself from its data after a fetch resolves
    // (results_compare#_fitHomeView), which moves every card below it. One
    // re-measure after that has had a chance to land; a ResizeObserver would
    // be the general answer, but this is one known, one-off reflow.
    this._settle = setTimeout(() => { this._measure(); this._update() }, 900)
  }

  disconnect() {
    this.scrollerTarget.removeEventListener("scroll", this._onScroll)
    window.removeEventListener("resize", this._onResize)
    document.removeEventListener("turbo:frame-render", this._onFrame)
    clearTimeout(this._settle)
    if (this._raf) cancelAnimationFrame(this._raf)
  }

  // Jump to a question. preventDefault because the anchor would work — the
  // cards carry the ids — but the browser scrolls the container flush to the
  // card's top edge, with no room above it and no smoothing.
  go(event) {
    event.preventDefault()
    const i = Number(event.params.index)
    // Measured fresh rather than trusting the cache: this is an explicit
    // request to land on a specific card, and anything that changed the feed's
    // height without changing its scrollHeight — a summary expanding, a menu
    // closing — would otherwise send the reader somewhere near it.
    this._measure()
    const card = this._cards[i]
    if (!card) return

    this.scrollerTarget.scrollTo({ top: Math.max(0, card.top - 16), behavior: "smooth" })
  }

  // ── internals ─────────────────────────────────────────────────────────────

  _schedule() {
    if (this._raf) return
    this._raf = requestAnimationFrame(() => { this._raf = null; this._update() })
  }

  // Card positions WITHIN the scrolled content. Read from bounding rects
  // rather than offsetTop, which is relative to whichever ancestor happens to
  // be positioned (.results-stage today) and would silently change meaning if
  // anything between here and the card gained a `position`.
  _measure() {
    const scroller = this.scrollerTarget
    const base = scroller.getBoundingClientRect().top - scroller.scrollTop
    this._cards = Array.from(scroller.querySelectorAll(".rc-card")).map(el => ({
      el, top: el.getBoundingClientRect().top - base
    }))
    this._scrollHeight = scroller.scrollHeight
  }

  _update() {
    const scroller = this.scrollerTarget
    // Anything that changed the feed's height moved the cards with it — an
    // image landing, a summary expanding, a menu opening. Cheaper to notice
    // here than to observe every one of them.
    if (scroller.scrollHeight !== this._scrollHeight) this._measure()

    this._condense(scroller.scrollTop)
    this._spy(scroller.scrollTop)
  }

  _condense(y) {
    const want = this._condensed ? y > CONDENSE_OFF : y > CONDENSE_ON
    if (want === this._condensed) return
    this._condensed = want
    if (this.hasHeaderTarget) this.headerTarget.classList.toggle("is-condensed", want)
  }

  _spy(y) {
    if (!this.hasItemTarget || this._cards.length === 0) return

    const line = y + READING_LINE
    let i = 0
    while (i + 1 < this._cards.length && this._cards[i + 1].top <= line) i++
    // At the very bottom the last card may never reach the reading line —
    // there is nothing below it to push it up — so scrolling to the end marks
    // the end.
    if (y + this.scrollerTarget.clientHeight >= this.scrollerTarget.scrollHeight - 4) {
      i = this._cards.length - 1
    }
    if (i === this._current) return

    this.itemTargets.forEach((item, n) => {
      const on = n === i
      item.classList.toggle("is-current", on)
      if (on) item.setAttribute("aria-current", "true")
      else item.removeAttribute("aria-current")
    })
    this._current = i
    this._reveal(this.itemTargets[i])
  }

  // Keep the marked row visible inside the rail's own scroller. Done by hand
  // rather than with scrollIntoView, which walks every scrollable ancestor —
  // and one of those is the feed, which would mean the outline scrolling the
  // page it is only meant to be reporting on.
  _reveal(item) {
    if (!item || !this.hasListTarget) return
    const list = this.listTarget
    const top = item.offsetTop
    const bottom = top + item.offsetHeight
    if (top < list.scrollTop) list.scrollTop = top - 4
    else if (bottom > list.scrollTop + list.clientHeight) list.scrollTop = bottom - list.clientHeight + 4
  }

  // The frame carries the live numbers; the rail is outside it. Read each
  // card's own answer count back out rather than re-rendering the rail, which
  // would mean a second copy of its template in JavaScript.
  _syncCounts() {
    if (!this.hasCountTarget) return
    const cards = this.scrollerTarget.querySelectorAll(".rc-card")
    this.countTargets.forEach((el, i) => {
      const n = cards[i]?.querySelector(".rc-answers")?.textContent.match(/\d[\d,]*/)
      if (n) el.textContent = n[0]
    })
  }
}
