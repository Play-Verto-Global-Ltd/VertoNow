import { Controller } from "@hotwired/stimulus"
import { EMOJI_CATEGORIES, ALL_EMOJI, searchEmoji } from "lib/emoji_library"
import { t } from "lib/i18n"

// A shared emoji picker for every emoji field in the editor.
//
// Before this, the only way to put an emoji anywhere — an option's icon, a
// token type — was the operating system's own emoji keyboard (⌃⌘Space, or the
// Windows/mobile equivalent). Plenty of creators don't know it exists, and on
// some setups it isn't reachable at all, so the fields looked decorative.
//
// One popover serves every field: a trigger button sets `_input` to the input
// it belongs to, and picking writes the value and dispatches a real `input`
// event so the field's existing handler (option-style#onEmoji,
// token-types#save) runs exactly as if it had been typed.
export default class extends Controller {
  static targets = [ "popover", "search", "grid", "tabs" ]

  // The browse grid used to render the curated set and nothing else, which is
  // where "more emoji's needed" came from the second time. The FULL set has
  // been searchable since August — around 1,500 glyphs, terms taken from their
  // Unicode names — but only if you already guessed the word. Nothing let you
  // simply look, so to a creator scrolling the tabs the library was however
  // many the tabs held.
  //
  // The last tab browses ALL_EMOJI itself. In pages, because a single grid of
  // 1,500 buttons is a long paint for something most creators scroll a little
  // of: a page renders, and the next appends when the scroll gets near the
  // bottom. Curated-first ordering is inherited from ALL_EMOJI, so the ones
  // people actually pick are still the ones at the top.
  static ALL_KEY  = "__all"
  static PAGE     = 182   // 26 rows of 7 — a bit over two screens of the grid
  static NEAR_END = 240   // px from the bottom at which the next page appends

  connect() {
    this._input = null
    this._category = EMOJI_CATEGORIES[0]?.key
    this._allShown = 0
    this._onGridScroll = () => this._maybeExtend()
    this._escListener = (e) => { if (e.key === "Escape") this.close() }
    this._outsideListener = (e) => {
      if (this.popoverTarget.hidden) return
      if (this.popoverTarget.contains(e.target)) return
      if (e.target.closest("[data-emoji-picker-trigger]")) return
      this.close()
    }
    document.addEventListener("keydown", this._escListener)
    document.addEventListener("mousedown", this._outsideListener)
    if (this.hasGridTarget) this.gridTarget.addEventListener("scroll", this._onGridScroll, { passive: true })
    this._renderTabs()
  }

  disconnect() {
    document.removeEventListener("keydown", this._escListener)
    document.removeEventListener("mousedown", this._outsideListener)
    if (this.hasGridTarget) this.gridTarget.removeEventListener("scroll", this._onGridScroll)
  }

  // Opened by any button carrying data-emoji-picker-trigger. The field it
  // fills is the one named by data-emoji-picker-for (a selector) or, failing
  // that, the nearest input beside the button — so a trigger can be dropped
  // next to a field without wiring anything up.
  open(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event.currentTarget
    const selector = trigger.dataset.emojiPickerFor
    this._input = (selector && document.querySelector(selector)) ||
      trigger.parentElement?.querySelector("input[type='text'], input:not([type])")
    if (!this._input) return

    this.searchTarget.value = ""
    this._category = EMOJI_CATEGORIES[0]?.key
    this._renderTabs()
    this._renderGrid()
    this.popoverTarget.hidden = false
    this._position(trigger)
    this.searchTarget.focus()
  }

  close() {
    this.popoverTarget.hidden = true
    this._input = null
  }

  onSearch() {
    this._renderGrid()
  }

  pickCategory(event) {
    this._category = event.currentTarget.dataset.category
    this._renderTabs()
    if (this.hasGridTarget) this.gridTarget.scrollTop = 0
    this._renderGrid()
  }

  // Writing the value is only half of it — the `input` event is what makes the
  // owning controller persist it, so a picked emoji behaves exactly like a
  // typed one.
  pick(event) {
    const emoji = event.currentTarget.dataset.emoji
    if (!this._input || !emoji) return
    this._input.value = emoji
    this._input.dispatchEvent(new Event("input", { bubbles: true }))
    this._input.dispatchEvent(new Event("change", { bubbles: true }))
    this.close()
  }

