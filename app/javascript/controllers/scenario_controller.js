import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { MAX_PAGES } from "lib/page_limits"

// Book-style page-turn widget for the "scenario" question type — narrative
// pages the respondent (or, in the editor, the creator) turns through one at
// a time, landing on an ordinary single-select .choice-list as the final
// "page". One controller drives both the editor (editableValue: true — adds
// per-page add/delete, contenteditable text) and the player (editableValue:
// false — read-only pages, real Next/Back page-turn), modeled on
// tap_stack_controller.js's bounded, absolutely-positioned card stack.
export default class extends Controller {
  static targets = [
    "stack", "page", "dots", "prevBtn", "nextBtn",
    "editTools", "addPageBtn", "delPageBtn", "live"
  ]
  static values = { editable: Boolean }

  connect() {
    this.current = 0
    // In form mode the deck loses its ambient motion (see tap-stack), so the
    // page-turn just snaps instead of animating.
    this.formsMode = !!this.element.closest(".forms-mode")
    this._pageSeq = 0
    // The card's question text/eyebrow (.q-header) is shared markup rendered
    // once above every type's answer widget — for scenario it belongs to the
    // final choice, not the story, so it's hidden while flipping through
    // narrative pages and only revealed on the answer page (see layout()).
    // It lives outside .book-wrap (this controller's root), so it's resolved
    // via the shared .split-right ancestor rather than a Stimulus target.
    this._header = this.element.closest(".split-right")?.querySelector(".q-header") || null
    this.layout()
  }

  // Whether the book is showing its final (answer) page — used by
  // player_controller to decide whether the deck's global Next should turn a
  // page instead of advancing to the next card.
  get atAnswerPage() {
    return this.current >= this.pageTargets.length - 1
  }

  // Turn forward. Returns true if a page actually turned (false at the last
  // page) — player_controller relies on this to know whether to fall through
  // to its own Next behaviour.
  next(event) {
    if (event) event.preventDefault()
    return this._turn(1)
  }

  back(event) {
    if (event) event.preventDefault()
    return this._turn(-1)
  }

  _turn(delta) {
    const next = this.current + delta
    if (next < 0 || next > this.pageTargets.length - 1) return false
    this.current = next
    this.layout()
    return true
  }

  // Insert a new blank page right after the one currently open (never after
  // the answer page, which must stay last) and jump straight to it.
  addPage(event) {
    if (event) event.preventDefault()
    if (!this.hasStackTarget) return
    const pages = this.pageTargets
    // Refuse rather than let the server drop it. The sanitiser keeps only the
    // first MAX_PAGES, so before this a creator could write a seventh page,
    // watch it save, and find it gone on reload with nothing having said so.
    // pages includes the answer page, which is not a narrative page.
    if ((pages.length - 1) >= MAX_PAGES) {
      if (this.hasLiveTarget) this.liveTarget.textContent = t("editor.scenario.page_limit", { max: MAX_PAGES })
      if (this.hasAddPageBtnTarget) this.addPageBtnTarget.disabled = true
      return
    }
    const anchor = pages[Math.min(this.current, pages.length - 2)]
    const el = this._buildPage("")
    if (anchor) anchor.after(el)
    else this.stackTarget.insertBefore(el, this.stackTarget.firstChild)

    this.current = Math.min(this.current + 1, this.pageTargets.length - 1)
    this._renumber()
    this.layout()
    this.dispatch("changed")

    const text = el.querySelector('[data-scenario-target="pageText"]')
    text?.focus()
  }

  // Remove the page currently open. Always keeps at least one narrative page,
  // and never touches the answer page (options are removed individually via
  // card-editor#deleteOption on the choice list itself).
  deletePage(event) {
    if (event) event.preventDefault()
    const pages = this.pageTargets
    if (pages.length - 1 <= 1) return // only one narrative page left
    const target = pages[this.current]
    if (!target || target.classList.contains("is-answer")) return
    target.remove()
    this.current = Math.min(this.current, this.pageTargets.length - 1)
    this._renumber()
    this.layout()
    this.dispatch("changed")
  }

  _buildPage(text) {
    const el = document.createElement("div")
    el.className = "book-page"
    el.dataset.scenarioTarget = "page"
    // Client-assigned id, good enough to persist as-is (mirrors the option-uid
    // trick elsewhere) — Survey.sanitize_scenario_pages! backfills any gaps.
    el.dataset.pageId = `pg_new_${Date.now()}_${this._pageSeq++}`
    el.innerHTML = `
      <div class="book-page-scroll">
        <div class="book-page-kicker" data-scenario-target="kicker"></div>
        <div class="book-page-text" contenteditable="true" data-rich-text data-scenario-target="pageText"
             data-placeholder="${this._esc(t("editor.scenario.page_placeholder"))}">${this._esc(text)}</div>
      </div>
      <div class="book-page-corner"></div>
      <div class="book-page-fade"></div>`
    return el
  }

