import { Controller } from "@hotwired/stimulus"

// Mirrors Survey.shareable_image? — the three forms a crawler can actually
// fetch when it comes for og:image (a Pexels CDN URL, a same-origin Active
// Storage blob, an app-rooted asset path). Notably NOT a data: URL, which
// sanitize_image_url accepts for a card panel and which og:image cannot carry.
// The server is still the authority — update_settings applies the same rule and
// stores nil for anything else — but a tile that could never stick is worse
// than no tile, so the picker doesn't offer one.
const SHAREABLE_IMAGE = new RegExp(
  "^(?:" +
    "https://images\\.pexels\\.com/[\\w\\-./]+\\.(?:png|jpe?g|webp)(?:\\?[\\w%\\-=&.+]*)?" +
    "|/rails/active_storage/[^\\s'\"<>?]+\\.(?:png|jpe?g|webp|svg|gif)(?:\\?[^\\s'\"<>]*)?" +
    "|/[\\w\\-./]+\\.(?:png|jpe?g|webp|svg|gif)" +
  ")$", "i"
)

// In-feed consent-gate and thank-you cards. Each lives in the cards feed as
// an editable replica of the player's design: a CTA (styled like Add
// question) sits above the welcome card / below the last card until the
// creator adds one, then the card itself shows with contenteditable text.
// Text persists to consent_text / thankyou_title / thankyou_body via
// update_settings (the same endpoint as the publish panel's settings forms),
// debounced like the card autosave. Save state is relayed to the top-left
// status pill through the gate-cards:status event (survey-editor#gateStatus).
export default class extends Controller {
  static targets = [
    "consentCta", "consentCard", "consentBody", "consentLeft",
    "tyCta", "tyCard", "tyTitle", "tyBody", "tyForwardUrl", "tyForwardLabel",
    "tyTitleCount", "tyBodyCount",
    "shareCta", "shareCard", "shareTitle", "shareStory", "shareMessage",
    "shareTitleCount", "shareStoryCount", "shareMessageCount",
    "shareImage", "shareImageBtn", "shareImagePanel", "shareImageGrid",
    "joinCta", "joinCard", "joinTitle", "joinBody", "joinCtaText"
  ]
  static values = { url: String }

  // A Verto that already has share copy renders its card open, so the counters
  // have to be right before anyone types.
  connect() {
    if (this.hasShareTitleTarget) this._paintShareCounts()
    if (this.hasTyTitleTarget) this._paintThankyouCounts()
  }

  // The picture picker's dismiss listeners live on the document while it is
  // open. Leaving them behind a teardown would leave a closure holding a
  // detached panel and closing it on every click in the page.
  disconnect() {
    this._unbindShareImageDismiss()
  }

  addConsent() {
    clearTimeout(this._consentTimer)
    this.consentCtaTarget.hidden = true
    this.consentCardTarget.hidden = false
    const body = this.consentBodyTarget
    if (!body.textContent.trim()) body.textContent = body.dataset.defaultText || ""
    this._focusEnd(body)
    this._save({ consent_text: body.textContent.trim() })
  }

  removeConsent() {
    clearTimeout(this._consentTimer)
    this.consentCardTarget.hidden = true
    this.consentCtaTarget.hidden = false
    this.consentBodyTarget.textContent = this.consentBodyTarget.dataset.defaultText || ""
    // The design image goes with the gate — re-adding starts from a clean card.
    this._paintConsentImage("", "", "")
    this._save({ consent_text: "", consent_image: "", consent_image_credit: "", consent_image_credit_url: "" })
  }

  // Consent-gate design image, picked in the media-picker modal (its
  // "consent" mode dispatches media-picker:consentImage to here). Repaints
  // the in-feed replica's left panel and persists the survey-level
  // consent_image fields the same way the consent text saves.
  setConsentImage(event) {
    const { url = "", credit = "", creditUrl = "" } = event.detail || {}
    this._paintConsentImage(url, credit, creditUrl)
    this._save({
      consent_image: url,
      consent_image_credit: url ? credit : "",
      consent_image_credit_url: url ? creditUrl : ""
    })
  }

