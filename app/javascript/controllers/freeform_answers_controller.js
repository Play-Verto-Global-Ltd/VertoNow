import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// The results page's "View all answers" panel for a freeform question.
//
// The result card previews a handful of answers; this opens every one of
// them, paged from SurveyTextAnswersController (100 at a time, newest first,
// within the segment and date range the page is showing) with a search box
// that asks the server rather than filtering what happens to be loaded — so
// "find every answer mentioning X" is true across all of them, not the first
// page. One shell on the page, outside the results-feed frame; each card's
// button carries its own URL and question as Stimulus params.
//
// Bounds the number of pages "Copy all" will walk. Fifty pages is five
// thousand answers — more than anyone pastes into a document, and a ceiling
// that stops a runaway loop against a Verto with far more.
const COPY_ALL_MAX_PAGES = 50

export default class extends Controller {
  static targets = ["modal", "eyebrow", "question", "search", "list", "status", "more", "copy"]

  connect() {
    this._answers = []
    this._seq = 0
  }

  // Params: url (required), question, and an optional eyebrow — the line
  // over the question that says what KIND of text this is. A freeform card
  // leaves it at the shell's default ("Freeform answers"); a closed card's
  // write-ins pass their own, and the next open without one puts the default
  // back rather than leaving the last caller's label on someone else's panel.
  open(event) {
    const { url, question, eyebrow } = event.params
    if (!url) return
    this.url   = url
    this.query = ""
    this.page  = 0
    this._answers = []
    if (this.hasEyebrowTarget) this.eyebrowTarget.textContent = eyebrow || this.eyebrowTarget.dataset.defaultLabel || ""
    this.questionTarget.textContent = question || ""
    this.searchTarget.value = ""
    this.listTarget.innerHTML = ""
    this.moreTarget.hidden = true
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
    this._load(1)
    this.searchTarget.focus()
  }

  close() {
    // An in-flight page must not paint into a closed panel, and neither may
    // a pending search: Escape inside a type=search field also clears it and
    // fires input, which would otherwise schedule an unfiltered reload.
    this._seq++
    clearTimeout(this._debounce)
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  closeOnEsc() {
    if (this._isOpen()) this.close()
  }

  // Debounced: the server is asked once the typing pauses, not per keystroke.
  search() {
    clearTimeout(this._debounce)
    this._debounce = setTimeout(() => this._applySearch(), 300)
  }

  // Enter searches at once, without waiting out the pause — the reflex of
  // anyone who has used a search box. Also what makes the search testable
  // on a slow headless browser, where a timer can lag well past its delay.
  searchNow(event) {
    event.preventDefault()
    clearTimeout(this._debounce)
    this._applySearch()
  }

  _applySearch() {
    if (!this._isOpen()) return
    const q = this.searchTarget.value.trim()
    if (q === this.query) return
    this.query = q
    this._answers = []
    this.listTarget.innerHTML = ""
    this._load(1)
  }

  loadMore() {
    this._load(this.page + 1)
  }

  // Every answer the panel is showing — the pages not loaded yet included,
  // so "all" means all — one per paragraph, for pasting into a doc or a
  // message. The button says so when it's done, then goes back.
  async copy() {
    const button = this.copyTarget
    try {
      await this._loadRemaining()
      const text = this._answers.map(a => a.text).join("\n\n")
      if (!text || !navigator.clipboard) throw new Error("no clipboard")
      await navigator.clipboard.writeText(text)
      button.textContent = t("results.freeform_copied")
    } catch {
      button.textContent = t("results.freeform_copy_failed")
    }
    setTimeout(() => { button.textContent = button.dataset.copyLabel }, 2000)
  }

  async _loadRemaining() {
    let pages = 0
    while (!this.moreTarget.hidden && pages < COPY_ALL_MAX_PAGES) {
      const before = this._answers.length
      await this._load(this.page + 1)
      if (this._answers.length === before) break // refused or superseded: stop, don't spin
      pages++
    }
  }

  async _load(page) {
    const seq = ++this._seq
    this.statusTarget.textContent = t("results.freeform_loading")
    this.moreTarget.hidden = true

    const url = new URL(this.url, window.location.origin)
    url.searchParams.set("page", page)
    if (this.query) url.searchParams.set("q", this.query)
    else url.searchParams.delete("q")

    try {
      const res  = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      const data = await res.json()
      if (seq !== this._seq) return // superseded by a newer search, or closed
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`)

      this.page = data.page
      for (const answer of data.answers) {
        this._answers.push(answer)
        this.listTarget.appendChild(this._item(answer))
      }
      this._paintStatus(data)
      this.moreTarget.hidden = !data.has_more
    } catch {
      if (seq === this._seq) this.statusTarget.textContent = t("results.freeform_error")
    }
  }

  _paintStatus(data) {
    if (data.matched === 0) {
      this.statusTarget.textContent = t("results.freeform_none")
      return
    }
    const showing = t("results.freeform_showing", { shown: this._answers.length, total: data.matched })
    this.statusTarget.textContent = this.query
      ? `${t("results.freeform_matched", { matched: data.matched, total: data.total, q: this.query })} · ${showing}`
      : showing
  }

  _item(answer) {
    const item = document.createElement("div")
    item.className = "freeform-item"

    const text = document.createElement("div")
    text.className = "freeform-item__text"
    text.textContent = answer.text
    item.appendChild(text)

    if (answer.at) {
      const when = document.createElement("time")
      when.className = "freeform-item__when"
      when.dateTime = answer.at
      when.textContent = this._formatDate(answer.at)
      item.appendChild(when)
    }
    return item
  }

  _formatDate(iso) {
    try {
      const lang = document.documentElement.lang || undefined
      return new Date(iso).toLocaleDateString(lang, { day: "numeric", month: "short", year: "numeric" })
    } catch {
      return iso.slice(0, 10)
    }
  }

  _isOpen() {
    return this.hasModalTarget && !this.modalTarget.classList.contains("hidden")
  }
}
