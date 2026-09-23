import { Controller } from "@hotwired/stimulus"

// The editor's "Search for" block for a location card (LocationScope): which
// kinds of place the respondent's search offers, and which countries and
// cities it stays inside. survey-editor hands it the selected card through
// load(card); everything it changes is written to that card's data attributes
// — data-card-location-places / -countries / -cities, JSON arrays — where
// survey-editor#serialize reads them back, and a `location-scope:changed`
// event marks the deck dirty.
//
// The server is the authority on what is kept (Survey.sanitize_cards_images!
// → LocationScope.sanitize_card!); this mirrors its two rules so the panel
// never shows a setting that won't survive the save: Country alone is
// "countries only" and has no city limit, and a city must sit inside the
// chosen countries.
const PLACE_ORDER = ["country", "region", "city", "town", "village", "district"]
const MAX_COUNTRIES = 10
const MAX_CITIES = 10

export default class extends Controller {
  static targets = ["place", "placesNote", "countryChips", "countrySelect", "citiesSection",
                    "cityChips", "cityInput", "cityResults", "removeLabel"]
  static values  = { citiesUrl: String, placeholders: Object }

  disconnect() {
    clearTimeout(this._cityTimer)
  }

  // Point the block at `card` and paint it from the card's stored scope.
  load(card) {
    this._card = card
    this._cityResults = []
    this._clearCityResults()
    if (this.hasCityInputTarget) this.cityInputTarget.value = ""
    this._render()
  }

  togglePlace(event) {
    if (!this._card) return
    const place = event.currentTarget.dataset.place
    const places = new Set(this._read("Places"))
    places.has(place) ? places.delete(place) : places.add(place)
    this._write("Places", PLACE_ORDER.filter(p => places.has(p)))
    // Countries only: a country can't be inside a city.
    if (this._countriesOnly()) this._write("Cities", [])
    this._changed()
  }

  addCountry(event) {
    const code = event.currentTarget.value
    event.currentTarget.value = ""
    if (!this._card || !code) return
    const countries = this._read("Countries")
    if (!countries.includes(code) && countries.length < MAX_COUNTRIES) {
      this._write("Countries", countries.concat(code))
      // A city already chosen outside the new country set would be dropped by
      // the server on save — drop it here, where the creator can see it go.
      this._write("Cities", this._read("Cities").filter(c => this._read("Countries").includes(c.country_code)))
    }
    this._changed()
  }

  remove(event) {
    if (!this._card) return
    const { kind, index } = event.currentTarget.dataset
    const list = this._read(kind)
    list.splice(Number(index), 1)
    this._write(kind, list)
    if (kind === "Countries" && list.length) {
      this._write("Cities", this._read("Cities").filter(c => list.includes(c.country_code)))
    }
    this._changed()
  }

  searchCities() {
    clearTimeout(this._cityTimer)
    this._cityTimer = setTimeout(() => this._runCitySearch(), 350)
  }

  cityKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      if (this._cityResults?.length) this._addCity(0)
    } else if (event.key === "Escape") {
      this._clearCityResults()
    }
  }

  pickCity(event) {
    this._addCity(Number(event.currentTarget.dataset.index))
  }

  async _runCitySearch() {
    const q = this.cityInputTarget.value.trim()
    if (q.length < 3 || !this.hasCitiesUrlValue) { this._clearCityResults(); return }
    const params = new URLSearchParams({ q })
    this._read("Countries").forEach(c => params.append("countries[]", c))
    const token = (this._cityToken = (this._cityToken || 0) + 1)
    try {
      const resp = await fetch(`${this.citiesUrlValue}?${params}`, { headers: { "Accept": "application/json" } })
      const data = await resp.json()
      if (token !== this._cityToken) return
      this._cityResults = Array.isArray(data.results) ? data.results : []
      this._renderCityResults()
    } catch (_) {
      this._clearCityResults()
    }
  }

  _addCity(idx) {
    const r = this._cityResults?.[idx]
    if (!this._card || !r) return
    const cities = this._read("Cities")
    const dup = cities.some(c => c.name.toLowerCase() === String(r.name).toLowerCase() && c.country_code === r.country_code)
    if (!dup && cities.length < MAX_CITIES) {
      this._write("Cities", cities.concat({ name: r.name, country_code: r.country_code, bbox: r.bbox }))
    }
    this.cityInputTarget.value = ""
    this._clearCityResults()
    this._changed()
  }

  _changed() {
    this._render()
    this._rewordCard()
    this.dispatch("changed")
  }

  _render() {
    if (!this._card) return
    const places = this._read("Places")
    this.placeTargets.forEach(btn => {
      const on = places.includes(btn.dataset.place)
      btn.classList.toggle("is-active", on)
      btn.setAttribute("aria-pressed", String(on))
    })
    if (this.hasPlacesNoteTarget) this.placesNoteTarget.hidden = places.length > 0

    const names = new Map(Array.from(this.countrySelectTarget.options).map(o => [o.value, o.textContent]))
    this.countryChipsTarget.innerHTML = this._chips("Countries", this._read("Countries").map(c => names.get(c) || c))
    this.citiesSectionTarget.hidden = this._countriesOnly()
    this.cityChipsTarget.innerHTML = this._chips("Cities", this._read("Cities").map(c => `${c.name} (${c.country_code})`))
  }

  _chips(kind, labels) {
    const remove = this.hasRemoveLabelTarget ? this.removeLabelTarget.innerHTML.trim() : "Remove"
    return labels.map((label, i) => `
      <li class="location-scope-chip">
        <span>${this._esc(label)}</span>
        <button type="button" class="location-scope-chip-remove" aria-label="${this._esc(remove)} ${this._esc(label)}"
                data-kind="${kind}" data-index="${i}" data-action="click->location-scope#remove">×</button>
      </li>`).join("")
  }

  _renderCityResults() {
    if (!this._cityResults.length) { this._clearCityResults(); return }
    this.cityResultsTarget.innerHTML = this._cityResults.map((r, i) => `
      <li><button type="button" class="location-search-result" data-index="${i}"
                  data-action="click->location-scope#pickCity">${this._esc(r.display_name)}</button></li>`).join("")
    this.cityResultsTarget.hidden = false
  }

  _clearCityResults() {
    this._cityResults = []
    if (this.hasCityResultsTarget) { this.cityResultsTarget.hidden = true; this.cityResultsTarget.innerHTML = "" }
  }

  // The card's own search box is the respondent's view of this setting, so
  // it rewords as levels are ticked — same key choice as
  // LocationScope.placeholder_key on the server.
  _rewordCard() {
    const field = this._card?.querySelector(".location-search-field")
    if (!field) return
    const places = this._read("Places")
    const key = places.length === 0 ? "none" : places.length === 1 ? places[0] : "any"
    const text = this.placeholdersValue[key]
    if (text) field.placeholder = text
  }

  _countriesOnly() {
    const places = this._read("Places")
    return places.length === 1 && places[0] === "country"
  }

  _read(kind) {
    try {
      const v = JSON.parse(this._card?.dataset[`cardLocation${kind}`] || "[]")
      return Array.isArray(v) ? v : []
    } catch (_) {
      return []
    }
  }

  _write(kind, list) {
    const attr = `cardLocation${kind}`
    if (list.length) this._card.dataset[attr] = JSON.stringify(list)
    else delete this._card.dataset[attr]
  }

  _esc(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
  }
}
