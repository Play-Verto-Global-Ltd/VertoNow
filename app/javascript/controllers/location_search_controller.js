import { Controller } from "@hotwired/stimulus"

// Satnav-style location search: debounced type-ahead against the server-side
// Nominatim proxy (PlayerController#location_search / NominatimClient), used
// by the "Where do you live?" demographic card in place of free text. A pick
// is packed into the hidden value target as "CC|Label" — a plain string, read
// generically like any other open_ended answer (see player_controller.js's
// _read/_applyValue) — never raw search text, never coordinates (the
// server-side client never returns lat/lon).
//
// There used to be a third segment, "CC|Label|POSTCODE", written when a
// creator turned on an optional postcode field. Postcodes are no longer
// collected anywhere on the platform, so nothing packs a third segment —
// but the server's parse still tolerates one, because a respondent can have
// a published deck open from before the field was removed.
export default class extends Controller {
  static targets = ["input", "results", "selected", "selectedText", "value"]
  static values  = { url: String }

  connect() {
    this._results = []
    this._active = -1
  }

  disconnect() {
    clearTimeout(this._searchTimer)
  }

  search() {
    clearTimeout(this._searchTimer)
    this._searchTimer = setTimeout(() => this._runSearch(), 350)
  }

  keydown(event) {
    if (!this._results.length) return
    if (event.key === "ArrowDown") { event.preventDefault(); this._move(1) }
    else if (event.key === "ArrowUp") { event.preventDefault(); this._move(-1) }
    else if (event.key === "Enter") { event.preventDefault(); this._pick(this._active >= 0 ? this._active : 0) }
    else if (event.key === "Escape") { this._clearResults() }
  }

  pick(event) {
    this._pick(Number(event.currentTarget.dataset.index))
  }

  // Let the respondent search again after confirming a pick.
  change() {
    if (this.hasSelectedTarget) this.selectedTarget.hidden = true
    this.inputTarget.hidden = false
    this.inputTarget.value = ""
    this.inputTarget.focus()
  }

  async _runSearch() {
    if (!this.hasUrlValue) return
    const q = this.inputTarget.value.trim()
    if (q.length < 3) { this._clearResults(); return }

    const token = (this._searchToken = (this._searchToken || 0) + 1)
    try {
      const resp = await fetch(`${this.urlValue}?q=${encodeURIComponent(q)}`, { headers: { "Accept": "application/json" } })
      const data = await resp.json()
      if (token !== this._searchToken) return // a newer search superseded this one

      this._results = Array.isArray(data.results) ? data.results : []
      this._active = -1
      this._render()
    } catch (_) {
      this._clearResults()
    }
  }

  _render() {
    if (!this.hasResultsTarget) return
    if (!this._results.length) { this._clearResults(); return }
    this.resultsTarget.innerHTML = this._results.map((r, i) => `
      <li><button type="button" class="location-search-result" data-index="${i}"
                   data-action="click->location-search#pick">${this._esc(r.display_name)}</button></li>
    `).join("")
    this.resultsTarget.hidden = false
  }

  _move(dir) {
    this._active = (this._active + dir + this._results.length) % this._results.length
    Array.from(this.resultsTarget.children).forEach((li, i) => {
      li.querySelector("button")?.classList.toggle("is-active", i === this._active)
    })
  }

  _pick(idx) {
    const result = this._results[idx]
    if (!result) return
    this._clearResults()
    this.inputTarget.hidden = true
    if (this.hasSelectedTarget) this.selectedTarget.hidden = false
    if (this.hasSelectedTextTarget) this.selectedTextTarget.textContent = result.display_name
    if (this.hasValueTarget) this.valueTarget.value = this._pack(result.country_code, result.label || "")
  }

  _pack(country, label) {
    return `${country}|${label}`
  }

  _clearResults() {
    this._results = []
    this._active = -1
    if (this.hasResultsTarget) { this.resultsTarget.hidden = true; this.resultsTarget.innerHTML = "" }
  }

  _esc(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
  }
}