  // Mirrors media-picker's _setCardImage (photo-only path) against the gate
  // card's left panel — everything it paints carries [data-consent-media] so
  // a repaint/clear swaps cleanly with the server-rendered markup.
  _paintConsentImage(url, credit, creditUrl) {
    if (!this.hasConsentLeftTarget) return
    const left = this.consentLeftTarget
    left.querySelectorAll("[data-consent-media]").forEach(el => el.remove())
    if (!url) return
    const img = document.createElement("div")
    img.className = "split-left-img"
    img.dataset.consentMedia = "true"
    img.style.backgroundImage = `url('${url.replace(/'/g, "\\'")}')`
    left.prepend(img)
    const ov = document.createElement("div")
    ov.className = "split-left-overlay"
    ov.dataset.consentMedia = "true"
    img.after(ov)
    if (!credit) return
    const el = document.createElement("div")
    el.className = "split-left-credit"
    el.dataset.consentMedia = "true"
    const label = `Photo by ${credit}`
    if (creditUrl) {
      const a = document.createElement("a")
      a.href = creditUrl
      a.target = "_blank"
      a.rel = "noopener nofollow"
      a.textContent = label
      el.replaceChildren(a)
    } else {
      el.textContent = label
    }
    ov.after(el)
  }

  // The text is captured NOW, not read from the DOM when the timer fires. A
  // closure that reads the element 900ms later reads whatever any sibling
  // handler has since written into it — and removeConsent resets that element
  // to its default text, so a pending keystroke timer would post the DEFAULT
  // consent copy a moment after the gate was removed, silently putting a live
  // consent gate back on a Verto the creator had just taken it off.
  queueConsentSave() {
    clearTimeout(this._consentTimer)
    const text = this.consentBodyTarget.textContent.trim()
    this._consentTimer = setTimeout(() => this._save({ consent_text: text }), 900)
  }

  addThankyou() {
    clearTimeout(this._tyTimer)
    this.tyCtaTarget.hidden = true
    this.tyCardTarget.hidden = false
    this._focusEnd(this.tyTitleTarget)
    this._saveThankyou()
  }

  removeThankyou() {
    clearTimeout(this._tyTimer)
    this.tyCardTarget.hidden = true
    this.tyCtaTarget.hidden = false
    // Back to the player defaults, which is what the reopened card shows.
    this.tyTitleTarget.textContent = this.tyTitleTarget.dataset.defaultText || ""
    // The message box is EMPTY by default, and its data-default-text is the
    // placeholder rather than a value — writing it in would put the
    // placeholder's own words in the box as though they had been typed.
    this.tyBodyTarget.textContent = ""
    this._paintThankyouCounts()
    // The off-site link goes with the screen. Leaving it behind would keep a
    // live redirect on a thank-you screen the creator believes they removed,
    // with nothing in the editor still showing it.
    if (this.hasTyForwardUrlTarget) this.tyForwardUrlTarget.value = ""
    if (this.hasTyForwardLabelTarget) this.tyForwardLabelTarget.value = ""
    this._save({ thankyou_title: "", thankyou_body: "", forward_url: "", forward_label: "" })
  }

  queueThankyouSave() {
    clearTimeout(this._tyTimer)
    this._paintThankyouCounts()
    this._tyTimer = setTimeout(() => this._saveThankyou(), 900)
  }

  blockEnter(event) {
    event.preventDefault()
  }

  // ── Share card ────────────────────────────────────────────────────────────
  // Three columns describing what a passed-on /play link says about itself.
  // Unlike the thank-you card these start EMPTY rather than prefilled with the
  // fallback: the placeholder shows what the link says today, and typing over
  // a prefilled default is how a creator ends up "customising" copy they never
  // meant to touch.
  addShare() {
    clearTimeout(this._shareTimer)
    this.shareCtaTarget.hidden = true
    this.shareCardTarget.hidden = false
    this._paintShareCounts()
    this._focusEnd(this.shareTitleTarget)
  }

