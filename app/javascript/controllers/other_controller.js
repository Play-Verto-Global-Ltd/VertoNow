import { Controller } from "@hotwired/stimulus"
import { haptic } from "lib/haptics"

// The "Other" write-in on a question card: a floating "＋ Other" CTA, a panel
// with the textarea, and — once the respondent has committed what they typed —
// a selected-looking row under the options showing it.
//
// Three states, read off the DOM rather than kept in a field so a clone (the
// editor's Preview) or a restore paints itself right on connect:
//   idle       panel hidden, chip hidden, CTA shown, textarea blank
//   editing    panel open, CTA lit, card carries .other-active (the overlay's
//              layout gives the block the scroll while it is open)
//   committed  panel hidden, chip shown with the text, CTA hidden
//
// The textarea is the single source of truth in every state. player#_answerOf
// reads [data-other-input] whether the panel is open or folded into the chip,
// so a draft the respondent never committed still travels with the answer, and
// the chip is only ever a display of the value, never a second copy.
//
// Other COMBINES with the picks — on every type. It used to replace them (the
// list dimmed and the submitted value was nulled), which is how a respondent
// who ticked two and wrote a third lost the two. The chip is deliberately not a
// picker item: no data-picker-target, so it never counts toward max_choices and
// never leaks into the picked value.
export default class extends Controller {
  static targets = [ "wrap", "btn", "panel", "input", "chip", "chipMain", "chipText", "clear", "add" ]

  // How long a blur waits before committing. Folding the panel re-centres the
  // option list, so a mousedown on a row that blurred the textarea must land
  // on the row it was aimed at before the panel goes; the document click
  // listener commits sooner when a click does arrive, and this covers the
  // cases where none does — Tab away, or the iOS keyboard's Done.
  static BLUR_COMMIT_MS = 200

  connect() {
    this._onDocClick = (e) => this._clickedOutside(e)
    this._render()
  }

  disconnect() {
    this._unwatch()
    clearTimeout(this._blurTimer)
  }

  // The CTA: opens the panel, or commits what is in it.
  toggle() {
    if (this._state() === "editing") this.commit({ explicit: true })
    else this.open()
  }

  // The chip: back into the panel with the text intact, caret at the end.
  edit() { this.open() }

  // Opening changes nothing about the answer, so it tells the deck nothing:
  // the focus the box takes runs the player's own reveal, and the layout
  // follows .other-active.
  open() {
    this.panelTarget.hidden = false
    this.chipTarget.hidden = true
    this.btnTarget.hidden = false
    this.btnTarget.classList.add("is-active")
    this._card()?.classList.add("other-active")
    this._watch()
    const ta = this.inputTarget
    ta.focus()
    const end = ta.value.length
    try { ta.setSelectionRange(end, end) } catch (_) { /* a locked deck's disabled box */ }
  }

  // Idempotent: every path that can fire after the fold (the blur the fold
  // itself causes, the deferred timer, a second Enter) finds the state already
  // moved on and does nothing. `explicit` is Enter, Add or the CTA — the
  // respondent asked for the commit, and one buzz answers them. A tap on an
  // option row commits too, but that row buzzes for itself; a blur commits in
  // silence.
  commit({ explicit = false } = {}) {
    if (this._state() !== "editing") return
    clearTimeout(this._blurTimer)
    this._unwatch()
    const text = this.inputTarget.value.trim()
    if (!text) { this.clear(); return }
    this.chipTextTarget.textContent = text
    this.panelTarget.hidden = true
    this.chipTarget.hidden = false
    this.btnTarget.hidden = true
    this.btnTarget.classList.remove("is-active")
    this._card()?.classList.remove("other-active")
    // Drops the keyboard on a phone. The focusout this causes sees the state
    // is no longer "editing" and does nothing.
    if (document.activeElement === this.inputTarget) this.inputTarget.blur()
    if (explicit) haptic()
    this._poke()
  }

  // Enter, Add: the respondent's own commit.
  commitExplicit() { this.commit({ explicit: true }) }

  // The chip's ×, and an empty commit: back to idle with nothing recorded.
  clear() {
    clearTimeout(this._blurTimer)
    this._unwatch()
    this.inputTarget.value = ""
    this.panelTarget.hidden = true
    this.chipTarget.hidden = true
    this.btnTarget.hidden = false
    this.btnTarget.classList.remove("is-active")
    this._card()?.classList.remove("other-active")
    // A keyboard user is not left on a node that just vanished — but focus
    // that has already gone somewhere else (the field they tapped instead,
    // Next, the card after this one) stays there; pulling it back would drop
    // the keyboard they just raised.
    const active = document.activeElement
    const stranded = !active || active === document.body || this.element.contains(active)
    if (stranded && !this.btnTarget.disabled) this.btnTarget.focus({ preventScroll: true })
    // One bubbling `input` refreshes the counter (freeform#update) and tells
    // the deck the answer changed.
    this._poke()
  }

  // Enter commits — never a new line. The box is one answer, not a paragraph;
  // the limit and the wrapping are what give it room. Shift+Enter included:
  // "pressing enter should not take you to a new line" was the whole report.
  // An IME composition's Enter is the IME's, not ours.
  keydown(event) {
    if (event.key !== "Enter" || event.isComposing || event.keyCode === 229) return
    event.preventDefault()
    this.commit({ explicit: true })
  }

  // Tapping or tabbing away commits. Not immediately — see BLUR_COMMIT_MS.
  focusout(event) {
    if (this._state() !== "editing") return
    if (event.relatedTarget && this.element.contains(event.relatedTarget)) return
    clearTimeout(this._blurTimer)
    this._blurTimer = setTimeout(() => this.commit(), this.constructor.BLUR_COMMIT_MS)
  }

  // The Add button: keep the textarea focused through the press so its blur
  // can never race the click. pointerdown's preventDefault stops the focus
  // change in Chrome and Safari; mousedown is the belt for anything older.
  holdFocus(event) { event.preventDefault() }

  _state() {
    if (!this.panelTarget.hidden) return "editing"
    return this.chipTarget.hidden ? "idle" : "committed"
  }

  // Paint from what the DOM holds. A hidden panel with text in it (a Turbo
  // restore, a clone) is a committed answer and shows as one.
  _render() {
    const text = this.inputTarget.value.trim()
    if (this.panelTarget.hidden && text) {
      this.chipTextTarget.textContent = text
      this.chipTarget.hidden = false
      this.btnTarget.hidden = true
    }
  }

  // Capture phase, so the commit lands before the clicked row's own handler
  // runs — the fold moves the list, and the pick must not be lost to that. On
  // iOS a tap on a row does not blur a textarea at all, so this is the only
  // thing that commits there.
  _watch()   { document.addEventListener("click", this._onDocClick, true) }
  _unwatch() { document.removeEventListener("click", this._onDocClick, true) }

  _clickedOutside(event) {
    if (!this.element.contains(event.target)) this.commit()
  }

  // One bubbling `input` from the textarea is the deck's existing hook: the
  // player's capture listener marks the card touched, re-syncs the Next glow
  // and re-fits the card — everything a fold or unfold needs, none of which
  // would otherwise hear about it.
  _poke() {
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  _card() {
    return this.element.closest(".split-card") || this.element.closest(".preview-card")
  }
}