  _renumber() {
    const pages = this.pageTargets
    const total = pages.length - 1 // narrative pages only, excludes the answer page
    pages.forEach((page, i) => {
      if (page.classList.contains("is-answer")) return
      const kicker = page.querySelector('[data-scenario-target="kicker"]')
      if (kicker) kicker.textContent = t("editor.scenario.page_of", { n: i + 1, total })
      const corner = page.querySelector(".book-page-corner")
      if (corner) corner.textContent = String(i + 1)
    })
  }

  layout() {
    const pages = this.pageTargets
    pages.forEach((page, i) => {
      const pos = i - this.current
      let transform
      // A turned page fades on a delayed, longer curve (see .book-page.is-turning)
      // so the rotation stays legible instead of vanishing mid-arc.
      page.classList.toggle("is-turning", pos < 0)
      if (pos < 0) {
        // Stops short of edge-on: past about 105deg there's nothing left to see,
        // so the extra rotation was only shortening the visible part of the turn.
        transform = "rotateY(-104deg) translateX(-6px)"
        page.style.opacity = "0"
        page.style.zIndex = 0
        page.style.pointerEvents = "none"
      } else if (pos === 0) {
        transform = "rotateY(0deg) translateY(0) scale(1)"
        page.style.opacity = "1"
        page.style.zIndex = 40
        page.style.pointerEvents = "auto"
      } else {
        // More travel than before (7px / 0.04) — the arriving page barely moved,
        // so a turn gave almost no sense of a new page coming forward.
        const scale = Math.max(1 - pos * 0.05, 0.85)
        transform = `rotateY(0deg) translateY(${pos * 13}px) scale(${scale})`
        page.style.opacity = String(Math.max(1 - pos * 0.3, 0))
        page.style.zIndex = 40 - pos
        page.style.pointerEvents = "none"
      }
      page.style.transition = this.formsMode ? "none" : ""
      page.style.transform = transform
      // The visual stack hides non-current pages with opacity/pointer-events
      // only, which leaves every page in the accessibility tree and tab order
      // at once — a screen reader hears the whole book on arrival. inert
      // removes them from both; aria-hidden is the belt to its braces on
      // engines older than inert (pre-iOS 15.5 / Chrome 102).
      page.toggleAttribute("inert", pos !== 0)
      page.setAttribute("aria-hidden", String(pos !== 0))
      this._checkOverflow(page)
    })

    this._syncDots()
    // The player teaches each long page to scroll as it is turned to; it
    // cannot see a turn any other way.
    this.dispatch("turned", { detail: { page: this.current } })

    const atAnswer = this.atAnswerPage
    this._header?.classList.toggle("book-header-visible", atAnswer)
    if (this.hasPrevBtnTarget) this.prevBtnTarget.disabled = this.current === 0
    if (this.hasNextBtnTarget) {
      this.nextBtnTarget.disabled = atAnswer
      if (this.editableValue) {
        this.nextBtnTarget.textContent = atAnswer
          ? t("editor.scenario.end_of_card")
          : (this.current === pages.length - 2 ? t("editor.scenario.edit_options") : t("editor.scenario.next_page_btn"))
      }
    }
    if (this.hasEditToolsTarget) this.editToolsTarget.style.visibility = atAnswer ? "hidden" : "visible"
    if (this.hasDelPageBtnTarget) this.delPageBtnTarget.disabled = (pages.length - 1) <= 1
    // Grey the add button at the cap, so the limit is visible before it is hit
    // rather than only announced when it is.
    if (this.hasAddPageBtnTarget) this.addPageBtnTarget.disabled = (pages.length - 1) >= MAX_PAGES

    if (this.hasLiveTarget) {
      this.liveTarget.textContent = atAnswer
        ? t(this.editableValue ? "editor.scenario.answer_kicker" : "editor.scenario.choose_kicker")
        : t("editor.scenario.page_of", { n: this.current + 1, total: pages.length - 1 })
    }
  }

  _checkOverflow(page) {
    const scroll = page.querySelector(".book-page-scroll")
    if (!scroll) return
    page.classList.toggle("has-more", scroll.scrollHeight > scroll.clientHeight + 1)
  }

  _syncDots() {
    if (!this.hasDotsTarget) return
    const total = this.pageTargets.length
    const box = this.dotsTarget
    while (box.children.length < total) {
      const d = document.createElement("span")
      d.className = "book-dot"
      box.appendChild(d)
    }
    while (box.children.length > total) box.lastElementChild.remove()
    Array.from(box.children).forEach((dot, i) => {
      dot.classList.toggle("done", i < this.current)
      dot.classList.toggle("active", i === this.current)
      dot.classList.toggle("answer", i === total - 1)
    })
  }

  _esc(s) {
    return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }
}