  removeShare() {
    clearTimeout(this._shareTimer)
    this.shareCardTarget.hidden = true
    this.shareCtaTarget.hidden = false
    this.shareTitleTarget.textContent = ""
    this.shareStoryTarget.textContent = ""
    this.shareMessageTarget.textContent = ""
    this._paintShareCounts()
    // The picked preview picture goes with the card, and the panel it was
    // picked in goes with it: leaving share_image set would keep an override
    // on a link whose card the creator has just taken off, with nothing on
    // screen still showing it — and share_copy? would reopen the card on the
    // next load as though the removal had not happened.
    this.closeShareImage({ refocus: false })
    if (this.hasShareImagePanelTarget) {
      this.shareImagePanelTarget.dataset.current = ""
      const auto = this.shareImagePanelTarget.dataset.autoUrl
      if (this.hasShareImageTarget && auto) this.shareImageTarget.src = auto
    }
    // Clearing all four puts the link back on the fallback tags, which is what
    // removing the card means. Nothing is lost that the creator can still see.
    this._save({ share_title: "", share_description: "", share_message: "", share_image: "" })
  }

  // Text captured at queue time, not read from the DOM when the timer fires —
  // the same rule as queueConsentSave above, and for the same reason: removeShare
  // blanks these elements, so a pending timer that re-read them could post
  // whatever the reset left behind a moment after the card was removed.
  queueShareSave() {
    clearTimeout(this._shareTimer)
    this._paintShareCounts()
    const fields = {
      share_title: this.shareTitleTarget.textContent.trim(),
      share_description: this.shareStoryTarget.textContent.trim(),
      share_message: this.shareMessageTarget.textContent.trim()
    }
    this._shareTimer = setTimeout(() => this._save(fields), 900)
  }

  // Counters are advisory: the cap is applied server-side in update_settings, so
  // this only has to tell the creator before the truncation does.
  _paintShareCounts() {
    this._paintCounts([
      [ this.shareTitleTarget, this.shareTitleCountTarget ],
      [ this.shareStoryTarget, this.shareStoryCountTarget ],
      [ this.shareMessageTarget, this.shareMessageCountTarget ]
    ])
  }

  // ── Share card: the preview picture ───────────────────────────────────────
  // The one part of the unfurl a creator could look at and not change. Behind
  // it sits Survey#default_share_image_path — consent image, then backdrop,
  // then the first card that has a picture, then a theme-matched one from the
  // library — which is a fine guarantee and a poor decision: it hands the only
  // thing a stranger sees before reading a word to whichever card happens to
  // come first. So the derivation stays as the default and share_image is an
  // override on top of it, picked from the pictures this Verto already carries.

  toggleShareImage() {
    if (!this.shareImagePanelTarget.hidden) return this.closeShareImage()
    this._paintShareImageGrid()
    this.shareImagePanelTarget.hidden = false
    this.shareImageBtnTarget.setAttribute("aria-expanded", "true")
    // Bound on open, dropped on close. The click that opened the panel is still
    // bubbling towards the document as this runs, which is why the handler
    // checks the trigger as well as the panel — without that it would arrive at
    // the document a moment later and close what it had just opened.
    this._shareImageAway = (event) => {
      if (this.shareImagePanelTarget.contains(event.target)) return
      if (this.shareImageBtnTarget.contains(event.target)) return
      this.closeShareImage({ refocus: false })
    }
    this._shareImageEsc = (event) => { if (event.key === "Escape") this.closeShareImage() }
    document.addEventListener("click", this._shareImageAway)
    document.addEventListener("keydown", this._shareImageEsc)
  }

  closeShareImage({ refocus = true } = {}) {
    if (!this.hasShareImagePanelTarget || this.shareImagePanelTarget.hidden) return
    this.shareImagePanelTarget.hidden = true
    this.shareImageBtnTarget.setAttribute("aria-expanded", "false")
    // Focus goes back to what opened the panel, not to wherever the dismissing
    // click landed — otherwise closing it steals the caret out of the headline.
    if (refocus) this.shareImageBtnTarget.focus()
    this._unbindShareImageDismiss()
  }

  _unbindShareImageDismiss() {
    if (this._shareImageAway) document.removeEventListener("click", this._shareImageAway)
    if (this._shareImageEsc) document.removeEventListener("keydown", this._shareImageEsc)
    this._shareImageAway = null
    this._shareImageEsc = null
  }

