import { Controller } from "@hotwired/stimulus"

// Fills in the "what the answers tell us" box beside each question.
//
// ONE request for the whole feed, not one per card. The endpoint reads every
// question in a single model call (QuestionInsights) — partly because twenty
// calls is twenty throttle slots and twenty chances to half-fail, and partly
// because the readings worth having are the ones that see the other questions,
// which a per-card call cannot make.
//
// Cached server-side against the segment AND the response count, so the second
// visit is a database read. The shimmer is therefore the cold-cache case only;
// it is not what this normally looks like.
export default class extends Controller {
  static targets = [ "slot", "wait" ]
  static values  = { url: String }

  connect() {
    // A feed with no question cards (a deck of welcome and consent screens) has
    // nothing to read and should not spend a call finding that out.
    if (this.slotTargets.length === 0) return this._clearWaits()

    // The shimmer is rendered hidden and revealed here, rather than rendered
    // visible: a page whose JavaScript never arrives would otherwise sit
    // under "Reading the answers…" forever, waiting on a fetch that nothing
    // is going to make. Revealed only once there is a request to wait for.
    this.waitTargets.forEach(el => { el.hidden = false })

    this._aborter = new AbortController()
    this._load()
  }

  disconnect() {
    this._aborter?.abort()
  }

  async _load() {
    try {
      const res = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        signal:  this._aborter.signal
      })
      if (!res.ok) return this._clearWaits()

      const body = await res.json()
      if (!body?.ok) return this._clearWaits()

      this._fill(body.insights || {})
    } catch (e) {
      // An abort is the ordinary case — a filter click replaces the frame
      // mid-request — and is not a failure worth reporting anywhere.
      if (e?.name !== "AbortError") this._clearWaits()
    }
  }

  _fill(insights) {
    this.slotTargets.forEach(slot => {
      const text = insights[slot.dataset.index]
      if (!text) return

      // textContent, not innerHTML: this is model output rendered inside the
      // creator's own page, and the one thing it must never be able to do is
      // bring markup with it.
      slot.querySelector(".rc-tell-body").textContent = text
      slot.hidden = false
    })
    this._clearWaits()
  }

  // The shimmer goes whatever happened. A question the model declined to read
  // — too few answers, nothing honest to say — is a question with no box, not
  // a question that waits forever.
  _clearWaits() {
    this.waitTargets.forEach(el => el.remove())
  }
}
