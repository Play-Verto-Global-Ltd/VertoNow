import { Controller } from "@hotwired/stimulus"

// Verto slider: track with N dots, draggable thumb. Snaps to the nearest
// step on release. Horizontal by default; axisValue "vertical" flips the
// drag math and positions the thumb via `bottom` instead of `left` — dots
// are positioned once at render time by the server/JS builder (see
// _card_component.html.erb / sliderHtml in type_panel_controller.js), so
// only the thumb needs runtime axis awareness.
//
// It also drives the left-panel reaction animation on Range cards: each step
// change dispatches `verto:scaleValue` with the step index and the step count,
// and the lottie-player controller maps that position onto however many
// frames ITS set holds — five for every pickable set, one per band for the
// age card's seven-stop slider (NpsHelper::AGE_BAND_THEME), where the mapping
// is the identity and every answer plays its own file. The frame count is the
// player's to know, not this slider's, which is why nothing here says "5".
//
// On connect it dispatches `neutral` instead of a position, so the character
// opens on its set's resting frame whatever the step count.

// ── Scale words are never broken mid-word ─────────────────────────────────
// Five stops divide the panel into five equal columns, and a flex column
// cannot shrink below its longest WORD. At the player's 16px "Definitely"
// outgrows the ~69px a 390px phone has to give it, and the fallback that
// stops a label spilling over its neighbour — `overflow-wrap: break-word` —
// printed it as "Definitel / y". A word sheared in half is worse than every
// lever that avoids it, so two are pulled here, in this order:
//
//   1. Shrink the type to fit the widest word, but only as far as
//      --play-scale-floor. Read from the stylesheet, never stated here: the
//      answer is the last thing on a card that may get smaller, and
//      player_type_floor_test holds this to the token rather than to
//      "whatever happened to fit".
//   2. If the widest word still won't fit at the floor, and the creator left
//      the layout on `auto`, turn the scale vertical — a full-width row per
//      stop, which is exactly what that layout exists for.
//
// Words are measured on a canvas rather than by writing a size and reading
// the wrapped height back: this runs on every resize, and each read-back is a
// forced synchronous layout.
const WORDS = /\s+/

// Air kept between one stop's widest word and the next column. The columns
// are flush (flex: 1 1 0 under space-between, so no gap to inherit), and a
// word sized to the last pixel of its own column ends up touching its
// neighbour — "Probably Definitely" read as one phrase. Charged to the fit
// only: a card whose words already fit keeps every pixel of its type.
const LABEL_GUTTER = 5

export default class extends Controller {
  static targets = ["track", "thumb", "dot", "label"]
  static values  = {
    steps: Number,
    index: { type: Number, default: 0 },
    axis:  { type: String, default: "horizontal" },
    // Whether the card's stored slider_axis is "auto" — i.e. whether this
    // controller is allowed to turn the scale vertical on its own. A creator
    // who picked horizontal from the toggle keeps horizontal.
    auto:  { type: Boolean, default: false },
    // A vertical scale that lists its first option at the TOP (the age card —
    // NpsHelper#slider_top_down?). Only the drawing flips: index 0 is still
    // the first option, so what gets stored is unchanged.
    topDown: { type: Boolean, default: false }
  }

  connect() {
    this._onMove = this.onMove.bind(this)
    this._onUp   = this.onUp.bind(this)
    this.indexValue = Math.floor((this.stepsValue - 1) / 2)
    // The axis the server resolved, kept so a flip to vertical can be undone.
    // A fit that only ever goes one way leaves a phone that has been turned
    // sideways — or an editor panel that closed — reading the layout its
    // narrowest moment needed.
    this._serverAxis = this.axisValue
    this.render()
    this._watchWidth()
    // Open on the NEUTRAL frame explicitly rather than deriving it from the
    // step count: a legacy even-count scale (a published 4-point Verto, which
    // Survey#enforce_range_scale deliberately leaves alone) maps its centre
    // index to an off-centre frame, so the character would greet the
    // respondent already leaning one way.
    this._dispatchScaleValue(true)
  }

  disconnect() {
    this._widthObserver?.disconnect()
    this._widthObserver = null
  }

  // Arrow keys step the slider, mirroring nps_slider_controller#key (P2-4).
  // Without this the range card is drag-only — pointerdown is the sole way to
  // answer it, which locks out anyone not using a pointer.
  key(event) {
    let up   = [ "ArrowUp", "ArrowRight" ].includes(event.key)
    let down = [ "ArrowDown", "ArrowLeft" ].includes(event.key)
    if (!up && !down) return
    // On a top-down scale the next option is BELOW, so the vertical arrows
    // follow the thumb rather than the index.
    if (this._topDown && [ "ArrowUp", "ArrowDown" ].includes(event.key)) {
      [ up, down ] = [ down, up ]
    }
    if (event.target.isContentEditable) return
    event.preventDefault()

    const n    = Math.max(2, this.stepsValue)
    const next = Math.max(0, Math.min(n - 1, this.indexValue + (up ? 1 : -1)))
    if (next === this.indexValue) return

    this.indexValue = next
    this.render()
    // No argument: _dispatchScaleValue derives the reaction frame from
    // indexValue, exactly as the drag path does.
    this._dispatchScaleValue()
  }