  // Delegated from the grid, so a tile built a moment ago is live without
  // waiting for Stimulus to notice its action attribute.
  pickShareImage(event) {
    const tile = event.target.closest(".share-image-tile")
    if (!tile) return
    this._applyShareImage(tile.dataset.url || "")
    this.closeShareImage()
  }

  // "" is the Automatic tile: it clears the override rather than storing a URL,
  // so the link goes back to being chosen for the creator — and the thumbnail
  // shows what that choice currently is, which is what the panel is carrying.
  _applyShareImage(url) {
    const panel = this.shareImagePanelTarget
    panel.dataset.current = url
    const shown = url || panel.dataset.autoUrl || ""
    if (this.hasShareImageTarget && shown) this.shareImageTarget.src = shown
    this._save({ share_image: url })
  }

  _paintShareImageGrid() {
    const panel   = this.shareImagePanelTarget
    const current = panel.dataset.current || ""
    const found   = this._shareImageCandidates()
    // Automatic first and always, whatever the deck is carrying: it is how the
    // override is undone, and a Verto with no pictures of its own still has one.
    const tiles = [
      { url: "", label: panel.dataset.autoLabel || "", thumb: panel.dataset.autoUrl || "" },
      ...found
    ].map(tile => this._shareImageTile(tile, current))

    if (!found.length && panel.dataset.emptyLabel) {
      const note = document.createElement("p")
      note.className = "share-image-empty"
      note.textContent = panel.dataset.emptyLabel
      tiles.push(note)
    }
    this.shareImageGridTarget.replaceChildren(...tiles)
  }

  _shareImageTile({ url, label, thumb }, current) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "share-image-tile"
    btn.dataset.url = url
    btn.setAttribute("aria-pressed", String(url === current))
    if (url === current) btn.classList.add("is-picked")

    const img = document.createElement("img")
    img.className = "share-image-tile-img"
    img.src = thumb || url
    img.alt = ""
    img.loading = "lazy"

    const cap = document.createElement("span")
    cap.className = "share-image-tile-label"
    cap.textContent = label || ""