  clear() {
    if (!this._input) return
    this._input.value = ""
    this._input.dispatchEvent(new Event("input", { bubbles: true }))
    this._input.dispatchEvent(new Event("change", { bubbles: true }))
    this.close()
  }

  _renderTabs() {
    if (!this.hasTabsTarget) return
    // Category labels are still hardcoded English in lib/emoji_library.js — a
    // pre-existing gap, and 10 categories across every locale file is its own
    // piece of work. This tab is new chrome, so it gets a real key.
    const tabs = [
      ...EMOJI_CATEGORIES.map(c => [ c.key, c.label ]),
      [ this.constructor.ALL_KEY, t("editor.emoji_all") ]
    ]
    this.tabsTarget.innerHTML = tabs.map(([ key, label ]) => `
      <button type="button" class="emoji-picker-tab${key === this._category ? " is-active" : ""}"
              data-category="${key}" data-action="click->emoji-picker#pickCategory">${label}</button>
    `).join("")
  }

  // The glyphs this view is showing, before paging.
  _list() {
    const query = this.searchTarget.value.trim()
    if (query) return searchEmoji(query)
    if (this._category === this.constructor.ALL_KEY) return ALL_EMOJI.map(([ e ]) => e)
    return (EMOJI_CATEGORIES.find(c => c.key === this._category)?.emoji || []).map(([ e ]) => e)
  }

  // A single emoji typed or pasted into the search box — a flag, a unicorn,
  // something copied off Emojipedia — is itself the answer, whether or not the
  // library has a row for it. The search can only match the library's words,
  // so without this a creator who pasted 🇪🇺 was told "No emoji match that"
  // and had nowhere to put it.
  _pastedEmoji() {
    const query = this.searchTarget.value.trim()
    if (!query || !/\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(query)) return null
    const clusters = typeof Intl?.Segmenter === "function"
      ? [ ...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(query) ].length
      : [ ...query ].length
    return clusters === 1 ? query : null
  }

  _renderGrid() {
    let list = this._list()
    const pasted = this._pastedEmoji()
    if (pasted && !list.includes(pasted)) list = [ pasted, ...list ]

    if (!list.length) {
      this._allShown = 0
      this.gridTarget.innerHTML =
        `<div class="emoji-picker-empty">${t("editor.emoji_none", { default: "No emoji match that." })}</div>`
      return
    }
    // Only the All tab pages; a curated category and a capped search result are
    // both short enough to paint in one go.
    const paged = !this.searchTarget.value.trim() && this._category === this.constructor.ALL_KEY
    this._allShown = paged ? Math.min(this.constructor.PAGE, list.length) : list.length
    this.gridTarget.innerHTML = this._buttons(list.slice(0, this._allShown))
  }

  _maybeExtend() {
    if (this._category !== this.constructor.ALL_KEY) return
    if (this.searchTarget.value.trim()) return

    const grid = this.gridTarget
    if (grid.scrollHeight - grid.scrollTop - grid.clientHeight > this.constructor.NEAR_END) return

    const list = this._list()
    if (this._allShown >= list.length) return

    const next = list.slice(this._allShown, this._allShown + this.constructor.PAGE)
    this._allShown += next.length
    grid.insertAdjacentHTML("beforeend", this._buttons(next))
  }

  _buttons(list) {
    return list.map(e => `
      <button type="button" class="emoji-picker-item" data-emoji="${e}"
              data-action="click->emoji-picker#pick" aria-label="${e}">${e}</button>
    `).join("")
  }

  // Anchored to the trigger, flipped up or left when it would otherwise run
  // off-screen — the token-type rows sit low in a right-hand panel.
  _position(trigger) {
    const r = trigger.getBoundingClientRect()
    const pop = this.popoverTarget
    const w = pop.offsetWidth || 300
    const h = pop.offsetHeight || 340
    let top = r.bottom + 6
    let left = r.left
    if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 6)
    if (left + w > window.innerWidth - 8) left = Math.max(8, window.innerWidth - w - 8)
    pop.style.top = `${top}px`
    pop.style.left = `${left}px`
  }
}
