import { Controller } from "@hotwired/stimulus"
import lottie from "lottie-web"

// Mounts a lottie-web instance and swaps the animation in response to
// `verto:scaleValue` events from the slider. Each value-swap destroys the
// previous animation and plays the next one from frame 0 (no loop).
// Animation URLs (one per frame 1..N) are supplied as a JSON array in the
// `urls` value, so Rails can pass digested asset paths. N is this set's to
// know: five for every pickable set, one per age band for the age card's
// (NpsHelper::AGE_BAND_THEME) — the slider sends its position and `react`
// maps it onto whatever is mounted.
//
// The default `current` is the NEUTRAL middle frame (3 of 5), matching
// NpsHelper::NPS_NEUTRAL_FRAME and where slider_controller parks its thumb —
// a character resting on frame 1 reads as "strongly disagree" and biases the
// answer before the respondent has touched anything.
const NEUTRAL_FRAME = 3

export default class extends Controller {
  // `loop` is for decorative card media (a pasted LottieFiles animation on the
  // card's left panel): one URL, playing continuously. The slider reaction
  // sets keep the default one-shot behaviour.
  static values  = { urls: Array, current: { type: Number, default: NEUTRAL_FRAME }, loop: { type: Boolean, default: false } }
  static targets = ["mount"]

  connect() {
    this._onChange = (e) => this.react(e.detail || {})
    // Listen on THIS card, not the document: the player and the editor both
    // hold every card in the DOM at once, so a document-level listener let one
    // card's drag move every other card's character off its neutral resting
    // pose. The slider dispatches a bubbling event from inside the same
    // .split-card, so scoping here keeps each card's animation its own.
    this._scope = this.element.closest(".split-card") || document
    this._scope.addEventListener("verto:scaleValue", this._onChange)
    // Derive the resting frame from the set actually mounted when the server
    // didn't name one, so a theme shipping a different frame count still opens
    // centred rather than on whatever NEUTRAL_FRAME happens to say.
    this.show(this.hasCurrentValue ? this.currentValue : this._neutralFrame)
  }

  get _neutralFrame() {
    return Math.ceil(this.urlsValue.length / 2) || NEUTRAL_FRAME
  }

  disconnect() {
    this._scope?.removeEventListener("verto:scaleValue", this._onChange)
    this._scope = null
    this.instance?.destroy()
    this.instance = null
    // Forget which frame was on screen. show() early-returns when the requested
    // value equals `shown`, so a controller that reconnects (Turbo restore, or
    // the element being moved in the DOM) would take that early return and
    // never re-mount — leaving an empty panel where destroy() cleared the SVG.
    this.shown = null
  }

  // A slider position → the frame of THIS set that stands for it. Five frames
  // under a five-stop slider, or seven under the age card's seven, is the
  // identity: every stop plays its own file. Five frames under a three-stop
  // scale spreads the stops across the set, exactly the 1–5 value the slider
  // used to compute for itself, so every existing set reacts as it always did.
  // `neutral` is the resting pose (connect, and the slider's own connect),
  // derived from the mounted set rather than assumed to be 3.
  react({ neutral, index, steps }) {
    if (neutral) return this.show(this._neutralFrame)
    const frames = this.urlsValue.length
    if (!Number.isFinite(index) || !(steps > 1) || !frames) return
    this.show(Math.round(index / (steps - 1) * (frames - 1)) + 1)
  }

  // The editor's theme picker swaps the `urls` value to a different animation
  // set; re-render the current frame so the change shows at once. Guarded on the
  // mount target since Stimulus fires this before connect() on first render
  // (where connect() already does the initial show). Clamped to the new set's
  // length: a frame the old set had and the new one lacks would leave the
  // mount empty, since show() has nothing to load for it.
  urlsValueChanged() {
    if (!this.hasMountTarget) return
    this.shown = null
    this.show(Math.min(this.currentValue, this.urlsValue.length))
  }

  show(value) {
    const v = Number(value)
    if (!Number.isFinite(v) || v === this.shown) return
    const url = this.urlsValue[v - 1] // 1-indexed value
    if (!url) return
    this.shown = v
    // Remember where we are, so urlsValueChanged() (the editor's animation
    // picker swapping the set) re-renders the frame actually on screen instead
    // of snapping back to the mount default.
    this.currentValue = v
    this.instance?.destroy()
    // Empty the mount before loading. loadAnimation APPENDS an <svg>, and
    // destroy() only clears the SVG this controller instance made — so any
    // <svg> that arrived already rendered inside the mount survives and the new
    // one stacks under it. Two SVGs, each forced to height:100% by
    // .card-lottie-mount svg, is the "animation drawn twice, second copy cut
    // off by the card edge" glitch. It reaches the mount two ways: a Turbo Drive
    // cache restore (the snapshot holds the rendered SVG, while a fresh
    // controller has no `instance` to destroy), and preview_verto_controller's
    // deep clone of an already-rendered card.
    this.mountTarget.replaceChildren()
    this.instance = lottie.loadAnimation({
      container: this.mountTarget,
      renderer: "svg",
      loop: this.loopValue,
      autoplay: true,
      path: url,
    })
    // A failed fetch left an EMPTY mount inside an invisible inset:0 box, so
    // the card showed a bare brand panel with its "Change media" button still
    // there and nothing to say why — reported as "the lottie links disappear
    // randomly after added and platform saved" when the link had not gone
    // anywhere. Mark the wrapper so the panel can show its empty state, and say
    // so once in the console for anyone looking.
    this.element.classList.remove("is-broken")
    this.instance.addEventListener("data_failed", () => {
      this.element.classList.add("is-broken")
      console.warn(`[lottie-player] could not load ${url}`)
    })
  }
}