    btn.append(img, cap)
    return btn
  }

  // Every picture this Verto already carries, read from the feed at open time
  // rather than from a list rendered with the page. The media picker writes a
  // new card image straight onto data-card-image and repaints the panel — no
  // reload — so a baked-in list would be missing exactly the picture the
  // creator had just added, which is the one they came here to choose.
  //
  // Deduped by URL: the same photo used on three cards is one choice, not three.
  _shareImageCandidates() {
    const panel = this.shareImagePanelTarget
    const tpl   = panel.dataset.cardLabel || ""
    const seen  = new Set()
    const out   = []
    const push = (url, label) => {
      const clean = (url || "").trim()
      if (!clean || seen.has(clean) || !SHAREABLE_IMAGE.test(clean)) return
      seen.add(clean)
      out.push({ url: clean, label })
    }

    this.element.querySelectorAll("[data-survey-editor-target='card']").forEach(card => {
      const label = tpl.replace("%{number}", card.dataset.cardNum || "")
      push(card.dataset.cardImage, label)
      // The animation backdrop. A card whose panel is a Lottie or a range
      // reaction still carries a photograph, and it is a photograph of this
      // Verto — the fall-through reaches these too (Survey#first_card_image).
      this._jsonish(card.dataset.cardMediaBg, bg => push(bg?.image, label))
      // …and the mobile background, which is a photograph of this Verto too
      // (Survey#first_card_image reaches it the same way).
      this._jsonish(card.dataset.cardMobileBg, bg => push(bg?.image, label))
      // A tap card's statement pictures. "Any card image" means these as well:
      // they are often the strongest pictures in a deck, and the derivation
      // this panel overrides could never reach them at all.
      this._jsonish(card.dataset.cardOptionImages, imgs => {
        if (Array.isArray(imgs)) imgs.forEach(img => push(img, label))
      })
      // A clip's poster frame — the only still a video card has.
      push(card.dataset.cardVideoPoster, label)
    })

    // The Verto's backdrop and the consent gate's picture. Both are steps in
    // the derivation this panel replaces, so leaving them out would make
    // choosing deliberately a way to LOSE options rather than gain them.
    push(this._cssUrl(this.element.querySelector("[data-media-picker-target='bgThumb']")?.style?.backgroundImage),
         panel.dataset.backdropLabel)
    if (this.hasConsentLeftTarget) {
      push(this._cssUrl(this.consentLeftTarget.querySelector(".split-left-img")?.style?.backgroundImage),
           panel.dataset.gateLabel)
    }
    return out
  }

  _jsonish(raw, fn) {
    if (!raw) return
    try { fn(JSON.parse(raw)) } catch (_e) { /* malformed — nothing to offer */ }
  }

  // url("…") → the bare URL. The backdrop and the gate picture live in inline
  // styles rather than in a dataset, so this is the only place they can be read
  // from — media_picker#_currentBg reads the same property the same way.
  _cssUrl(value) {
    const match = /^url\((['"]?)([\s\S]*)\1\)$/.exec((value || "").trim())
    return match ? match[2] : ""
  }

  // The thank-you card's two boxes, which had no counters at all — so an end
  // message was cut at the server's cap with nothing on screen to say it
  // would be ("the end message gets cut off, I assume because of character
  // limit"). Same advisory contract as the share card's.
  _paintThankyouCounts() {
    this._paintCounts([
      [ this.tyTitleTarget, this.hasTyTitleCountTarget ? this.tyTitleCountTarget : null ],
      [ this.tyBodyTarget, this.hasTyBodyCountTarget ? this.tyBodyCountTarget : null ]
    ])
  }

  _paintCounts(pairs) {
    pairs.forEach(([ field, count ]) => {
      if (!field || !count) return
      const max = parseInt(field.dataset.max, 10)
      const used = field.textContent.trim().length
      count.textContent = `${used} / ${max}`
      count.classList.toggle("is-over", Number.isFinite(max) && used > max)
    })
  }

  // ── The account ask ───────────────────────────────────────────────────────
  // No addJoin here on purpose. Turning the account ask ON can be REFUSED —
  // a Verto that asks the neurodiversity question may not also collect an
  // email — and the refusal comes back as a redirect, which _save's fetch
  // follows and reads as 200. So the "+ Ask them to join" CTA is a real form
  // submit in the template, and this controller only handles the off switch
  // and the copy, neither of which can fail.
  removeJoin() {
    clearTimeout(this._joinTimer)
    this.joinCardTarget.hidden = true
    this.joinCtaTarget.hidden = false
    // The copy is deliberately NOT cleared: turning the ask back on should
    // return the creator's own words, not the house ones. join_prompt_enabled
    // is what decides whether a respondent ever sees them.
    this._save({ join_prompt_enabled: "0" })
  }

  // Captured at queue time rather than read when the timer fires — the same
  // rule as the other three, and for the same reason.
  queueJoinSave() {
    clearTimeout(this._joinTimer)
    const fields = {
      join_title: this.joinTitleTarget.textContent.trim(),
      join_body: this.joinBodyTarget.textContent.trim(),
      join_cta: this.joinCtaTextTarget.textContent.trim()
    }
    this._joinTimer = setTimeout(() => this._save(fields), 900)
  }

  _saveThankyou() {
    this._save({
      thankyou_title: this.tyTitleTarget.textContent.trim(),
      thankyou_body: this.tyBodyTarget.textContent.trim(),
      forward_url: this.hasTyForwardUrlTarget ? this.tyForwardUrlTarget.value.trim() : "",
      forward_label: this.hasTyForwardLabelTarget ? this.tyForwardLabelTarget.value.trim() : ""
    })
  }

  async _save(fields) {
    if (!this.hasUrlValue || !this.urlValue) return
    this.dispatch("status", { detail: { state: "saving" } })
    try {
      const fd = new FormData()
      Object.entries(fields).forEach(([k, v]) => fd.append(k, v))
      const res = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "application/json"
        },
        body: fd
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      this.dispatch("status", { detail: { state: "saved", time: new Date().toLocaleTimeString() } })
    } catch (err) {
      this.dispatch("status", { detail: { state: "error", msg: err.message } })
    }
  }

  _focusEnd(el) {
    el.focus()
    const range = document.createRange()
    range.selectNodeContents(el)
    range.collapse(false)
    const sel = window.getSelection()
    sel.removeAllRanges()
    sel.addRange(range)
  }
}