  // Tapping a label jumps straight to that step — with five 16px labels the
  // words are a far larger target than the dots they sit under. Player only:
  // the editor's labels are contenteditable and never carry this action.
  jump(event) {
    if (event.target.isContentEditable) return
    const idx = this.labelTargets.indexOf(event.currentTarget)
    if (idx < 0 || idx === this.indexValue) return
    this.indexValue = idx
    this.render()
    this._dispatchScaleValue()
    this.dispatch("settle", { detail: { index: this.indexValue } })
  }

  start(event) {
    if (event.target.isContentEditable) return
    event.preventDefault()
    event.stopPropagation() // don't also select/apply the type underneath
    this.dragging = true
    this.updateFromEvent(event)
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup",   this._onUp, { once: true })
  }

  onMove(event) { if (this.dragging) this.updateFromEvent(event) }
  onUp() {
    this.dragging = false
    window.removeEventListener("pointermove", this._onMove)
    this.dispatch("settle", { detail: { index: this.indexValue } })
  }

  updateFromEvent(event) {
    const rect = this.trackTarget.getBoundingClientRect()
    const raw  = this.axisValue === "vertical"
      ? (this._topDown ? event.clientY - rect.top : rect.bottom - event.clientY) / rect.height
      : (event.clientX - rect.left) / rect.width
    const ratio = Math.max(0, Math.min(1, raw))
    const n     = Math.max(2, this.stepsValue)
    const idx   = Math.round(ratio * (n - 1))
    if (idx !== this.indexValue) {
      this.indexValue = idx
      this.render()
      this._dispatchScaleValue()
    }
  }

  // Broadcast the current step (0…n-1, of n) for the reaction animation, or
  // `neutral` for the resting pose. Dispatched from this slider's own element
  // and left to BUBBLE, so the lottie-player in the same .split-card picks it
  // up and no other card's does — the player and editor both hold every card
  // in the DOM, so a document-level event used to drag every character off
  // neutral at once.
  _dispatchScaleValue(neutral = false) {
    const n      = Math.max(2, this.stepsValue)
    const detail = neutral ? { neutral: true } : { index: this.indexValue, steps: n }
    this.element.dispatchEvent(
      new CustomEvent("verto:scaleValue", { detail, bubbles: true })
    )
  }

  render() {
    const n     = Math.max(2, this.stepsValue)
    const ratio = this.indexValue / (n - 1)
    const pct   = `${(ratio * 100).toFixed(2)}%`

    if (this.hasThumbTarget) {
      this._place(this.thumbTarget, pct)
    }

    // The dots are positioned inline by whoever built the markup (the ERB
    // partial and sliderHtml both do it), so a runtime axis flip has to move
    // them: an inline `left:75%` left behind would beat the stylesheet's
    // `left:50%` centring and strand the dot off the vertical track.
    this.dotTargets.forEach((dot, i) => {
      this._place(dot, `${(i / (n - 1) * 100).toFixed(2)}%`)
      dot.classList.toggle("active", i === this.indexValue)
    })

    // Same convention as the NPS labels: the chosen step's label lights up, so
    // the value reads without hunting for the active dot.
    this.labelTargets.forEach((label, i) =>
      label.classList.toggle("is-active", i === this.indexValue)
    )

    // Keep the announced value in step with the visible thumb. Only where the
    // role was applied — the editor renders the same markup without it.
    if (this.element.hasAttribute("role")) {
      this.element.setAttribute("aria-valuenow", String(this.indexValue))
      const label = this.labelTargets[this.indexValue]
      if (label) this.element.setAttribute("aria-valuetext", label.textContent.trim())
    }
  }

  // Top-down only means anything on a vertical scale; a horizontal one reads
  // left to right whatever the card is.
  get _topDown() { return this.topDownValue && this.axisValue === "vertical" }

  // Put a dot or the thumb `at` along the scale, clearing the offsets the
  // other layouts use so an inline one left behind can't win.
  _place(el, at) {
    const edge = this.axisValue !== "vertical" ? "left" : (this._topDown ? "top" : "bottom")
    for (const side of [ "left", "top", "bottom" ]) el.style[side] = side === edge ? at : ""
  }

  // ── Fitting the scale words ─────────────────────────────────────────────

  // The editor's stops are contenteditable: a creator typing a longer word is
  // the same event as the panel getting narrower.
  refit() { this.fitLabels() }

