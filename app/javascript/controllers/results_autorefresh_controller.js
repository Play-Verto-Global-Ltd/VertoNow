import { Controller } from "@hotwired/stimulus"

// Opt-in auto-refresh for the results page's per-question breakdown.
//
// The live tally already updates over Action Cable (ResultsActivity /
// results_live) — deliberately just two counts, never a re-aggregation, so a
// Verto being actively answered doesn't re-run the full breakdown for every
// viewer on every submission (see _results_live.html.erb). This controller
// turns that same broadcast into a "the numbers moved" signal and, at most
// once per interval, does programmatically what the existing "↻ Refresh
// breakdown" link already does: reload the results-feed frame. Aggregates
// still only ever recompute on an actual reload, never per response.
//
// Off by default, honouring the reasoning above — this is opt-in, not a
// reversal of it.
export default class extends Controller {
  static targets = ["toggle"]
  static values  = { url: String, interval: { type: Number, default: 45000 } }

  connect() {
    this._dirty = false
    this._on    = localStorage.getItem("resultsAutorefresh") === "1"
    this._timer = setInterval(() => this._tick(), this.intervalValue)
    this._onVisible = () => this._tick()
    document.addEventListener("visibilitychange", this._onVisible)
    this._renderToggle()
  }

  disconnect() {
    clearInterval(this._timer)
    document.removeEventListener("visibilitychange", this._onVisible)
  }

  // Bound in the view to turbo:before-stream-render, which fires for every
  // stream on the page — filter to the one replace this cares about.
  markDirty(event) {
    if (event.target?.getAttribute?.("target") !== "results-live") return
    this._dirty = true
  }

  toggle() {
    this._on = !this._on
    localStorage.setItem("resultsAutorefresh", this._on ? "1" : "0")
    this._renderToggle()
    if (this._on) this._tick()
  }

  _tick() {
    if (!this._on || !this._dirty) return
    if (document.hidden) return
    if (this._blocked()) return // try again next tick rather than interrupting
    this._dirty = false
    const frame = document.getElementById("results-feed")
    if (frame) frame.src = this.urlValue
  }

  // Never interrupt the AI-report modal, an open export/share/segments menu, or
  // a focused field — a mid-edit reload would either discard unsaved state (the
  // report brief, an in-place markdown edit) or just close whatever the creator
  // has open.
  //
  // Scoped to the DOCUMENT, not the frame. These used to live inside
  // #results-feed and the guard looked there; the header moved them out, which
  // would have left every one of them unguarded — a tick mid-typing in the
  // share panel, or with the report modal open, is exactly what this exists to
  // prevent, and where the node sits in the tree has nothing to do with it.
  _blocked() {
    const frame = document.getElementById("results-feed")
    if (!frame) return true
    if (document.querySelector(".report-modal:not(.hidden)")) return true
    if (document.querySelector("details[open]")) return true
    const active = document.activeElement
    if (active && [ "INPUT", "TEXTAREA", "SELECT" ].includes(active.tagName)) return true
    return false
  }

  _renderToggle() {
    if (!this.hasToggleTarget) return
    this.toggleTarget.setAttribute("aria-pressed", String(this._on))
    this.toggleTarget.classList.toggle("is-on", this._on)
    this.toggleTarget.textContent = this._on ? "Auto ↻ on" : "Auto ↻ off"
  }
}