  // Re-fit when the slider's WIDTH changes, and only then. Observing height
  // too would loop: a smaller label wraps to fewer lines, the row shortens,
  // the observer fires, and the fit runs against its own result.
  _watchWidth() {
    if (typeof ResizeObserver === "undefined") { this.fitLabels(); return }
    this._widthObserver = new ResizeObserver(() => {
      const w = Math.round(this.element.getBoundingClientRect().width)
      if (w === this._fittedAt) return
      this._fittedAt = w
      this.fitLabels()
    })
    this._widthObserver.observe(this.element)
    // The first fit measures text, so it has to wait for the webfont: ABeeZee
    // is wider than the fallback the first paint uses, and a fit computed
    // against the fallback comes out too generous by exactly the difference.
    document.fonts?.ready?.then(() => this.fitLabels()).catch(() => {})
  }

  fitLabels() {
    if (!this.hasLabelTarget) return
    const row = this.labelTargets[0].parentElement
    if (!row) return

    // Always start from where the server left things — the stylesheet's own
    // size, and the axis it resolved — never on top of a previous fit.
    // Otherwise a panel that grows back stays shrunk, and sideways.
    if (this.autoValue) this._setAxis(this._serverAxis)

    if (this._sizeToFit(row) && this.autoValue && this.axisValue === "horizontal") {
      // Out of type before the words fit: spend the layout instead.
      this._setAxis("vertical")
      // And fit again. A vertical row is much wider than a fifth of the panel
      // but not unconditionally wide enough — "Uncomfortable" is 113px and a
      // 320px phone's label column is 112.6 — so the flip buys the room, it
      // doesn't excuse the measurement.
      this._sizeToFit(row)
    }
  }

  // Size the scale so its widest word fits the column it has, never below
  // --play-scale-floor. Returns true if the floor was reached before the word
  // fit — i.e. type alone could not solve it.
  _sizeToFit(row) {
    row.style.removeProperty("--slider-label-fit")

    const style   = getComputedStyle(this.labelTargets[0])
    const natural = parseFloat(style.fontSize)
    const column  = Math.min(...this.labelTargets.map(l => l.getBoundingClientRect().width))
    if (!(natural > 0) || !(column > 0)) return false

    // A vertical stop has the whole row and its neighbours are above and
    // below it, so there is nothing for the gutter to keep it off.
    const gutter = this.axisValue === "vertical" ? 0 : LABEL_GUTTER
    const widest = this._widestWordPx(style)
    if (!(widest > column - gutter)) return false

    const floor  = this._scaleFloorPx(row, natural)
    // The gutter is the first thing given up, before the type reaches its
    // floor and well before the layout turns: on a small phone it is the
    // difference between a scale that still fits and a vertical one, and
    // touching words read better than a rotated card.
    let wanted = natural * ((column - gutter) / widest)
    if (wanted < floor) wanted = natural * (column / widest)
    // Floored to a tenth of a pixel: rounding UP can land a hair over the
    // column and put the break straight back.
    row.style.setProperty("--slider-label-fit", `${Math.max(floor, Math.floor(wanted * 10) / 10)}px`)
    return wanted < floor
  }

  // The widest single word across every stop, at the size they render now.
  // Measured at weight 700, not the resting 600: the chosen stop bolds, and a
  // label that fits until it is picked is the same bug arriving one tap late.
  _widestWordPx(style) {
    const ctx = (this.constructor._measure ||=
      document.createElement("canvas").getContext("2d"))
    if (!ctx) return 0
    ctx.font = `700 ${style.fontSize} ${style.fontFamily}`
    let widest = 0
    for (const label of this.labelTargets) {
      for (const word of label.textContent.trim().split(WORDS)) {
        if (word) widest = Math.max(widest, ctx.measureText(word).width)
      }
    }
    return widest
  }

  // --play-scale-floor in resolved pixels. Read off a probe rather than
  // parsed from the custom property, which hands back the token as authored
  // ("0.875rem") and would compare as 0.875 against real pixel sizes.
  _scaleFloorPx(row, natural) {
    const probe = document.createElement("span")
    probe.style.cssText = "position:absolute;visibility:hidden;font-size:var(--play-scale-floor)"
    row.appendChild(probe)
    const px = parseFloat(getComputedStyle(probe).fontSize)
    probe.remove()
    return px > 0 ? Math.min(px, natural) : natural
  }

  // Runtime-only: the card's stored slider_axis is untouched, so this is the
  // same kind of decision resolved_slider_axis makes on the server, made
  // again once the real column width is known.
  _setAxis(axis) {
    if (this.axisValue === axis) return
    this.axisValue = axis
    if (this.element.hasAttribute("aria-orientation")) {
      this.element.setAttribute("aria-orientation", axis)
    }
    this.render()
  }
}
