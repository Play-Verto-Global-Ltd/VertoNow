import { Controller } from "@hotwired/stimulus"
import { applyFocal, focalPercent, focalZoom, optionMediaStyle, FOCAL_ZOOM_MAX } from "lib/option_media"
import { isFullScreenAnswer } from "lib/full_screen_types"
import { inkForColor, inkForImage } from "lib/backdrop_ink"
import { t } from "lib/i18n"

// Modal that lets editors attach an image to a card's left panel.
// Two sources: file upload (stored as a data URL on the card JSON) and the
// curated Verto Library (asset paths under /assets/verto-library/...).
export default class extends Controller {
  static targets = [
    "backdrop", "modal", "tab", "pane",
    "fileInput", "dropzone", "uploadError",
    "libraryItem", "applyBtn", "clearBtn",
    "bgThumb", "bgRemoveBtn",
    "recommendedSection", "recommendedLabel", "recommendedGrid",
    "searchInput", "searchSection", "searchStatus", "searchGrid", "loadMore",
    "mediaToggle", "mediaTab",
    "saveToLibrary", "brandGrid", "libraryFileInput", "brandStatus",
    "lottieSection", "lottieInput", "lottieError", "lottieBtn",
    "animBgSection", "animBgColor", "animBgClear", "animBgLabel", "animBgHint",
    "animateAssetSection", "animateAssetToggle",
    "focalSection", "focalFrame", "focalImg",
    "cropStage", "cropFrame", "cropImg", "cropZoom",
    "cropHint", "cropHintLegacy", "cropSkipBtn",
    "posStage", "posFrame", "posImg", "posVideo", "posHint", "posHintVideo", "posCropBtn",
    "posZoom", "posChrome", "modalTitle"
  ]
  static values = { url: String, pexsearchUrl: String, moderateUrl: String, cardImageUrl: String, cardLottieUrl: String, libraryUrl: String, theme: String, backgroundRecommended: Array }

  // Uploaded images are normalised before they're stored: capped in source
  // size, downscaled to a max edge, and re-encoded to a compact format. Raw
  // multi-MB photos stored as base64 data URLs were the main memory driver
  // behind the production 502s, and unbounded dimensions/formats also rendered
  // inconsistently across devices.
  static SOURCE_BYTE_CAP = 12 * 1024 * 1024 // reject absurdly large uploads outright
  static MAX_EDGE        = 1600             // longest side, px
  static ENCODE_QUALITY  = 0.82
  static SVG_BYTE_CAP    = 500 * 1024       // SVGs skip downscaling, so cap them directly
  // GIFs skip downscaling too (see _readFile) — capped directly at the
  // server's own Survey::CARD_IMAGE_MAX_BYTES so nothing the client accepts
  // can still be rejected once it reaches CardImageStore.decode.
  static GIF_BYTE_CAP    = 3 * 1024 * 1024
  // The most inline base64 a card may KEEP — Survey::MAX_BACKGROUND_DATA_URL_BYTES,
  // measured on the data-URL string (JsConstantParityTest pins the two). It
  // only matters when _persistUpload has failed and the picture is about to be
  // carried inline: a raw GIF or an undecodable file near GIF_BYTE_CAP is
  // ~4 MB of base64, the sanitiser drops anything over this, and the creator
  // was left with "Saved, but an image didn't stick" on every autosave, with
  // re-uploading reproducing it exactly. Better to refuse at the upload pane,
  // where the message can say what to do.
  static INLINE_DATA_URL_CAP = 3000000

  // Fixed [width, height] output ratio per slot, matching PexelsClient::CROP_FOR
  // — a Pexels pick already arrives pre-cropped to these dimensions server-side,
  // so an upload should land on the card at the same shape. Only the modes
  // listed here get an interactive crop stage; consent/comms uploads keep
  // today's plain-downscale path (their slot isn't a fixed ratio the way a
  // card/background/tap-option art frame is).
  static CROP_RATIO = { card: [ 720, 1280 ], background: [ 1920, 1080 ], tapOption: [ 800, 800 ] }
  static CROP_ZOOM_MAX = 3 // how far past cover-fit the slider lets an editor punch in

  connect() {
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._mode = "card"
    this._optionIndex = null
    this._searchMedia = "photos"
    this._escListener = (e) => { if (e.key === "Escape") this.close() }
    this._cropImgEl = null
    // The re-crop record riding with a cropped upload: the uncropped original
    // and the crop rect taken from it, stashed by cropApply and consumed by
    // the card-image branch of applyImage. Null everywhere else — a pick with
    // no record stamps none onto the card.
    this._pendingSource = null
    this._pendingCrop = null
    // The Adjust flow: true while the crop stage is re-editing an existing
    // picture (reached from the reposition stage rather than from an upload),
    // with _adjustSource holding the stored original's URL so apply doesn't
    // re-persist bytes the server already has.
    this._adjustMode = false
    this._adjustSource = null
    // The reposition stage's subject: which card (and, for a tap card, which
    // statement) is being reframed, what its media is, and the element the
    // position is painted onto. Null whenever that stage is closed.
    this._posSlot = null
  }

  open(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event?.currentTarget
    const card    = trigger?.closest("[data-survey-editor-target='card']")
                 || trigger?.closest(".survey-card-wrap")
    if (!card) return
    this._mode = "card"
    // The backdrop section this modal shows (when it shows one) is the
    // HEADER's: the card's own picture and what sits behind it are one panel.
    this._bgSlot = "panel"
    this._activeCard = card
    this._pendingUrl = null
    this._pendingVideo = null
    this._pendingSource = null
    this._pendingCrop = null
    this._setApplyEnabled(false)

    // A range card has no photo/video/lottie slot of its own — its reaction
    // animation is swapped through the separate animation-picker modal. This
    // modal opens for such a card only for the per-card SETTINGS below (the
    // Animation background), so the source tabs/panes have nothing to act on
    // and stay hidden; openAnimBgImage() brings them back for its own "Use an
    // image" sub-flow regardless of card type.
    const isRange = card.dataset.cardType === "range"
    this._showMediaSwapUI(!isRange)
    if (isRange) {
      this.paneTargets.forEach(p => { p.hidden = true })
      this.clearBtnTarget.hidden = true
      // The colour/asset settings below all save live (_writeAnimBg calls
      // _notifyDirty itself) — there is never anything pending to Apply here
      // until "Use an image" is picked, so a permanently-disabled Apply only
      // reads as broken. openAnimBgImage() brings it back for that sub-flow.
      this.applyBtnTarget.hidden = true
    } else {
      this.applyBtnTarget.hidden = false
      // Open on the Verto Library so the curated designs are visible straight
      // away — uploading your own image is one click away on the other tab.
      this._switchTabKey("library")
      this._setMedia("photos")            // cards can be photo or video
      this._showMediaToggle(true)
      this._showLottieSection(true)       // paste-a-LottieFiles-URL, cards only

      const currentUrl = card.dataset.cardImage || card.dataset.cardVideo || card.dataset.cardLottie || ""
      this.clearBtnTarget.hidden = !currentUrl

      this._renderRecommended(this._parseUrls(card.dataset.cardRecommendedImages), "Recommended for this card")
      this._seedSearch()
    }
    this._syncAnimationBg()             // backdrop, only when the panel animates
    this._syncAnimateAsset()            // push in/out loop, photo or lottie only
    this._syncFocal()                   // mobile header position, images only
    // A range card's "Add media" IS its header backdrop — the section is all
    // that opens — so the head says so, the same as the pill that opened it.
    this._setModalTitle(isRange ? "background" : "default")

    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  // The modal is toggled with `hidden` rather than torn down, so its scroller
  // keeps whatever offset it had — and the sections above the fold (the stock
  // grid, the approved strip) un-hide ASYNCHRONOUSLY after it is already on
  // screen, pushing the view further down. Between them a creator opening Add
  // media landed part-way down the asset list, sometimes at the very bottom.
  // Called on open and again once those late sections have landed.
  _resetModalScroll() {
    const body = this.element.querySelector(".media-modal-body")
    if (!body) return
    body.scrollTop = 0
    requestAnimationFrame(() => { body.scrollTop = 0 })
  }

  // Opens the same modal for a Comms email image block. Photos only, no
  // Lottie, no per-card recommendations. Applying dispatches
  // media-picker:commsImage — comms_editor_controller owns the selected
  // block and paints it, so this controller stays survey-markup-free here.
  openComms(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this._mode = "comms"
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("upload")
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    this.clearBtnTarget.hidden = true
    this._renderRecommended([], "")
    this._seedSearch()
    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  // The "Header background" pill on a card's own panel. It opens the picker
  // already AIMED at the backdrop, and that is the whole of this method: it
  // used to share #open with "Change media", which opens the card's own media
  // picker with the backdrop folded into a section below it. So the obvious
  // thing to do in it — pick a photo, press Apply — filled the card's HERO,
  // and the creator watched a control labelled Background change something
  // else: "the pill shows but doesn't work, it's changing the left hand card
  // image not the background". Reported against the mobile background, but
  // the mis-aim was on every Background pill that isn't a range card's (range
  // hides the media tabs outright, which is why it never showed there).
  //
  // Same modal, same library, same Apply — `animBg` mode is what routes the
  // pick to a backdrop instead of to card.image, and the section stays open
  // above it so a colour is one click away from a picture. WHICH backdrop is
  // this._bgSlot: "panel" here (card.media_bg, the header's), "mobile" from
  // openMobileBackground below (card.mobile_bg). The two never share a
  // writer, so neither can reach the other's field.
  openCardBackground(event) {
    this._openBackdrop(event, "panel")
  }

  // The "Mobile background" pill — the same picker aimed at card.mobile_bg,
  // the colour or picture behind the question and answers on a phone. On
  // every type: what the header holds is irrelevant to what sits below it.
  // Everything a card's own picture can be, this can be — the Verto library,
  // the brand library, an upload (a GIF included: _readFile keeps its bytes),
  // the stock search — and nothing the creator does here touches the header:
  // "the Mobile Background and Mobile Header/Main Asset need to be treated as
  // completely separate properties/assets".
  openMobileBackground(event) {
    this._openBackdrop(event, "mobile")
  }

  _openBackdrop(event, slot) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event?.currentTarget
    const card    = trigger?.closest("[data-survey-editor-target='card']")
                 || trigger?.closest(".survey-card-wrap")
    if (!card) return
    this._activeCard = card
    this._mode = "animBg"
    this._bgSlot = slot
    this._pendingUrl = null
    this._pendingVideo = null
    this._pendingSource = null
    this._pendingCrop = null
    this._setApplyEnabled(false)
    this._showMediaSwapUI(true)
    this.applyBtnTarget.hidden = false
    this._switchTabKey("library")
    // Every source a card's own picture gets: the Verto Library and the brand
    // library on this tab, an upload on the other, and the stock search below
    // — "you need to be able to pick any media you wish as a mobile
    // background". Photos only is the one narrowing, and it is a storage fact
    // rather than a choice: media_bg holds a colour and an image, and a video
    // URL handed to it is rejected by sanitize_image_url on the way in. A
    // toggle offering one would be a toggle whose picks silently do not stick.
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    // "Remove current media" clears the card's OWN picture, which is not what
    // this modal is pointed at — offering it here is the same confusion one
    // button along.
    this.clearBtnTarget.hidden = true
    this._syncAnimationBg(true)
    this._syncAnimateAsset()
    this._syncFocal()
    // The curated strip comes too. These are chosen from the card's own words,
    // which is as good a starting point for what sits behind the answer as for
    // the picture itself — and leaving it out was the difference between a
    // picker and a cut-down one.
    this._renderRecommended(this._parseUrls(card.dataset.cardRecommendedImages),
                            "Recommended for this card")
    this._seedSearch()
    this._setModalTitle(slot === "mobile" ? "mobileBackground" : "background")
    // The colour swatch and Remove come FIRST when the modal is aimed at a
    // backdrop: they are the controls the pill promised ("change the colour"),
    // and below the whole library they were a scroll away from being found.
    this.modalTarget.classList.add("is-backdrop")
    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  // Opens the same modal but targets the Verto's backdrop instead of a card.
  openBackground(event) {
    event?.preventDefault()
    this._mode = "background"
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("library")
    // Backgrounds are photos only — a video can't be a Verto backdrop.
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    this.clearBtnTarget.hidden = !this._currentBg()
    this._renderRecommended(this.hasBackgroundRecommendedValue ? this.backgroundRecommendedValue : [], "Recommended backgrounds")
    this._seedSearch()
    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  // Opens the same modal but targets the consent gate's left panel. The gate
  // is a survey-level setting, not a card — applying dispatches to
  // gate-cards#setConsentImage, which paints the in-feed replica and persists
  // consent_image via update_settings. Photos only, like the Verto backdrop.
  openConsent(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this._mode = "consent"
    this._activeCard = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("library")
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    this.clearBtnTarget.hidden = !this._consentLeft()?.querySelector(".split-left-img")
    // The per-card "Recommended" list keys off a card's own content — the
    // gate has none, so lean on the theme-seeded stock search instead.
    this._renderRecommended([], "")
    this._seedSearch()
    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  _consentLeft() {
    return this.element.querySelector("[data-gate-cards-target='consentLeft']")
  }

  // Which statement a chip belongs to, taken from the DOM rather than from the
  // index baked into the markup. option_images is positional and deleting a
  // statement removes its node without renumbering the chips after it, so a
  // baked index goes stale the moment a statement is deleted — and pointed the
  // picker at a different statement than the one whose chip was clicked. DOM
  // order is the alignment everywhere else (see the serialiser); it is here
  // too. The attribute stays as the fallback, and as what marks a trigger as
  // a statement's rather than the card's own.
  _tapIndexFor(trigger, card) {
    const rotate = trigger?.closest(".rotate-card")
    if (rotate && card) {
      const i = Array.from(card.querySelectorAll(".rotate-card")).indexOf(rotate)
      if (i >= 0) return i
    }
    const raw = parseInt(trigger?.dataset.mediaPickerOptionIndex, 10)
    return Number.isNaN(raw) ? null : raw
  }

  // Opens the same modal but targets ONE tap-card statement's image instead
  // of the card's own left-panel image/video.
  openTapOption(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event?.currentTarget
    const card    = trigger?.closest("[data-survey-editor-target='card']")
                 || trigger?.closest(".survey-card-wrap")
    const index   = this._tapIndexFor(trigger, card)
    if (!card || index == null) return
    this._mode = "tapOption"
    this._optionIndex = index
    this._activeCard = card
    this._pendingUrl = null
    this._pendingVideo = null
    this._setApplyEnabled(false)
    this._switchTabKey("library")
    // A tap-card statement's image is a photo only — no video slot here.
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)

    const images = this._parseUrls(card.dataset.cardOptionImages)
    this.clearBtnTarget.hidden = !images[index]

    // The card-level "Recommended" list is for the card's own image, not any
    // one statement — leave it empty rather than showing designs for the
    // wrong slot.
    this._renderRecommended([], "")
    this._seedSearch()

    this.backdropTarget.hidden = false
    this._resetModalScroll()
    document.addEventListener("keydown", this._escListener)
  }

  close() {
    this.backdropTarget.hidden = true
    this.modalTarget.classList.remove("is-backdrop")
    this._activeCard = null
    this._bgSlot = null
    this._pendingUrl = null
    this._pendingVideo = null
    this._pendingSource = null
    this._pendingCrop = null
    this._setApplyEnabled(false)
    // Reset to shown: only open()'s range-card branch ever hides these, and
    // every other entry point (openBackground/openConsent/openComms/
    // openTapOption) relies on them being visible without setting it itself.
    this._showMediaSwapUI(true)
    this.applyBtnTarget.hidden = false
    this._switchTabKey("library")
    this.libraryItemTargets.forEach(i => i.setAttribute("aria-selected", "false"))
    if (this.hasFileInputTarget) this.fileInputTarget.value = ""
    this._clearUploadError()
    this._renderRecommended([], "")
    this._clearSearch()
    this._closeCropStage()
    this._closePosStage()
    document.removeEventListener("keydown", this._escListener)
  }

  backdropClick(event) {
    if (event.target === this.backdropTarget) this.close()
  }

  switchTab(event) {
    const key = event.currentTarget.dataset.tab
    this._switchTabKey(key)
  }

  _switchTabKey(key) {
    this.tabTargets.forEach(t =>
      t.setAttribute("aria-selected", t.dataset.tab === key ? "true" : "false")
    )
    this.paneTargets.forEach(p => { p.hidden = p.dataset.pane !== key })
  }

  // Hides the Upload/Verto Library tabs bar — irrelevant on open() for a
  // range card, which has no photo/video/lottie slot for them to fill.
  // openAnimBgImage() shows it again regardless of card type: picking a
  // backdrop image reuses these same tabs/panes.
  _showMediaSwapUI(show) {
    const tabs = this.element.querySelector(".media-modal-tabs")
    if (tabs) tabs.hidden = !show
  }

  // ── Upload tab ─────────────────────────────────────────
  fileChosen(event) {
    const file = event.target.files?.[0]
    if (file) this._readFile(file)
  }

  dragover(event)  { event.preventDefault(); this.dropzoneTarget.classList.add("is-drag") }
  dragleave()      { this.dropzoneTarget.classList.remove("is-drag") }
  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("is-drag")
    const file = event.dataTransfer?.files?.[0]
    if (file) this._readFile(file)
  }

  _readFile(file) {
    this._clearUploadError()
    // Uploaded images carry no photographer credit.
    this._pendingCredit = ""
    this._pendingCreditUrl = ""
    // Some browsers report a blank `type` for formats they don't recognise by
    // sniffing (HEIC/HEIF is the common case) — fall back to the extension
    // rather than rejecting a file that might be perfectly fine.
    const name = file.name || ""
    const looksLikeImage = file.type.startsWith("image/") || /\.(jpe?g|png|gif|webp|heic|heif|svg)$/i.test(name)
    if (!looksLikeImage) {
      this._showUploadError("That doesn't look like an image file.")
      return
    }
    if (file.size > this.constructor.SOURCE_BYTE_CAP) {
      const mb = Math.round(this.constructor.SOURCE_BYTE_CAP / (1024 * 1024))
      this._showUploadError(`That image is too large — please choose one under ${mb} MB.`)
      return
    }
    // HEIC/HEIF (the default iPhone photo format) can't be decoded on a canvas
    // in most browsers — Safari 17+ is the exception. Rather than silently
    // falling through to the raw-file path below and forwarding an
    // undownscaled multi-MB blob the server will likely reject anyway, say so
    // up front.
    if (file.type === "image/heic" || file.type === "image/heif" || /\.hei[cf]$/i.test(name)) {
      this._showUploadError("iPhone HEIC photos aren't supported yet — please convert to JPEG or PNG and try again.")
      return
    }
    // SVGs are vector and usually tiny; rasterising them on a canvas would only
    // make them bigger and blurry, so keep them as-is — but a hand-exported or
    // embedded-raster SVG can still be large, so cap it directly since it skips
    // the downscale step that normally bounds upload size. Bypasses the crop
    // stage entirely too, for the same reason: there's no raster to re-encode.
    if (file.type === "image/svg+xml") {
      if (file.size > this.constructor.SVG_BYTE_CAP) {
        const kb = Math.round(this.constructor.SVG_BYTE_CAP / 1024)
        this._showUploadError(`That SVG is too large — please choose one under ${kb} KB.`)
        return
      }
      this._readAsDataUrl(file)
      return
    }
    // GIFs are frame sequences — drawing one onto a canvas (what both the
    // crop stage and the plain downscale path do) captures only whichever
    // frame happened to be current, silently flattening the animation to a
    // single still. Store the original bytes untouched instead, same as SVG,
    // and skip the crop stage for the same reason: there's no single frame
    // to crop that wouldn't also freeze the animation.
    if (file.type === "image/gif" || /\.gif$/i.test(name)) {
      if (file.size > this.constructor.GIF_BYTE_CAP) {
        const mb = Math.round(this.constructor.GIF_BYTE_CAP / (1024 * 1024))
        this._showUploadError(`That GIF is too large — please choose one under ${mb} MB.`)
        return
      }
      this._readAsDataUrl(file)
      return
    }
    // A fixed-ratio slot gets an interactive crop stage; everything else
    // (consent gate, comms image block) keeps the plain downscale-and-stash
    // path this always had.
    if (this.constructor.CROP_RATIO[this._mode]) this._openCropStage(file)
    else this._downscale(file)
  }

  // Re-encodes a canvas to WebP, falling back to JPEG. Shared by the plain
  // downscale path and the crop stage's single final encode.
  _encodeCanvas(canvas) {
    const q = this.constructor.ENCODE_QUALITY
    try {
      const webp = canvas.toDataURL("image/webp", q)
      // Browsers without WebP encoding silently return PNG — fall back to JPEG
      // so we never store an unexpectedly large PNG.
      if (webp.startsWith("data:image/webp")) return webp
    } catch (_e) { /* fall through to JPEG */ }
    return canvas.toDataURL("image/jpeg", q)
  }

  // Draws an already-decoded image onto a canvas capped at MAX_EDGE on its
  // longest side and encodes it — the plain, uncropped path a fresh upload
  // (via _downscale) and a skipped crop stage both end up at.
  _downscaledDataUrl(img) {
    const maxEdge = this.constructor.MAX_EDGE
    const scale = Math.min(1, maxEdge / Math.max(img.width, img.height))
    const w = Math.max(1, Math.round(img.width * scale))
    const h = Math.max(1, Math.round(img.height * scale))
    const canvas = document.createElement("canvas")
    canvas.width = w
    canvas.height = h
    canvas.getContext("2d").drawImage(img, 0, 0, w, h)
    return this._encodeCanvas(canvas)
  }

  // Decode + downscale + re-encode, skipping the crop stage outright (used for
  // brand-library uploads, which aren't headed for any one fixed-ratio slot).
  // Both encoders complete through `done`, defaulting to the card-apply flow
  // (stash as the pending pick). The add-to-library tile passes its own
  // completion instead.
  _downscale(file, done = this._stashPending.bind(this)) {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      done(this._downscaledDataUrl(img))
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      // Couldn't decode (exotic format) — fall back to the raw file so the user
      // isn't blocked; the server-side size cap is the backstop.
      this._readAsDataUrl(file, done)
    }
    img.src = url
  }

  // ── Crop stage ──────────────────────────────────────────
  // Sits between decode and stash for a fixed-ratio slot (card/background/
  // tap-option — see CROP_RATIO): drag to reposition, a slider to zoom, single
  // final encode straight from the ORIGINAL decoded image so quality is never
  // lost to an intermediate downscale. Runs before moderation and persistence
  // — applyImage() moderates and stores whatever _stashPending receives here,
  // same as any other pending pick, so the crop is exactly what ships.

  // Decode the file once, then open the crop UI against that one Image —
  // Skip and Apply both read from it, so nothing is decoded twice.
  _openCropStage(file) {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      this._cropObjectUrl = url
      this._cropImgEl = img
      if (this.hasCropImgTarget) this.cropImgTarget.src = url
      const [ rw, rh ] = this.constructor.CROP_RATIO[this._mode]
      if (this.hasCropFrameTarget) this.cropFrameTarget.style.aspectRatio = `${rw} / ${rh}`
      this._showCropStage(true)
      this._setModalTitle("crop")
      // The frame's rendered size depends on the aspect-ratio just applied —
      // defer a frame so getBoundingClientRect reflects the real layout.
      requestAnimationFrame(() => this._layoutCrop())
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      // Couldn't decode for cropping either — degrade exactly like _downscale
      // does: forward the raw file rather than blocking the upload.
      this._readAsDataUrl(file)
    }
    img.src = url
  }

  // Cover-fits the image into the frame (never leaves a gap), centred, at
  // zoom 1 — the same starting point every time the stage opens.
  _layoutCrop() {
    if (!this._cropImgEl || !this.hasCropFrameTarget) return
    const rect = this.cropFrameTarget.getBoundingClientRect()
    this._cropFrameW = rect.width
    this._cropFrameH = rect.height
    this._cropMinScale = Math.max(
      this._cropFrameW / this._cropImgEl.naturalWidth,
      this._cropFrameH / this._cropImgEl.naturalHeight
    )
    this._cropZoomFactor = 1
    if (this.hasCropZoomTarget) this.cropZoomTarget.value = "1"
    this._cropScale = this._cropMinScale
    this._setCropOffset(
      (this._cropFrameW - this._cropImgEl.naturalWidth * this._cropScale) / 2,
      (this._cropFrameH - this._cropImgEl.naturalHeight * this._cropScale) / 2
    )
  }

  // Clamp so the image always fully covers the frame (no gap on any edge),
  // then paint.
  _setCropOffset(x, y) {
    const dispW = this._cropImgEl.naturalWidth  * this._cropScale
    const dispH = this._cropImgEl.naturalHeight * this._cropScale
    const minX = Math.min(0, this._cropFrameW - dispW)
    const minY = Math.min(0, this._cropFrameH - dispH)
    this._cropOffsetX = Math.min(0, Math.max(minX, x))
    this._cropOffsetY = Math.min(0, Math.max(minY, y))
    this._paintCropTransform()
  }

  _paintCropTransform() {
    if (!this.hasCropImgTarget) return
    this.cropImgTarget.style.transform = `translate(${this._cropOffsetX}px, ${this._cropOffsetY}px) scale(${this._cropScale})`
  }

  cropDragStart(event) {
    if (!this._cropImgEl) return
    event.preventDefault()
    // Best-effort: a pointer id the browser won't let us capture (some
    // synthetic/edge-case pointers) should still let the drag itself proceed
    // via the ordinary move/up events rather than aborting cropDragStart here.
    try { this.cropFrameTarget.setPointerCapture?.(event.pointerId) } catch (_e) { /* no-op */ }
    this._cropDragging = true
    this._cropDragStartX = event.clientX
    this._cropDragStartY = event.clientY
    this._cropDragOriginX = this._cropOffsetX
    this._cropDragOriginY = this._cropOffsetY
  }

  cropDrag(event) {
    if (!this._cropDragging) return
    event.preventDefault()
    this._setCropOffset(
      this._cropDragOriginX + (event.clientX - this._cropDragStartX),
      this._cropDragOriginY + (event.clientY - this._cropDragStartY)
    )
  }

  cropDragEnd(event) {
    if (!this._cropDragging) return
    this._cropDragging = false
    try { this.cropFrameTarget.releasePointerCapture?.(event.pointerId) } catch (_e) { /* no-op */ }
  }

  // Zoom slider: 1 = cover-fit, CROP_ZOOM_MAX = punched all the way in.
  // Re-anchors on the frame's centre point (in image space) so zooming feels
  // centred instead of yanking the image toward the top-left corner.
  cropZoomChanged(event) {
    if (!this._cropImgEl) return
    const factor = parseFloat(event.target.value) || 1
    const oldScale = this._cropScale
    const cx = (this._cropFrameW / 2 - this._cropOffsetX) / oldScale
    const cy = (this._cropFrameH / 2 - this._cropOffsetY) / oldScale
    this._cropScale = this._cropMinScale * factor
    this._setCropOffset(
      this._cropFrameW / 2 - cx * this._cropScale,
      this._cropFrameH / 2 - cy * this._cropScale
    )
  }

  // Output canvas size for the active slot: the mode's fixed ratio, scaled
  // down (never up) so its longest edge respects MAX_EDGE — mirrors how the
  // plain downscale path bounds its own output.
  _cropOutputDims() {
    const [ rw, rh ] = this.constructor.CROP_RATIO[this._mode]
    const scale = Math.min(1, this.constructor.MAX_EDGE / Math.max(rw, rh))
    return [ Math.max(1, Math.round(rw * scale)), Math.max(1, Math.round(rh * scale)) ]
  }

  // Single encode straight from the original decoded image: the frame's
  // current pan/zoom converts directly to a source rectangle, drawn once onto
  // the target-sized canvas — no intermediate downscale to lose quality to.
  cropApply(event) {
    event?.preventDefault()
    if (!this._cropImgEl) return
    const srcX = -this._cropOffsetX / this._cropScale
    const srcY = -this._cropOffsetY / this._cropScale
    const srcW = this._cropFrameW / this._cropScale
    const srcH = this._cropFrameH / this._cropScale
    const [ outW, outH ] = this._cropOutputDims()
    const canvas = document.createElement("canvas")
    canvas.width = outW
    canvas.height = outH
    canvas.getContext("2d").drawImage(this._cropImgEl, srcX, srcY, srcW, srcH, 0, 0, outW, outH)
    const dataUrl = this._encodeCanvas(canvas)

    // What re-cropping later needs, and the single encode above destroys: the
    // uncropped original (bounded by the same MAX_EDGE downscale as any plain
    // upload — an Adjust pass reuses the stored path instead of re-encoding
    // bytes the server already has) and where this crop sits in it, as
    // fractions of the natural size so the record survives any resize of the
    // stored source. Card heroes only for now: a tap option or background has
    // no Adjust entry point yet, and an unconsumed record on those modes
    // would be a stale thing waiting for a code path to trip over it.
    let source = null
    let crop = null
    if (this._mode === "card") {
      const nw = this._cropImgEl.naturalWidth
      const nh = this._cropImgEl.naturalHeight
      const clamp01 = (v) => Math.min(1, Math.max(0, v))
      crop = { x: clamp01(srcX / nw), y: clamp01(srcY / nh),
               w: clamp01(srcW / nw), h: clamp01(srcH / nh) }
      source = this._adjustSource || this._downscaledDataUrl(this._cropImgEl)
    }
    const adjusting = this._adjustMode
    this._closeCropStage()
    this._stashPending(dataUrl, source, crop)
    // The Adjust flow opened the stage directly — the picker's tabs and its
    // Apply button were never on screen — so confirming the crop IS the apply.
    if (adjusting) this.applyImage()
  }

  // "Skip" — today's behaviour, unchanged: the plain MAX_EDGE-capped
  // downscale of the whole original image, no fixed ratio forced on it.
  // No re-crop record either: the stored image IS the whole original, so a
  // later Adjust has everything it needs through the legacy path already.
  //
  // In the Adjust flow this button reads "Cancel" (relabelled at open):
  // the stage is re-editing a picture already on the card, nothing is
  // pending, and the card must leave exactly as it came. Backing out returns
  // to the reposition stage it was reached from — the creator asked to
  // reframe, not to leave the modal.
  cropSkip(event) {
    event?.preventDefault()
    if (!this._cropImgEl) return
    if (this._adjustMode) {
      const backToPos = this._cropFromPos && this._posSlot
      this._closeCropStage()
      if (!backToPos) { this.close(); return }
      this._showPosStage(true)
      this._setModalTitle("reposition")
      return
    }
    const dataUrl = this._downscaledDataUrl(this._cropImgEl)
    this._closeCropStage()
    this._stashPending(dataUrl)
  }

  // The crop stage reopened against a picture that is already on a card:
  // seeded from the kept original (image_source) and the stored rect
  // (image_crop), so the frame can move AND widen — the owner's ask was
  // exactly that you shouldn't have to remove and re-upload to re-frame.
  // On a legacy slot (nothing kept — pre-feature uploads, Skip'd uploads, and
  // every tap-card statement) the current image stands in as the source:
  // reposition and zoom IN are real, zoom OUT has no pixels to reach, and the
  // hint says so. Applying from that state promotes the current image to the
  // kept source, so the NEXT adjust of a card hero has the full record.
  //
  // Reached from the reposition stage's "Crop & zoom", which is where the
  // same-origin check that gates it lives; this is the belt to that brace.
  // The stage stands alone — no tabs, no Library, no modal Apply button — so
  // "Use this crop" applies immediately and "Skip" reads Cancel.
  _beginAdjustCrop(slot) {
    const card = slot?.card
    if (!card) return
    // A card hero can re-crop from its kept original; a tap statement has no
    // such record, so the stored image itself is all there is to draw from.
    const kept   = slot.kind === "card" ? card.dataset.cardImageSource : ""
    const source = kept || slot.url
    if (!this._croppable(source)) return
    const legacy = !kept

    this._activeCard = card
    this._pendingUrl = null
    this._pendingVideo = null
    this._pendingSource = null
    this._pendingCrop = null
    // The picture doesn't change identity when its framing does — keep the
    // credit it already carries rather than wiping it with a stale pending.
    // Only a card hero carries one; a statement image has no credit line.
    this._pendingCredit    = slot.kind === "card" ? (card.dataset.cardImageCredit || "") : ""
    this._pendingCreditUrl = slot.kind === "card" ? (card.dataset.cardImageCreditUrl || "") : ""
    this._setApplyEnabled(false)
    this._adjustMode = true
    this._adjustSource = source

    let rect = null
    if (!legacy && card.dataset.cardImageCrop) {
      try { rect = JSON.parse(card.dataset.cardImageCrop) } catch (_e) { rect = null }
    }

    if (this.hasCropHintTarget) this.cropHintTarget.hidden = legacy
    if (this.hasCropHintLegacyTarget) this.cropHintLegacyTarget.hidden = !legacy
    if (this.hasCropSkipBtnTarget && this.cropSkipBtnTarget.dataset.cancelLabel) {
      this.cropSkipBtnTarget.textContent = this.cropSkipBtnTarget.dataset.cancelLabel
    }

    // Stage up immediately (empty), THEN decode — opening on image load
    // would flash the picker's tabs for however long the decode takes.
    this._showCropStage(true)
    this._setModalTitle("crop")
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)

    const img = new Image()
    img.onload = () => {
      if (!this._adjustMode) return // closed while decoding
      this._cropImgEl = img
      if (this.hasCropImgTarget) this.cropImgTarget.src = source
      const [ rw, rh ] = this.constructor.CROP_RATIO[this._mode] || this.constructor.CROP_RATIO.card
      if (this.hasCropFrameTarget) this.cropFrameTarget.style.aspectRatio = `${rw} / ${rh}`
      requestAnimationFrame(() => {
        this._layoutCrop()
        if (rect) this._seedCrop(rect)
      })
    }
    // The stored source didn't decode — there is nothing to adjust against,
    // and an empty stuck stage would read as broken.
    img.onerror = () => this.close()
    img.src = source
  }

  // Drawing an image onto a canvas taints it unless it is same-origin, and the
  // crop stage's final encode then throws — so a stored path or an inline data
  // URL is croppable and a Pexels CDN URL is not.
  _croppable(url) {
    const v = String(url || "")
    return v.startsWith("/") || v.startsWith("data:")
  }

  // Reproduce a stored crop in the stage: scale so the rect's width fills
  // the frame, offsets so its top-left sits on the frame's origin. Clamped
  // to the slider's own range, so a rect that maths outside it (rounding,
  // a source swapped underneath) lands on the nearest legal state instead
  // of a broken transform. Runs after _layoutCrop, which owns the frame
  // measurements and the min scale this builds on.
  _seedCrop(rect) {
    const w = parseFloat(rect?.w)
    if (!this._cropImgEl || !(w > 0)) return
    const nw = this._cropImgEl.naturalWidth
    const nh = this._cropImgEl.naturalHeight
    const max = this._cropMinScale * this.constructor.CROP_ZOOM_MAX
    this._cropScale = Math.min(max, Math.max(this._cropMinScale, this._cropFrameW / (w * nw)))
    this._cropZoomFactor = this._cropScale / this._cropMinScale
    if (this.hasCropZoomTarget) this.cropZoomTarget.value = String(this._cropZoomFactor)
    this._setCropOffset(
      -(parseFloat(rect?.x) || 0) * nw * this._cropScale,
      -(parseFloat(rect?.y) || 0) * nh * this._cropScale
    )
  }

  _showCropStage(show) {
    if (this.hasCropStageTarget) this.cropStageTarget.hidden = !show
    this._takeOverModal(show)
  }

  // Which of the modal's jobs the head announces. The head is the only chrome
  // that survives a stage taking over the body, so leaving it on "Add media"
  // through a crop or a reposition was the modal claiming to be doing
  // something else. `key` is a data-*-label on the title element; anything
  // unnamed falls back to the default.
  _setModalTitle(key) {
    if (!this.hasModalTitleTarget) return
    const el = this.modalTitleTarget
    const label = el.dataset[`${key}Label`] || el.dataset.defaultLabel
    if (label) el.textContent = label
  }

  // A full-height stage (crop or reposition) takes over the modal's content
  // area — the normal tabs/body/foot (Upload/Library, Cancel/Apply) sit it out.
  _takeOverModal(show) {
    const tabs = this.element.querySelector(".media-modal-tabs")
    const body = this.element.querySelector(".media-modal-body")
    const foot = this.element.querySelector(".media-modal-foot")
    if (tabs) tabs.hidden = show
    if (body) body.hidden = show
    if (foot) foot.hidden = show
  }

  _closeCropStage() {
    this._showCropStage(false)
    this._setModalTitle("default")
    if (this._cropObjectUrl) URL.revokeObjectURL(this._cropObjectUrl)
    this._cropObjectUrl = null
    this._cropImgEl = null
    this._adjustMode = false
    this._adjustSource = null
    // Restore the stage's ordinary copy — the Adjust flow may have swapped
    // the hint (legacy zoom-in-only note) and relabelled Skip as Cancel.
    if (this.hasCropHintTarget) this.cropHintTarget.hidden = false
    if (this.hasCropHintLegacyTarget) this.cropHintLegacyTarget.hidden = true
    if (this.hasCropSkipBtnTarget && this.cropSkipBtnTarget.dataset.skipLabel) {
      this.cropSkipBtnTarget.textContent = this.cropSkipBtnTarget.dataset.skipLabel
    }
    if (this.hasCropImgTarget) {
      this.cropImgTarget.removeAttribute("src")
      this.cropImgTarget.style.transform = ""
    }
  }

  // ── Reposition stage ────────────────────────────────────
  // The non-destructive half of reframing. Nothing is re-encoded: it records
  // only WHERE the media sits inside the frame that crops it (focal_x/focal_y
  // on a card hero, one entry of option_focals on a tap statement), which is
  // the one reframing available to media the crop stage cannot touch — a
  // Pexels photo (cross-origin, so the canvas tainting kills the encode) or a
  // video (no canvas path at all, and "no crop on the videos" by request).
  // That is the whole of "reposition every image and piece of content — at the
  // moment I can only do it with uploads".
  //
  // The frame is sized to the REAL slot the media fills, so a drag here is
  // what the card will show rather than an approximation of it.

  openAdjust(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event?.currentTarget
    const card    = trigger?.closest("[data-survey-editor-target='card']")
                 || trigger?.closest(".survey-card-wrap")
    if (!card) return
    // A chip inside a statement reframes that statement; the panel fab
    // reframes the card's own hero.
    const index = trigger?.closest(".rotate-card") ? this._tapIndexFor(trigger, card) : null
    const slot  = index == null ? this._cardSlot(card) : this._tapOptionSlot(card, index)
    if (!slot) return

    // The crop hand-off runs through the ordinary apply path, which keys off
    // these — set them here so "Crop & zoom" needs no second resolution pass.
    this._mode = slot.kind
    this._optionIndex = slot.index
    this._activeCard = card
    this._pendingUrl = null
    this._pendingVideo = null
    this._pendingSource = null
    this._pendingCrop = null
    this._posSlot = slot
    // Cleared per open, not just per close: the overflow belongs to ONE
    // picture in ONE frame, and a stale pair would let a drag move media the
    // new frame doesn't crop. _measurePos fills them back in once the media
    // reports its natural size.
    this._posOverflowX = 0
    this._posOverflowY = 0
    this._posDragging = false
    this._cropFromPos = false

    // Crop is for stills the browser will let us redraw. A video is never
    // croppable and a cross-origin photo cannot be, so the button is simply
    // absent rather than present-and-failing.
    if (this.hasPosCropBtnTarget) {
      this.posCropBtnTarget.hidden = !(slot.type === "image" && this._croppable(slot.url))
    }
    const isVideo = slot.type === "video"
    if (this.hasPosHintTarget) this.posHintTarget.hidden = isVideo
    if (this.hasPosHintVideoTarget) this.posHintVideoTarget.hidden = !isVideo
    this._showPosStage(true)
    this._setModalTitle("reposition")
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)

    // Match the stage frame to the slot's own shape, so the crop the creator
    // is adjusting is the crop they are looking at on the card. A slot with no
    // measurable box (scrolled out, a card mid-rebuild) falls back to the
    // nominal ratio for its kind.
    const rect = slot.measureEl?.getBoundingClientRect()
    const [ rw, rh ] = (rect && rect.width > 0 && rect.height > 0)
      ? [ rect.width, rect.height ]
      : (this.constructor.CROP_RATIO[slot.kind] || this.constructor.CROP_RATIO.card)
    if (this.hasPosFrameTarget) this.posFrameTarget.style.aspectRatio = `${rw} / ${rh}`

    this._posX = slot.x
    this._posY = slot.y
    this._posZoom = this._clampZoom(slot.z)
    this._posNatW = 0
    this._posNatH = 0
    if (this.hasPosZoomTarget) this.posZoomTarget.value = String(this._posZoom)
    this._renderPosChrome(slot)
    slot.type === "video" ? this._mountPosVideo(slot) : this._mountPosImage(slot)
  }

  // The card's own left-panel media: a video if it has one, otherwise its
  // photo. A Lottie/range panel has neither and never renders the CTA.
  _cardSlot(card) {
    const video = card.dataset.cardVideo || ""
    const image = card.dataset.cardImage || ""
    if (!video && !image) return null
    const type = video ? "video" : "image"
    const el = card.querySelector(type === "video" ? ".split-left-video" : ".split-left-img")
    return {
      kind: "card", index: null, type, card, el, measureEl: el,
      url: video || image,
      x: this._cardFocal(card, "cardFocalX"),
      y: this._cardFocal(card, "cardFocalY"),
      z: this._clampZoom(card.dataset.cardFocalZoom)
    }
  }

  // One tap-card statement's picture. Targets .rotate-card-media (the
  // server-rendered markup) and falls back to the .rotate-card itself, which
  // is where type_panel_controller's client-side rebuild paints instead.
  _tapOptionSlot(card, index) {
    const url = this._parseUrls(card.dataset.cardOptionImages)[index]
    if (!url) return null
    const rotateCard = card.querySelectorAll(".rotate-card")[index]
    const focal = this._optionFocals(card)[index] || {}
    return {
      kind: "tapOption", index, type: "image", card, url,
      el: rotateCard?.querySelector(".rotate-card-media") || rotateCard || null,
      // The stack, not the card: tap-stack gives every .rotate-card a resting
      // transform (translate/scale/rotate), and a rotated box measures wider
      // and shorter than the card actually is. Every card fills the stack
      // (position:absolute; inset:0), which carries no transform of its own.
      measureEl: rotateCard?.closest(".rotate-card-stack") || rotateCard || null,
      // The chrome that will sit ON this picture — the statement band and the
      // response strip — measured off the live card so the stage can show what
      // is about to cover it.
      chromeEl: rotateCard || null,
      x: this._clampPercent(focal.x),
      y: this._clampPercent(focal.y),
      z: this._clampZoom(focal.z)
    }
  }

  _cardFocal(card, key) {
    return this._clampPercent(card?.dataset?.[key])
  }

  // Centre / cover-fit for anything that isn't a number — never 0, which would
  // silently pin the frame to an edge. Shared with every other painter of this
  // model (see lib/option_media), so the editor, the rebuild and the server
  // cannot disagree about what a stored value means.
  _clampPercent(value) { return focalPercent(value) }
  _clampZoom(value)    { return focalZoom(value) }

  _optionFocals(card) {
    try {
      const focals = JSON.parse(card?.dataset?.cardOptionFocals || "[]")
      return Array.isArray(focals) ? focals : []
    } catch (_e) {
      return []
    }
  }

  // Both media types are laid out the same way — cover-fit inside the frame —
  // so the drag maths only needs the natural size, which is read without ever
  // touching a canvas. That is what keeps a cross-origin photo repositionable.
  _mountPosImage(slot) {
    if (this.hasPosVideoTarget) { this.posVideoTarget.hidden = true; this.posVideoTarget.removeAttribute("src") }
    if (!this.hasPosImgTarget) return
    this.posImgTarget.hidden = false
    this.posImgTarget.style.backgroundImage = `url('${String(slot.url).replace(/'/g, "\\'")}')`
    this._paintPos()
    const img = new Image()
    img.onload = () => this._measurePos(img.naturalWidth, img.naturalHeight)
    // A picture that won't load leaves the axes unmeasured, so dragging does
    // nothing rather than flinging the frame around on bogus numbers.
    img.src = slot.url
  }

  _mountPosVideo(slot) {
    if (this.hasPosImgTarget) { this.posImgTarget.hidden = true; this.posImgTarget.style.backgroundImage = "" }
    if (!this.hasPosVideoTarget) return
    const vid = this.posVideoTarget
    vid.hidden = false
    vid.src = slot.url
    this._paintPos()
    vid.onloadedmetadata = () => this._measurePos(vid.videoWidth, vid.videoHeight)
    // A moving preview is the honest one — the framing is being chosen against
    // the clip, not its first frame. Autoplay refusal just leaves it paused.
    vid.play?.()?.catch(() => { /* paused preview is fine */ })
  }

  // Remember the natural size; the overflow itself is derived, because zoom
  // changes it and the slider can move at any time.
  _measurePos(naturalW, naturalH) {
    if (!(naturalW > 0) || !(naturalH > 0)) return
    this._posNatW = naturalW
    this._posNatH = naturalH
    this._recomputeOverflow()
  }

  // How many pixels of the picture are hidden on each axis, relative to the
  // FRAME. Cover fits the picture to a box that is _posZoom times the frame, so
  // the painted size is (zoom × cover-scale × natural) and the overflow is
  // whatever of that the frame doesn't show. Zero on an axis means the picture
  // exactly fits there and a drag has nothing to reveal — which is the whole
  // reason the zoom slider exists.
  _recomputeOverflow() {
    this._posOverflowX = 0
    this._posOverflowY = 0
    if (!this.hasPosFrameTarget || !(this._posNatW > 0) || !(this._posNatH > 0)) return
    const rect = this.posFrameTarget.getBoundingClientRect()
    const fw = rect.width, fh = rect.height
    if (!(fw > 0) || !(fh > 0)) return
    const zoom  = this._clampZoom(this._posZoom)
    const scale = zoom * Math.max(fw / this._posNatW, fh / this._posNatH)
    this._posOverflowX = Math.max(0, this._posNatW * scale - fw)
    this._posOverflowY = Math.max(0, this._posNatH * scale - fh)
  }

  // The stage's preview layer reads the SAME custom properties the card does,
  // so what the creator drags here is rendered by the identical rule rather
  // than by a lookalike.
  _paintPos() {
    applyFocal(this.hasPosImgTarget ? this.posImgTarget : null, this._posX, this._posY, this._posZoom)
    applyFocal(this.hasPosVideoTarget ? this.posVideoTarget : null, this._posX, this._posY, this._posZoom)
  }

  // Zoom slider. Punching in hides more of the picture on both axes, which is
  // what gives an axis that already fits something to slide — so the overflow
  // has to be recomputed before the next drag, not after it.
  posZoomChanged(event) {
    this._posZoom = this._clampZoom(parseFloat(event.target.value))
    this._recomputeOverflow()
    this._paintPos()
  }

  // ── "Where do the options sit?" ─────────────────────────────────────────
  // A tap statement's picture is never seen bare: the statement band covers its
  // top and the response strip (or, at five answers and up, the whole fanned
  // arc) covers its bottom. Framing a face into either of those is the easiest
  // mistake to make here and the only one you cannot see until you play the
  // deck. So the stage draws them.
  //
  // Measured off the LIVE card rather than hard-coded: the strip changes shape
  // with the answer count (see .rotate-card-controls--fan), and a ghost that
  // guessed would be wrong for exactly the cards that need it most.
  _renderPosChrome(slot) {
    if (!this.hasPosChromeTarget) return
    this.posChromeTarget.replaceChildren()
    // Measured against the STACK, which carries no transform of its own —
    // tap-stack gives each card a resting translate/rotate, and a rotated box
    // measures wider and shorter than the card really is.
    const box = slot.chromeEl && slot.measureEl?.getBoundingClientRect()
    if (!box || !(box.width > 0) || !(box.height > 0)) {
      this.posChromeTarget.hidden = true
      return
    }
    // The statement band belongs to the card that was clicked; the answers are
    // a SIBLING of the cards, one level up on the stack — looking for both
    // inside the card found only the band, and the answers are the half a
    // creator is most likely to frame a face into.
    const find = (sel) => slot.chromeEl.querySelector(sel) || slot.measureEl.querySelector(sel)
    const parts = [
      [ this._rectOf(find(".rotate-card-statement")), t("editor.reposition_chrome_statement") ],
      // The pills themselves, not the box that holds them: past four answers
      // the strip becomes a full-card fan wrapper (.rotate-card-controls--fan
      // is top:0), so ghosting the wrapper greyed the entire picture and said
      // nothing about where anything actually lands.
      [ this._unionRect(slot, "[data-tap-response]"), t("editor.reposition_chrome_answers") ]
    ]
    let drew = false
    for (const [ rect, label ] of parts) {
      if (!rect || !(rect.height > 0)) continue
      const ghost = document.createElement("div")
      ghost.className = "media-pos-ghost"
      ghost.style.left   = `${((rect.left - box.left) / box.width) * 100}%`
      ghost.style.top    = `${((rect.top - box.top) / box.height) * 100}%`
      ghost.style.width  = `${(rect.width / box.width) * 100}%`
      ghost.style.height = `${(rect.height / box.height) * 100}%`
      const tag = document.createElement("span")
      tag.className = "media-pos-ghost-label"
      tag.textContent = label
      ghost.appendChild(tag)
      this.posChromeTarget.appendChild(ghost)
      drew = true
    }
    this.posChromeTarget.hidden = !drew
  }

  _rectOf(el) {
    const rect = el?.getBoundingClientRect()
    return rect && rect.height > 0 ? rect : null
  }

  // The smallest box holding every match — what the answer pills between them
  // actually cover, however the current answer count arranges them.
  _unionRect(slot, selector) {
    const els = [
      ...(slot.chromeEl?.querySelectorAll(selector) || []),
      ...(slot.measureEl?.querySelectorAll(selector) || [])
    ]
    let box = null
    for (const el of els) {
      const r = this._rectOf(el)
      if (!r) continue
      box = box ? {
        left:   Math.min(box.left, r.left),
        top:    Math.min(box.top, r.top),
        right:  Math.max(box.right, r.right),
        bottom: Math.max(box.bottom, r.bottom)
      } : { left: r.left, top: r.top, right: r.right, bottom: r.bottom }
    }
    return box && { ...box, width: box.right - box.left, height: box.bottom - box.top }
  }

  posDragStart(event) {
    if (!this._posSlot) return
    event.preventDefault()
    try { this.posFrameTarget.setPointerCapture?.(event.pointerId) } catch (_e) { /* no-op */ }
    this._posDragging = true
    this._posDragStartX = event.clientX
    this._posDragStartY = event.clientY
    this._posOriginX = this._posX
    this._posOriginY = this._posY
  }

  // Dragging RIGHT moves the picture right, revealing more of its left side —
  // which is a SMALLER background-position percentage. Hence the subtraction:
  // the picture follows the pointer, which is the only behaviour that reads as
  // "drag the image", and it matches the mobile-header drag above.
  posDrag(event) {
    if (!this._posDragging) return
    event.preventDefault()
    const overX = this._posOverflowX || 0
    const overY = this._posOverflowY || 0
    if (overX > 0) {
      this._posX = this._clampPercent(this._posOriginX - ((event.clientX - this._posDragStartX) / overX) * 100)
    }
    if (overY > 0) {
      this._posY = this._clampPercent(this._posOriginY - ((event.clientY - this._posDragStartY) / overY) * 100)
    }
    this._paintPos()
  }

  posDragEnd(event) {
    if (!this._posDragging) return
    this._posDragging = false
    try { this.posFrameTarget.releasePointerCapture?.(event.pointerId) } catch (_e) { /* no-op */ }
  }

  // Save: the card only learns about the new framing here, so backing out
  // needs no undo — the stage is the preview, not the card.
  posApply(event) {
    event?.preventDefault()
    const slot = this._posSlot
    if (!slot) return
    if (slot.kind === "tapOption") this._writeOptionFocal(slot.card, slot.index, this._posX, this._posY, this._posZoom)
    else this._writeCardFocal(slot.card, this._posX, this._posY, this._posZoom)
    this._notifyDirty()
    this.close()
  }

  posCancel(event) {
    event?.preventDefault()
    this.close()
  }

  // Hand off to the destructive stage, for the media that can take it. Coming
  // back out of it returns here rather than closing the modal — the creator
  // asked to reframe, not to leave.
  posToCrop(event) {
    event?.preventDefault()
    const slot = this._posSlot
    if (!slot || slot.type !== "image" || !this._croppable(slot.url)) return
    this._cropFromPos = true
    this._showPosStage(false)
    this._beginAdjustCrop(slot)
  }

  _showPosStage(show) {
    if (this.hasPosStageTarget) this.posStageTarget.hidden = !show
    this._takeOverModal(show)
    if (show) return
    // Stop the preview the moment the stage stands down: a <video> left with a
    // src goes on buffering behind a hidden element.
    if (this.hasPosVideoTarget) {
      this.posVideoTarget.pause?.()
      this.posVideoTarget.onloadedmetadata = null
      this.posVideoTarget.removeAttribute("src")
      this.posVideoTarget.load?.()
    }
  }

  _closePosStage() {
    this._showPosStage(false)
    this._setModalTitle("default")
    this._posSlot = null
    this._posDragging = false
    this._posOverflowX = 0
    this._posOverflowY = 0
    this._cropFromPos = false
    if (this.hasPosImgTarget) this.posImgTarget.style.backgroundImage = ""
  }

  // The card hero's focal pair. Written onto the row (what autosave reads) and
  // painted straight onto the live panel, so the two can never disagree.
  _writeCardFocal(card, x, y, z) {
    if (!card) return
    this._setFocalDataset(card, x, y, z)
    this._paintCardFocal(card)
  }

  _setFocalDataset(card, x, y, z) {
    // Centre and cover-fit are the defaults everywhere — stored as nothing, so
    // a reset leaves no attribute for the serialiser or the sanitiser to carry.
    if (this._clampPercent(x) === 50) delete card.dataset.cardFocalX
    else card.dataset.cardFocalX = String(this._clampPercent(x))
    if (this._clampPercent(y) === 50) delete card.dataset.cardFocalY
    else card.dataset.cardFocalY = String(this._clampPercent(y))
    const zoom = this._clampZoom(z)
    if (zoom > 1) card.dataset.cardFocalZoom = String(Number(zoom.toFixed(2)))
    else delete card.dataset.cardFocalZoom
  }

  // Both media elements read the same custom properties (see .split-left-img /
  // .split-left-video), so one painter covers photo and video.
  _paintCardFocal(card) {
    const x = this._cardFocal(card, "cardFocalX")
    const y = this._cardFocal(card, "cardFocalY")
    const z = this._clampZoom(card.dataset.cardFocalZoom)
    card.querySelectorAll(".split-left-img, .split-left-video").forEach(el => applyFocal(el, x, y, z))
  }

  // One statement's focal pair, positional against option_images exactly like
  // the images themselves. A centred slot is stored as null rather than a
  // {50,50} pair, so an untouched deck serialises to nothing.
  _writeOptionFocal(card, index, x, y, z) {
    if (!card || !Number.isInteger(index)) return
    const focals = this._optionFocals(card)
    while (focals.length <= index) focals.push(null)
    const cx = this._clampPercent(x)
    const cy = this._clampPercent(y)
    const cz = Number(this._clampZoom(z).toFixed(2))
    const slot = { x: cx, y: cy }
    if (cz > 1) slot.z = cz
    focals[index] = (cx === 50 && cy === 50 && cz === 1) ? null : slot
    this._storeOptionFocals(card, focals)
    this._paintOptionFocal(card, index, cx, cy, cz)
  }

  _storeOptionFocals(card, focals) {
    while (focals.length && focals[focals.length - 1] == null) focals.pop()
    if (focals.length) card.dataset.cardOptionFocals = JSON.stringify(focals)
    else delete card.dataset.cardOptionFocals
  }

  // The statement's media layer reads the same custom properties every other
  // cover-cropped layer does, so moving it is writing those — the url and the
  // white base underneath it are untouched.
  _paintOptionFocal(card, index, x, y, z) {
    const rotateCard = card.querySelectorAll(".rotate-card")[index]
    if (!rotateCard) return
    applyFocal(rotateCard.querySelector(".rotate-card-media") || rotateCard, x, y, z)
  }

  _readAsDataUrl(file, done = this._stashPending.bind(this)) {
    const reader = new FileReader()
    reader.onload = () => done(reader.result)
    reader.readAsDataURL(file)
  }

  _stashPending(dataUrl, source = null, crop = null) {
    this._pendingUrl = dataUrl
    // Only cropApply passes these; every other stash — Skip's plain
    // downscale, a decode fallback, a brand-library upload — carries no
    // re-crop record and clears whatever an earlier crop left behind.
    this._pendingSource = source
    this._pendingCrop = crop
    this._setApplyEnabled(true)
  }

  _showUploadError(msg) {
    if (!this.hasUploadErrorTarget) return
    this.uploadErrorTarget.textContent = msg
    this.uploadErrorTarget.hidden = false
  }

  _clearUploadError() {
    if (!this.hasUploadErrorTarget) return
    this.uploadErrorTarget.textContent = ""
    this.uploadErrorTarget.hidden = true
  }

  // ── Library tab ────────────────────────────────────────
  pickLibraryItem(event) {
    const item = event.currentTarget
    this.libraryItemTargets.forEach(i => i.setAttribute("aria-selected", "false"))
    item.setAttribute("aria-selected", "true")
    if (item.dataset.video) {
      this._pendingVideo = { video: item.dataset.video, poster: item.dataset.poster || "" }
      this._pendingUrl = null
    } else {
      this._pendingUrl = item.dataset.url
      this._pendingVideo = null
    }
    // A tile pick replaces whatever a crop stashed — including its re-crop
    // record. Left set, a Library pick made AFTER cropping an upload would
    // carry the upload's original and rect onto a picture they belong to
    // not at all.
    this._pendingSource = null
    this._pendingCrop = null
    // Pexels results carry a creator credit; curated/recommended tiles don't
    // (these stay empty so the credit is cleared on apply).
    this._pendingCredit    = item.dataset.credit || ""
    this._pendingCreditUrl = item.dataset.creditUrl || ""
    this._setApplyEnabled(true)
  }

  // ── Pexels search ──────────────────────────────────────
  // Debounced as the editor types; Enter searches immediately. Results are
  // fetched at the ratio of the slot being filled (this._mode → context) and
  // reuse the libraryItem target + pickLibraryItem action, so selecting one
  // behaves exactly like a curated thumbnail.
  searchKeydown(event) {
    if (event.key === "Enter") { event.preventDefault(); this._runSearch() }
  }

  // Photos ↔ Videos toggle. Re-runs the current query against the chosen
  // media type.
  switchMedia(event) {
    this._setMedia(event.currentTarget.dataset.media)
    this._runSearch()
  }

  _setMedia(media) {
    this._searchMedia = media === "videos" ? "videos" : "photos"
    if (this.hasMediaTabTarget) {
      this.mediaTabTargets.forEach(t => {
        const on = t.dataset.media === this._searchMedia
        t.classList.toggle("is-active", on)
        t.setAttribute("aria-selected", on ? "true" : "false")
      })
    }
    if (this.hasSearchInputTarget) {
      this.searchInputTarget.placeholder = this._searchMedia === "videos"
        ? "Search stock videos…" : "Search stock photos…"
    }
  }

  _showMediaToggle(show) {
    if (this.hasMediaToggleTarget) this.mediaToggleTarget.hidden = !show
  }

  // Pre-fill the search with the Verto theme and run it on open, so the picker
  // surfaces on-theme stock photos immediately instead of waiting for the
  // editor to type. The editor can refine the query at any time.
  //
  //
  // Theme only. Shuffle's direction prompt deliberately does NOT join it: a
  // steer belongs to the shuffle it was typed for, and seeding the picker from
  // one would mean a sentence typed minutes ago silently deciding what this
  // search returns.
  _seedSearch() {
    if (!this.hasSearchInputTarget || !this.hasPexsearchUrlValue) return
    if (this.searchInputTarget.value.trim()) return
    const seed = (this.hasThemeValue ? this.themeValue : "").trim()
    if (!seed) return
    this.searchInputTarget.value = seed
    this._runSearch()
  }

  searchPexels() {
    clearTimeout(this._searchTimer)
    this._searchTimer = setTimeout(() => this._runSearch(), 350)
  }

  // The Load more button. Walks to the next page of the SAME query and appends,
  // so what the creator has already scrolled past stays put.
  loadMoreStock(event) {
    event?.preventDefault()
    this._runSearch((this._searchPage || 1) + 1)
  }

  async _runSearch(page = 1) {
    if (!this.hasPexsearchUrlValue || !this.hasSearchGridTarget) return
    const q = (this.hasSearchInputTarget ? this.searchInputTarget.value : "").trim()
    if (!q) { this._clearSearch(); return }

    const context = this._mode === "background" ? "background" : "card"
    const media   = this._searchMedia
    const noun    = media === "videos" ? "videos" : "photos"
    const append  = page > 1
    this._showSearchStatus(append ? "" : "Searching…")
    this._showLoadMore(false)
    // Page 1 is a NEW search and replaces the grid; later pages extend it.
    if (!append) this.searchGridTarget.replaceChildren()

    const token = (this._searchToken = (this._searchToken || 0) + 1)
    try {
      const url = `${this.pexsearchUrlValue}?q=${encodeURIComponent(q)}&context=${context}&media=${media}&page=${page}`
      const resp = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await resp.json()
      if (token !== this._searchToken) return // a newer search superseded this one
      this._searchPage = Number(data.page) || page

      const items = Array.isArray(data.images) ? data.images : []
      // Our OWN rate limiter, not a Pexels problem. This used to fall through
      // to the generic branch below and report "Couldn't reach the stock
      // service", which is how a creator spent a morning believing the stock
      // server was down. Show the server's own message instead.
      if (resp.status === 429 || data.code === "rate_limited") {
        this._showSearchStatus(data.error || "You've searched a lot recently — give it a few minutes.")
        return
      }
      if (data.error === "search_unavailable") {
        this._showSearchStatus("Stock search isn’t configured.")
        return
      }
      if (data.error === "search_blocked") {
        this._showSearchStatus("Try different words — that search isn’t age-appropriate for this Verto.")
        return
      }
      if (!items.length) {
        // On a later page an empty result just means the well ran dry; only say
        // so from page 1, where it's the answer to what the creator asked.
        if (append) { this._showLoadMore(false); return }
        this._showSearchStatus(data.error ? "Couldn’t reach the stock service." : `No ${noun} found.`)
        return
      }
      this._showSearchStatus("")
      const frag = document.createDocumentFragment()
      for (const item of items) {
        const tile = this._stockTile(item)
        if (tile) frag.appendChild(tile)
      }
      this.searchGridTarget.appendChild(frag)
      this._showLoadMore(data.more !== false)
    } catch (_e) {
      if (token === this._searchToken) this._showSearchStatus("Couldn’t reach the stock service.")
    }
  }

  // One stock result tile. Returns null for a result with nothing to show.
  _stockTile(item) {
    const isVideo = item && item.type === "video"
    if (!item || (!item.url && !item.video)) return null
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = isVideo ? "media-library-item is-video" : "media-library-item"
    const verb = isVideo ? "Video" : "Photo"
    btn.title = item.photographer ? `${verb} by ${item.photographer}` : (item.alt || "")
    const thumb = item.thumb || item.poster || item.url
    if (thumb) btn.style.backgroundImage = `url('${String(thumb).replace(/'/g, "\\'")}')`
    if (isVideo) {
      btn.dataset.video = item.video
      if (item.poster) btn.dataset.poster = item.poster
      // Preview on hover. The playable mp4 already rides on the tile for the
      // apply path, so this costs no extra request until someone points at it.
      btn.addEventListener("mouseenter", () => this._previewVideo(btn))
      btn.addEventListener("mouseleave", () => this._stopPreview(btn))
      btn.addEventListener("focus", () => this._previewVideo(btn))
      btn.addEventListener("blur", () => this._stopPreview(btn))
    } else {
      btn.dataset.url = item.url
    }
    if (item.photographer) btn.dataset.credit = item.photographer
    if (item.photographer_url) btn.dataset.creditUrl = item.photographer_url
    btn.dataset.mediaPickerTarget = "libraryItem"
    btn.dataset.action = "click->media-picker#pickLibraryItem"
    btn.setAttribute("aria-selected", "false")
    return btn
  }

  // Muted, looping, inline — a thumbnail that moves, not a player. Held back
  // behind a short dwell so sweeping the pointer across the grid doesn't kick
  // off a dozen downloads, and skipped entirely when the viewer has asked for
  // reduced motion or the device can't hover (a touch "hover" is a tap, which
  // is the apply gesture).
  _previewVideo(btn) {
    if (!btn.dataset.video || btn.querySelector("video")) return
    if (window.matchMedia("(prefers-reduced-motion: reduce), (hover: none)").matches) return
    clearTimeout(btn._previewTimer)
    btn._previewTimer = setTimeout(() => {
      if (btn.querySelector("video")) return
      const vid = document.createElement("video")
      vid.className = "media-library-preview"
      vid.src = btn.dataset.video
      vid.muted = true
      vid.loop = true
      vid.playsInline = true
      vid.preload = "metadata"
      if (btn.dataset.poster) vid.poster = btn.dataset.poster
      btn.appendChild(vid)
      vid.play().catch(() => { /* autoplay refused — the poster still shows */ })
    }, 180)
  }

  _stopPreview(btn) {
    clearTimeout(btn._previewTimer)
    const vid = btn.querySelector("video")
    if (!vid) return
    vid.pause()
    vid.remove()
  }

  _showLoadMore(show) {
    if (!this.hasLoadMoreTarget) return
    this.loadMoreTarget.hidden = !show
  }

  _showSearchStatus(text) {
    // Un-hiding the stock section inserts a grid ABOVE everything already laid
    // out, so the view has to be pulled back to the top with it.
    const wasHidden = this.hasSearchSectionTarget && this.searchSectionTarget.hidden
    if (this.hasSearchSectionTarget) this.searchSectionTarget.hidden = false
    if (wasHidden) this._resetModalScroll()
    if (this.hasSearchStatusTarget) this.searchStatusTarget.textContent = text || ""
  }

  _clearSearch() {
    clearTimeout(this._searchTimer)
    this._searchToken = (this._searchToken || 0) + 1 // invalidate in-flight results
    this._searchPage = 1
    this._showLoadMore(false)
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ""
    if (this.hasSearchGridTarget) this.searchGridTarget.replaceChildren()
    if (this.hasSearchStatusTarget) this.searchStatusTarget.textContent = ""
    if (this.hasSearchSectionTarget) this.searchSectionTarget.hidden = true
  }

  // ── Apply / clear ──────────────────────────────────────
  async applyImage() {
    if (!this._pendingUrl && !this._pendingVideo) return

    // Uploaded images (data URLs) can't be word-filtered like Pexels picks, so
    // they get a PG / age-appropriateness check before they're ever applied.
    if (this._pendingUrl && this._pendingUrl.startsWith("data:")) {
      const ok = await this._moderateUpload(this._pendingUrl)
      if (!ok) return // reason already shown on the upload pane

      // Admin opt-in: also file this (already-moderated) upload in the org's
      // brand library. Best-effort — a library failure never blocks the apply.
      if (this.hasSaveToLibraryTarget && this.saveToLibraryTarget.checked) {
        this._saveToLibrary(this._pendingUrl)
      }

      // Store the bytes once and carry a short path on the card instead of the
      // base64. Inline data-URLs were the memory driver behind the 502s.
      this._pendingUrl = await this._persistUpload(this._pendingUrl)
      // Still a data URL means storage failed and the picture is about to ride
      // inline. Small ones may (the server still accepts them); one over the
      // sanitiser's cap would be applied here, then silently nil'd on the very
      // next autosave — so stop now, with a reason, instead of a warning later.
      if (this._pendingUrl.startsWith("data:") && this._pendingUrl.length > this.constructor.INLINE_DATA_URL_CAP) {
        this._showUploadError("We couldn't store that image — please try again, or use a smaller file (under about 2 MB).")
        return
      }
    }

    if (this._mode === "background") {
      // Backgrounds are photos only (the video toggle is hidden here).
      if (this._pendingUrl) { this._setVertoBackground(this._pendingUrl); this.close() }
      return
    }
    if (this._mode === "consent") {
      // Consent gate is photos only (the video toggle is hidden here).
      if (this._pendingUrl) {
        this.dispatch("consentImage", { detail: {
          url: this._pendingUrl,
          credit: this._pendingCredit || "",
          creditUrl: this._pendingCreditUrl || ""
        } })
        this.close()
      }
      return
    }
    if (this._mode === "comms") {
      // Email image blocks are photos only (the video toggle is hidden here).
      if (this._pendingUrl) {
        this.dispatch("commsImage", { detail: {
          url: this._pendingUrl,
          credit: this._pendingCredit || "",
          creditUrl: this._pendingCreditUrl || ""
        } })
        this.close()
      }
      return
    }
    if (!this._activeCard) return
    if (this._mode === "animBg") {
      // Behind the animation (or the answers), not instead of anything — the
      // card's own lottie/range/photo media is untouched: the slot's writer
      // never reads or writes card.image.
      if (this._pendingUrl) {
        const card = this._activeCard
        const slot = this._bgSlot
        // The picture's own ink is unknown until it decodes, and the previous
        // backdrop's answer is about a different picture — so it goes, rather
        // than colouring this one until the measurement lands.
        this._writeBg(slot, { ...this._readBg(slot), image: this._pendingUrl, ink: null }, card)
        this._measureBackdropInk(slot, card, this._pendingUrl)
      }
      this.close()
      return
    }
    if (this._mode === "tapOption") {
      // Tap-card statements are photos only (the video toggle stays hidden
      // for this mode), so there's nothing to check for _pendingVideo here.
      if (this._pendingUrl) this._setTapOptionImage(this._activeCard, this._optionIndex, this._pendingUrl)
      this._notifyDirty()
      this.close()
      return
    }
    if (this._pendingVideo) {
      this._setCardVideo(this._activeCard, this._pendingVideo.video, this._pendingVideo.poster,
        this._pendingCredit, this._pendingCreditUrl)
    } else {
      // The crop stage's re-crop record: persist the uncropped original too,
      // so "Adjust crop" can zoom back OUT of this crop later (an Adjust
      // re-crop arrives holding the already-stored path — nothing to do).
      // Its moderation is QUIET: the crop that actually ships was checked
      // above; a source that fails is simply not kept, and the card degrades
      // to the legacy remove-and-reupload behaviour instead of blocking an
      // apply whose visible image already passed.
      let source = this._pendingSource
      if (source && source.startsWith("data:")) {
        if (await this._moderateUpload(source, { quiet: true })) {
          source = await this._persistUpload(source)
        } else {
          source = null
        }
      }
      const crop = source ? this._pendingCrop : null
      this._setCardImage(this._activeCard, this._pendingUrl, this._pendingCredit, this._pendingCreditUrl,
        { source, crop })
    }
    this._notifyDirty()
    this.close()
  }

  // Hand the moderated upload to the server, which stores it and returns a
  // short same-origin path to put on the card. Returns that path, or the
  // original data URL if anything goes wrong — the server still accepts inline
  // base64, so a storage hiccup degrades to the old behaviour rather than
  // blocking a creator mid-edit.
  async _persistUpload(dataUrl) {
    if (!this.hasCardImageUrlValue) return dataUrl
    try {
      const res = await fetch(this.cardImageUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      return data.ok && data.url ? data.url : dataUrl
    } catch (_) {
      return dataUrl
    }
  }

  // POST the uploaded image for a content-safety verdict. Returns true to
  // allow. Fails safe: with no endpoint wired we don't block; a call that
  // errors or comes back unsafe blocks the upload with a message.
  //
  // `quiet` is for checks whose failure only degrades a feature rather than
  // blocking the visible apply (the re-crop source): no error banner, no
  // Apply-button churn — just the verdict.
  async _moderateUpload(dataUrl, { quiet = false } = {}) {
    if (!this.hasModerateUrlValue) return true
    if (!quiet) {
      this._clearUploadError()
      this._setApplyEnabled(false)
    }
    try {
      const res = await fetch(this.moderateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      if (data.ok) return true
      if (quiet) return false
      this._showUploadError(data.reason || "That image can’t be used — it isn’t PG or age-appropriate for this Verto.")
      return false
    } catch (_) {
      if (!quiet) this._showUploadError("We couldn’t check that image — please try again.")
      return false
    } finally {
      if (!quiet) this._setApplyEnabled(true)
    }
  }

  // ── Brand library ──────────────────────────────────────
  chooseLibraryFile(event) {
    event.preventDefault()
    if (this.hasLibraryFileInputTarget) this.libraryFileInputTarget.click()
  }

  // Upload straight into the org's brand library from the picker (admin
  // only — the tile and input only render for admins). Same downscale +
  // moderation pipeline as a card upload; nothing is applied to the card.
  libraryFileChosen(event) {
    const file = event.target.files?.[0]
    event.target.value = ""
    if (!file) return
    if (file.size > this.constructor.SOURCE_BYTE_CAP) {
      this._brandStatus(t("editor.library_save_failed"))
      return
    }
    const done = async (dataUrl) => {
      this._brandStatus(t("editor.library_saving"))
      const ok = await this._moderateLibraryUpload(dataUrl)
      if (!ok) return
      await this._saveToLibrary(dataUrl)
    }
    // Same reasoning as _readFile: a canvas re-encode captures only one frame
    // of a GIF, silently freezing it. Store the brand-library asset untouched.
    if (file.type === "image/svg+xml" || file.type === "image/gif") this._readAsDataUrl(file, done)
    else this._downscale(file, done)
  }

  // Moderation twin of _moderateUpload with feedback on the library section
  // (the upload pane's error area lives on the other tab).
  async _moderateLibraryUpload(dataUrl) {
    if (!this.hasModerateUrlValue) return true
    try {
      const res = await fetch(this.moderateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      if (data.ok) return true
      this._brandStatus(data.reason || t("editor.library_save_failed"))
      return false
    } catch (_) {
      this._brandStatus(t("editor.library_save_failed"))
      return false
    }
  }

  // POST an (already-moderated) data URL to the org brand library and surface
  // the new tile immediately. Best-effort by design: callers never block a
  // card apply on this.
  async _saveToLibrary(dataUrl) {
    if (!this.hasLibraryUrlValue || !this.libraryUrlValue) return
    try {
      const res = await fetch(this.libraryUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ image: dataUrl })
      })
      const data = await res.json().catch(() => ({}))
      if (!data.ok) {
        this._brandStatus(data.error || t("editor.library_save_failed"))
        return
      }
      this._brandStatus("")
      this._prependBrandTile(data)
    } catch (_) {
      this._brandStatus(t("editor.library_save_failed"))
    }
  }

  // Builds the same shape the server renders (see _media_modal.html.erb): a
  // positioned cell wrapping the tile and its remove ×. The tile is a
  // <button>, so the × can't be nested inside it.
  //
  // `id` and `deleteUrl` come off the create response and used to be dropped
  // on the floor here — which made a tile you had just uploaded the one tile
  // you could not remove without leaving the editor and reloading it.
  _prependBrandTile({ url, thumb, id, delete_url: deleteUrl }) {
    if (!this.hasBrandGridTarget || !url) return
    const cell = document.createElement("div")
    cell.className = "media-library-cell"

    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "media-library-item"
    btn.style.backgroundImage = `url('${thumb || url}')`
    btn.dataset.url = url
    if (id) btn.dataset.assetId = String(id)
    btn.dataset.mediaPickerTarget = "libraryItem"
    btn.dataset.action = "click->media-picker#pickLibraryItem"
    btn.setAttribute("aria-selected", "false")
    cell.appendChild(btn)

    // Only ever reachable by an admin: this path runs off the add-to-library
    // tile, which is itself admin-only, and the endpoint gates again server
    // side. Absent deleteUrl, the tile is simply not removable until reload.
    if (deleteUrl) cell.appendChild(this._brandDeleteButton(deleteUrl))

    const addTile = this.brandGridTarget.querySelector(".media-library-add")
    addTile ? addTile.after(cell) : this.brandGridTarget.prepend(cell)
  }

  _brandDeleteButton(deleteUrl) {
    const del = document.createElement("button")
    del.type = "button"
    del.className = "media-library-del"
    del.title = t("editor.remove_from_library")
    del.setAttribute("aria-label", del.title)
    del.dataset.deleteUrl = deleteUrl
    del.dataset.action = "click->media-picker#deleteBrandAsset"
    del.textContent = "\u00D7"
    return del
  }

  // Remove a brand asset from inside the picker. The affordance already
  // existed on Settings → Brand; the grid a creator is actually looking at
  // when they decide an image was a mistake is this one.
  //
  // The endpoint answers JSON here rather than redirecting, because this runs
  // inside a modal over an editor that may hold unsaved cards — a redirect
  // would navigate them away to make a thumbnail disappear.
  async deleteBrandAsset(event) {
    // The × sits ON the tile, and the tile is a picker button. Without this
    // the removal would also select the image it is removing.
    event.preventDefault()
    event.stopPropagation()

    const del  = event.currentTarget
    const cell = del.closest(".media-library-cell")
    const url  = del.dataset.deleteUrl
    if (!url || del.disabled) return
    if (!window.confirm(t("editor.library_remove_confirm"))) return

    del.disabled = true
    try {
      const res = await fetch(url, {
        method: "DELETE",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        }
      })
      const data = await res.json().catch(() => ({}))
      if (!data.ok) {
        del.disabled = false
        this._brandStatus(data.error || t("editor.library_remove_failed"))
        return
      }
      this._brandStatus("")
      this._forgetPickIfRemoved(cell)
      cell?.remove()
    } catch (_) {
      del.disabled = false
      this._brandStatus(t("editor.library_remove_failed"))
    }
  }

  // Apply is armed by a pending URL, not by what is on screen. Delete the tile
  // that armed it and Apply would still be lit, pointing at a blob that has
  // just been purged — the card would take a 404 for an image.
  _forgetPickIfRemoved(cell) {
    const tile = cell?.querySelector(".media-library-item")
    if (!tile || this._pendingUrl !== tile.dataset.url) return
    this._pendingUrl       = null
    this._pendingCredit    = ""
    this._pendingCreditUrl = ""
    this._setApplyEnabled(false)
  }

  _brandStatus(message) {
    if (this.hasBrandStatusTarget) this.brandStatusTarget.textContent = message
  }

  clearImage() {
    if (this._mode === "background") {
      this._setVertoBackground("")
      this.close()
      return
    }
    if (this._mode === "consent") {
      this.dispatch("consentImage", { detail: { url: "", credit: "", creditUrl: "" } })
      this.close()
      return
    }
    if (!this._activeCard) return
    if (this._mode === "tapOption") {
      this._setTapOptionImage(this._activeCard, this._optionIndex, "")
      this._notifyDirty()
      this.close()
      return
    }
    this._setCardImage(this._activeCard, "")
    this._notifyDirty()
    this.close()
  }

  // Panel "Remove" button — clears the Verto backdrop without opening the modal.
  removeBackground(event) {
    event?.preventDefault()
    this._setVertoBackground("")
  }

  _currentBg() {
    if (!this.hasBgThumbTarget) return ""
    const bg = this.bgThumbTarget.style.backgroundImage
    return bg && bg !== "none" ? bg : ""
  }

  _setVertoBackground(url) {
    // Thumbnail + Remove button in the panel
    if (this.hasBgThumbTarget) {
      this.bgThumbTarget.style.backgroundImage = url ? `url('${url.replace(/'/g, "\\'")}')` : ""
    }
    if (this.hasBgRemoveBtnTarget) this.bgRemoveBtnTarget.hidden = !url

    // Live-apply to every canvas wrapper (editor feed + preview overlay)
    const value = url
      ? `linear-gradient(rgba(0,0,0,0.45), rgba(0,0,0,0.12) 28%, rgba(0,0,0,0.12) 72%, rgba(0,0,0,0.45)), url("${url.replace(/"/g, "")}")`
      : ""
    document.querySelectorAll('[data-brand-palette-target="preview"]').forEach((el) => {
      if (value) el.style.setProperty("--brand-bg-image", value)
      else el.style.removeProperty("--brand-bg-image")
    })

    this._saveBackground(url)
  }

  async _saveBackground(url) {
    if (!this.hasUrlValue) return
    try {
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ background_image: url || null }),
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
    } catch (_e) {
      // The editor stays usable, but tell the user the backdrop didn't stick so
      // they don't publish thinking it saved (a source of draft/preview drift).
      this._flashEditor("Couldn't save the background — please try again.")
    }
  }

  // Reuse the survey-editor controller's status flash (it shares this root
  // element) so background-save failures surface like other save errors.
  _flashEditor(msg) {
    const editor = this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
    if (editor && typeof editor.flash === "function") editor.flash(msg, "text-hot-pink")
  }

  // Sets (or clears) ONE tap-card statement's image — mirrors _setCardImage
  // but writes into the option_images array at `index` and repaints only
  // that one card slot, not the whole card. Targets .rotate-card-media when
  // present (the server-rendered markup); falls back to the .rotate-card
  // itself for type_panel_controller.js's client-side preview, which paints
  // its background directly on that element instead.
  _setTapOptionImage(card, index, url) {
    const images = this._parseUrls(card.dataset.cardOptionImages)
    while (images.length <= index) images.push("")
    images[index] = url || ""
    card.dataset.cardOptionImages = JSON.stringify(images)

    // A different picture in the slot — or none — has nothing to do with where
    // the old one was framed, so that statement's stored position goes with it.
    const focals = this._optionFocals(card)
    if (index < focals.length) {
      focals[index] = null
      this._storeOptionFocals(card, focals)
    }
    this._syncTapAdjustBtn(card, index)

    const rotateCard = card.querySelectorAll(".rotate-card")[index]
    if (!rotateCard) return
    const target = rotateCard.querySelector(".rotate-card-media") || rotateCard
    // The one string every painter of this layer shares (see lib/option_media).
    // cssText, not `background`: it has to clear the previous picture's focal
    // properties as well as its url, and the new slot is centred at cover-fit.
    target.style.cssText = optionMediaStyle(url, null, index)
  }

  _setCardImage(card, url, credit = "", creditUrl = "", media = {}) {
    // A different picture has a different subject, so an old focal point is
    // meaningless against it — back to centre on both axes. A re-crop lands
    // here too, and its framing is baked into the new pixels.
    if (card) {
      delete card.dataset.cardFocalX
      delete card.dataset.cardFocalY
      delete card.dataset.cardFocalZoom
    }
    // "Animate asset" is a preference, not tied to one specific photo, so it
    // survives swapping to a different picture — cleared only when the card
    // ends up with no picture at all.
    if (card && !url) delete card.dataset.cardAnimateAsset

    card.dataset.cardImage = url || ""
    // The re-crop record rides with the picture it belongs to: stamped when
    // this apply carries one (a cropped upload, an Adjust re-crop), cleared
    // by any other change — a different photo has a different original, and
    // no record means the legacy remove-and-reupload behaviour.
    if (url && media.source) {
      card.dataset.cardImageSource = media.source
      if (media.crop) card.dataset.cardImageCrop = JSON.stringify(media.crop)
      else delete card.dataset.cardImageCrop
    } else {
      delete card.dataset.cardImageSource
      delete card.dataset.cardImageCrop
    }
    this._syncAdjustFab(card)
    card.dataset.cardImageCredit = url ? (credit || "") : ""
    card.dataset.cardImageCreditUrl = url ? (creditUrl || "") : ""
    // Picking/clearing a photo replaces any auto-populated video or pasted
    // animation on this card.
    card.dataset.cardVideo = ""
    card.dataset.cardVideoPoster = ""
    card.dataset.cardLottie = ""
    this._syncAnimateAssetClass(card)
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    left.querySelector(".card-lottie[data-card-media]")?.remove()
    let imgEl = left.querySelector(".split-left-img[data-card-media]")
    let ovEl  = left.querySelector(".split-left-overlay[data-card-media]")
    if (url) {
      if (!imgEl) {
        imgEl = document.createElement("div")
        imgEl.className = "split-left-img"
        imgEl.dataset.cardMedia = "true"
        left.prepend(imgEl)
      }
      imgEl.style.backgroundImage = `url('${url.replace(/'/g, "\\'")}')`
      // Back to centre on the element too — the dataset was cleared above, and
      // a stale --focal-* left inline would frame the new picture by the old
      // one's rules until the next server render.
      this._paintCardFocal(card)
      if (!ovEl) {
        ovEl = document.createElement("div")
        ovEl.className = "split-left-overlay"
        ovEl.dataset.cardMedia = "true"
        imgEl.after(ovEl)
      }
      this._renderCardCredit(left, ovEl, credit, creditUrl)
    } else {
      imgEl?.remove()
      ovEl?.remove()
      left.querySelector(".split-left-credit[data-card-media]")?.remove()
    }
  }

  // The "Reposition" fab is server-rendered on media-capable cards and shown
  // whenever the card actually carries media. No origin test any more: the
  // stage it opens repositions rather than re-encodes, so a Pexels photo and a
  // video are as adjustable as an upload — the same-origin rule now gates only
  // the "Crop & zoom" button inside it. Kept in sync here so just-applied
  // media gets its fab without waiting for the next server render.
  _syncAdjustFab(card) {
    const hasMedia = !!(card?.dataset.cardImage || card?.dataset.cardVideo)
    const fab = card?.querySelector(".media-adjust-fab")
    if (fab) fab.hidden = !hasMedia
    // …and its opposite number on the no-media panel. "Header background" is
    // offered exactly where it does something (see
    // ApplicationHelper#card_takes_backdrop? for the one statement of that
    // rule): on a bare card the backdrop IS the design, and the moment a photo
    // lands it is a control that changes nothing a respondent will ever see.
    // Only the CTA that ships on the bare panel — range and Lottie cards have
    // their own, and theirs stays whatever happens to the card's image,
    // because an animation keeps its transparency. And never on the three
    // full-screen types, which the phone draws no header at all.
    // The MOBILE background's pill (.card-bg-fab) is deliberately not touched
    // here: what sits below the header does not stop existing because a
    // picture arrived in it.
    const bg = card?.querySelector(".bare-bg-fab")
    if (bg) bg.hidden = hasMedia || isFullScreenAnswer(card?.dataset.cardType)
  }

  // The same rule for one tap statement's chip: it exists only where there is
  // a picture to move (a statement with no image renders a gradient).
  _syncTapAdjustBtn(card, index) {
    const rotateCard = card?.querySelectorAll(".rotate-card")?.[index]
    const btn = rotateCard?.querySelector(".tap-card-adjust-btn")
    if (!btn) return
    btn.hidden = !this._parseUrls(card.dataset.cardOptionImages)[index]
  }

  // Swap a card's left panel to an autoplaying video, mirroring the server
  // render (the autoplay-video controller handles play/pause + lazy loading).
  _setCardVideo(card, video, poster, credit = "", creditUrl = "") {
    card.dataset.cardVideo = video || ""
    card.dataset.cardVideoPoster = poster || ""
    card.dataset.cardImage = ""
    // Different footage, different subject — the focal pair goes back to
    // centre exactly as it does for a swapped photo. The new <video> below is
    // built without inline properties, so it starts centred either way; this
    // keeps the row saying the same thing.
    delete card.dataset.cardFocalX
    delete card.dataset.cardFocalY
    delete card.dataset.cardFocalZoom
    // No photo, no re-crop record — see _setCardImage.
    delete card.dataset.cardImageSource
    delete card.dataset.cardImageCrop
    this._syncAdjustFab(card)
    card.dataset.cardImageCredit = video ? (credit || "") : ""
    card.dataset.cardImageCreditUrl = video ? (creditUrl || "") : ""
    card.dataset.cardLottie = ""
    // The breathe toggle only applies to a photo or a Lottie — irrelevant
    // once the panel is a video, whose own motion is enough.
    delete card.dataset.cardAnimateAsset
    this._syncAnimateAssetClass(card)
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-img[data-card-media]")?.remove()
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    left.querySelector(".card-lottie[data-card-media]")?.remove()
    if (!video) {
      left.querySelector(".split-left-overlay[data-card-media]")?.remove()
      left.querySelector(".split-left-credit[data-card-media]")?.remove()
      return
    }
    const vid = document.createElement("video")
    vid.className = "split-left-video"
    vid.dataset.cardMedia = "true"
    vid.muted = true; vid.loop = true; vid.autoplay = true
    vid.setAttribute("playsinline", "")
    vid.preload = "none"
    if (poster) vid.poster = poster
    vid.dataset.controller = "autoplay-video"
    const source = document.createElement("source")
    source.src = video
    source.type = "video/mp4"
    vid.appendChild(source)
    left.prepend(vid)

    let ovEl = left.querySelector(".split-left-overlay[data-card-media]")
    if (!ovEl) {
      ovEl = document.createElement("div")
      ovEl.className = "split-left-overlay"
      ovEl.dataset.cardMedia = "true"
      vid.after(ovEl)
    }
    this._renderCardCredit(left, ovEl, credit, creditUrl, "Video")
  }

  // ── Lottie (pasted LottieFiles URL) ────────────────────────────────────
  // The URL never lands on the card: the server fetches, scrubs and stores
  // the animation JSON (CardLottieStore) and hands back a same-origin path —
  // the only form the cards sanitiser accepts for `lottie`.

  _showLottieSection(show) {
    if (this.hasLottieSectionTarget) this.lottieSectionTarget.hidden = !show
    if (show && this.hasLottieErrorTarget) this.lottieErrorTarget.hidden = true
  }

  // ── Mobile header position ────────────────────────────────────────────
  // The card image is stored whole; this records only WHICH horizontal stripe
  // of it the mobile header shows, as a background-position percentage. Nothing
  // is re-cropped, so it stays adjustable and every other surface still gets
  // the full picture.

  get _focalY() {
    const y = parseInt(this._activeCard?.dataset.cardFocalY, 10)
    return Number.isFinite(y) ? Math.min(100, Math.max(0, y)) : 50
  }

  _syncFocal() {
    const card  = this._activeCard
    const image = card?.dataset.cardImage
    const show  = this._mode === "card" && !!image
    if (this.hasFocalSectionTarget) this.focalSectionTarget.hidden = !show
    if (!show || !this.hasFocalImgTarget) return
    this.focalImgTarget.style.backgroundImage = `url('${String(image).replace(/'/g, "\\'")}')`
    this._paintFocal(this._focalY)
  }

  _paintFocal(y) {
    if (this.hasFocalImgTarget) this.focalImgTarget.style.backgroundPosition = `50% ${y}%`
  }

  // Dragging DOWN reveals more of the top of the picture, so the stored
  // percentage goes down with it — the image follows the pointer, which is what
  // "drag the image up and down" means. The frame's height is the full range.
  focalStart(event) {
    if (!this.hasFocalFrameTarget) return
    event.preventDefault()
    const frame  = this.focalFrameTarget
    const height = Math.max(frame.getBoundingClientRect().height, 1)
    const from   = this._focalY
    const startY = event.clientY
    frame.setPointerCapture?.(event.pointerId)

    const move = (e) => {
      const delta = ((e.clientY - startY) / height) * 100
      const next  = Math.round(Math.min(100, Math.max(0, from - delta)))
      this._paintFocal(next)
      this._writeFocal(next)
    }
    const stop = () => {
      frame.removeEventListener("pointermove", move)
      frame.removeEventListener("pointerup", stop)
      frame.removeEventListener("pointercancel", stop)
    }
    frame.addEventListener("pointermove", move)
    frame.addEventListener("pointerup", stop)
    frame.addEventListener("pointercancel", stop)
  }

  // Shares the reposition stage's writer, so the two controls that can move a
  // card's photo vertically leave the row in exactly the same state — this one
  // simply holds the horizontal axis where it already was.
  _writeFocal(y) {
    const card = this._activeCard
    if (!card) return
    this._setFocalDataset(card, this._cardFocal(card, "cardFocalX"), y)
    // Repaint the card's own hero at once — the custom properties are what the
    // mobile and device frames crop against.
    this._paintCardFocal(card)
    this._notifyDirty()
  }

  // ── Animation backdrop ────────────────────────────────────────────────
  // A per-card colour/image behind a Lottie or a range card's reaction set,
  // overriding the Verto-wide --brand-panel. Stored as card.media_bg and read
  // back off the card row by the editor serialiser.

  // Client-side twin of ApplicationHelper#card_takes_backdrop? and the
  // media_bg branch of Survey.sanitize_cards_images!. Anything but an opaque
  // medium: an animation has transparency to see through, and a card with no
  // media is nothing BUT its backdrop — which is the case that had no control
  // at all until a creator asked to design the phone view of an ordinary card.
  // Behind a photo or a video there is nothing to see, so nothing is offered.
  // And never on the three full-screen types: the phone draws them no header
  // at all, so there is nothing for a header backdrop to be behind — their
  // phone design is the mobile background, which every type takes.
  get _cardTakesBackground() {
    const card = this._activeCard
    if (!card) return false
    if (isFullScreenAnswer(card.dataset.cardType)) return false
    if (card.dataset.cardType === "range" || card.dataset.cardLottie) return true
    return !card.dataset.cardImage && !card.dataset.cardVideo
  }

  // ── The two backdrop slots ────────────────────────────────────────────
  // A card carries two backdrops and they are different things:
  //   panel  — the HEADER backdrop, card.media_bg: behind the left panel's
  //            animation, or the panel itself on a card with no media. Painted
  //            as a real background on .split-left, on every screen.
  //   mobile — the MOBILE BACKGROUND, card.mobile_bg: behind the question and
  //            answers on a phone. Handed to .split-right as --mobile-bg-*
  //            custom properties, which only the two phone blocks in
  //            application.css read — the same split ApplicationHelper
  //            #card_mobile_bg_style makes server-side, and the reason the
  //            desktop panel beside the creator does not change when they
  //            design the phone.
  // Each slot names its own dataset key, its own element and its own class,
  // and the one writer below is parameterised by the slot rather than by the
  // card's type. That is what makes "changing one must never change the
  // other" true by construction: nothing in here can reach the other slot's
  // field, and nothing reads card.image at all.
  static BG_SLOTS = {
    panel:  { key: "cardMediaBg",  target: ".split-left",  klass: "has-media-bg",  inked: false },
    mobile: { key: "cardMobileBg", target: ".split-right", klass: "has-mobile-bg", inked: true }
  }

  // All take the card explicitly (defaulting to the modal's own) so the
  // editor's dropped-media cleanup can clear a backdrop off a card the picker
  // was never opened on — see survey-editor#_clearDroppedMedia.
  _readBg(slot, card = this._activeCard) {
    const key = this.constructor.BG_SLOTS[slot].key
    try { return JSON.parse(card?.dataset[key] || "{}") || {} }
    catch (_) { return {} }
  }

  _readAnimBg(card = this._activeCard)   { return this._readBg("panel", card) }
  _readMobileBg(card = this._activeCard) { return this._readBg("mobile", card) }

  // One writer for the card row's dataset, the live style and the dirty flag,
  // so the preview and what autosave will send can never disagree.
  // `notify: false` for the editor's dropped-media cleanup, which repaints a
  // card the server has already refused and must NOT schedule a save of its
  // own (see survey-editor#_clearDroppedMedia — the two image writers beside
  // it mark nothing dirty either).
  _writeBg(slot, bg, card = this._activeCard, { notify = true } = {}) {
    if (!card) return
    const spec = this.constructor.BG_SLOTS[slot]
    const clean = {}
    if (bg?.color) clean.color = bg.color
    if (bg?.image) clean.image = bg.image
    // Which ink the words take over this backdrop — only on the slot whose
    // words are drawn ON it. The mobile background has the question and
    // answers on it; the header backdrop sits behind an animation with the
    // card's text on its own panel, and the server drops an ink for it, so
    // sending one would be the editor and the sanitiser disagreeing on every
    // save about a value neither uses. Carried through so a colour measured
    // here and a picture measured asynchronously below both survive the next
    // write — a creator who sets a colour and then a picture must not have
    // the picture's answer overwritten by the colour's.
    if (spec.inked && bg?.ink) clean.ink = bg.ink
    if (spec.inked && !clean.image && clean.color) {
      // A colour needs no decoding, so it is decided on the spot.
      clean.ink = inkForColor(clean.color) || clean.ink
    }

    if (Object.keys(clean).length) card.dataset[spec.key] = JSON.stringify(clean)
    else delete card.dataset[spec.key]

    const el = card.querySelector(spec.target)
    if (el) {
      const url = clean.image ? `url('${String(clean.image).replace(/'/g, "\\'")}')` : ""
      if (slot === "mobile") {
        clean.color ? el.style.setProperty("--mobile-bg-color", clean.color)
                    : el.style.removeProperty("--mobile-bg-color")
        url ? el.style.setProperty("--mobile-bg-image", url)
            : el.style.removeProperty("--mobile-bg-image")
        // The class the stylesheet flips its ink tokens on, mirroring
        // ApplicationHelper#card_mobile_bg_classes so the live editor and the
        // next server render agree without one waiting for the other.
        el.classList.toggle("bg-ink-dark", clean.ink === "dark")
      } else {
        el.style.backgroundColor = clean.color || ""
        el.style.backgroundImage = url
        el.style.backgroundSize     = clean.image ? "cover" : ""
        el.style.backgroundPosition = clean.image ? "center" : ""
      }
      // The class, not just the paint. For the header: on a phone a media-less
      // card has no hero strip at all — .split-left is display: contents — and
      // .has-media-bg is what gives it one, so without this the creator picks
      // a colour, watches the desktop panel change, and sees nothing at all in
      // the mobile frame they picked it for. For the mobile background:
      // .has-mobile-bg is the only thing that paints the panel. Mirrors
      // _split_left.html.erb and _card_component.html.erb respectively.
      el.classList.toggle(spec.klass, Object.keys(clean).length > 0)
    }
    if (!notify) return
    // _notifyDirty, not dispatch("changed"): the editor root listens for
    // `input`, and there is no media-picker:changed binding to pick up — a
    // custom event here would leave the backdrop unsaved until some unrelated
    // edit happened to mark the deck dirty.
    this._notifyDirty()
  }

  _writeAnimBg(bg, card = this._activeCard, opts = {})   { return this._writeBg("panel", bg, card, opts) }
  _writeMobileBg(bg, card = this._activeCard, opts = {}) { return this._writeBg("mobile", bg, card, opts) }

  // The default covers _openBackdrop's mode as well as #open's, and that
  // matters beyond the first frame: setAnimBgColor and clearAnimBg both re-sync
  // after writing, so a default that only knew about "card" would fold the
  // section away the instant a creator picked a colour in a modal that opened
  // on it. (openAnimBgImage is the exception and hides the section itself — it
  // is a drill-down FROM it, and nothing re-syncs while it is open.)
  //
  // The section's words follow the slot: a creator has to be told whether the
  // colour they are about to pick is the header's or the phone's.
  _syncAnimationBg(show = this._mode === "animBg" ||
                          (this._mode === "card" && this._cardTakesBackground)) {
    if (this.hasAnimBgSectionTarget) this.animBgSectionTarget.hidden = !show
    if (!show) return
    const slot = this._bgSlot || "panel"
    if (this.hasAnimBgLabelTarget) {
      this.animBgLabelTarget.textContent = this.animBgLabelTarget.dataset[`${slot}Label`] ||
                                           this.animBgLabelTarget.textContent
    }
    if (this.hasAnimBgHintTarget) {
      this.animBgHintTarget.textContent = this.animBgHintTarget.dataset[`${slot}Hint`] ||
                                          this.animBgHintTarget.textContent
    }
    if (this.hasAnimBgClearTarget) {
      const label = this.animBgClearTarget.dataset[`${slot}Label`]
      if (label) this.animBgClearTarget.textContent = label
    }
    const bg = this._readBg(slot)
    // The swatch shows what the card has, or the slot's own default when it
    // has nothing — never the colour left over from the last card opened.
    if (this.hasAnimBgColorTarget) this.animBgColorTarget.value = bg.color || this._bgDefault(slot)
    if (this.hasAnimBgClearTarget) this.animBgClearTarget.hidden = !(bg.color || bg.image)
  }

  // What each slot paints when nothing has been set: the brand panel behind
  // the header, and the white card behind the answers.
  _bgDefault(slot) {
    return slot === "mobile" ? "#ffffff" : "#2E3564"
  }

  setAnimBgColor(event) {
    const slot = this._bgSlot || "panel"
    this._writeBg(slot, { ...this._readBg(slot), color: event.target.value })
    this._syncAnimationBg()
  }

  // Reuse the library/upload picker for the backdrop image by flipping the
  // mode — applyImage routes back here rather than onto the card's own media,
  // so the animation stays put and only what is behind (or below) it changes.
  // The slot is left exactly as the opener set it: this is a drill-down from
  // the section, not a new aim.
  openAnimBgImage(event) {
    event?.preventDefault()
    this._mode = "animBg"
    this._bgSlot = this._bgSlot || "panel"
    this._showMediaSwapUI(true)
    this.applyBtnTarget.hidden = false
    this._switchTabKey("library")
    this._setMedia("photos")
    this._showMediaToggle(false)
    this._showLottieSection(false)
    if (this.hasAnimBgSectionTarget) this.animBgSectionTarget.hidden = true
    this._setModalTitle(this._bgSlot === "mobile" ? "mobileBackground" : "background")
  }

  // A picture has to be decoded before it can be measured, so this lands after
  // the backdrop is already on screen — the card flips to dark ink a moment
  // after a light picture appears, which is the right way round: the wrong ink
  // for an instant on a picture already visible, rather than a card that waits
  // on a download before it will show any words at all.
  //
  // Measured HERE and stored, not measured on the player: a respondent's phone
  // would otherwise redo this on every visit, on the slowest connections,
  // forever. inkForImage resolves null when the pixels cannot be read (a
  // cross-origin picture with no CORS headers taints the canvas) and null
  // leaves the ink alone rather than guessing. Only for the slot that carries
  // an ink at all.
  async _measureBackdropInk(slot, card, url) {
    if (!this.constructor.BG_SLOTS[slot].inked) return
    const ink = await inkForImage(url)
    if (!ink) return
    const bg = this._readBg(slot, card)
    if (bg.image !== url) return // the creator moved on; this answer is stale

    this._writeBg(slot, { ...bg, ink }, card)
  }

  clearAnimBg(event) {
    event?.preventDefault()
    const slot = this._bgSlot || "panel"
    this._writeBg(slot, {})
    if (this.hasAnimBgColorTarget) this.animBgColorTarget.value = this._bgDefault(slot)
    this._syncAnimationBg()
  }

  // Slow push-in/out loop on the card's own imagery. Meaningless for video
  // (its own motion is enough) and for range (the reaction set already
  // animates) — shown only when the panel is a photo or a Lottie.
  get _cardCanAnimateAsset() {
    const card = this._activeCard
    if (!card || card.dataset.cardType === "range") return false
    return !!(card.dataset.cardImage || card.dataset.cardLottie)
  }

  _syncAnimateAsset() {
    const show = this._mode === "card" && this._cardCanAnimateAsset
    if (this.hasAnimateAssetSectionTarget) this.animateAssetSectionTarget.hidden = !show
    if (show && this.hasAnimateAssetToggleTarget) {
      this.animateAssetToggleTarget.checked = this._activeCard.dataset.cardAnimateAsset === "true"
    }
  }

  toggleAnimateAsset(event) {
    const card = this._activeCard
    if (!card) return
    if (event.target.checked) card.dataset.cardAnimateAsset = "true"
    else delete card.dataset.cardAnimateAsset
    this._syncAnimateAssetClass(card)
    this._notifyDirty()
  }

  // One place to keep the live preview's CSS class in step with the dataset
  // — called here and from every media setter, since switching to video (or
  // clearing the card entirely) makes the toggle's state meaningless.
  _syncAnimateAssetClass(card) {
    card.querySelector(".split-left")
      ?.classList.toggle("has-asset-breathe", card.dataset.cardAnimateAsset === "true")
  }

  async applyLottie(event) {
    event?.preventDefault()
    if (this._mode !== "card" || !this._activeCard || !this.hasCardLottieUrlValue) return
    const pasted = this.lottieInputTarget.value.trim()
    if (!pasted) return

    this.lottieErrorTarget.hidden = true
    this.lottieBtnTarget.disabled = true
    try {
      const res = await fetch(this.cardLottieUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ url: pasted })
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok || !data.url) {
        this.lottieErrorTarget.textContent = data.error || t("editor.lottie_failed", { default: "That link doesn't look like a LottieFiles animation." })
        this.lottieErrorTarget.hidden = false
        return
      }
      this._setCardLottie(this._activeCard, data.url)
      this.lottieInputTarget.value = ""
      this._notifyDirty()
      this.close()
    } catch (_) {
      this.lottieErrorTarget.textContent = t("editor.lottie_failed", { default: "That link doesn't look like a LottieFiles animation." })
      this.lottieErrorTarget.hidden = false
    } finally {
      this.lottieBtnTarget.disabled = false
    }
  }

  // Swap a card's left panel to a looping Lottie, mirroring the server render
  // in shared/_split_left. Own class (card-lottie, NOT nps-lottie) — the
  // :has(.nps-lottie) CSS hides the Change-media CTA, which this must keep.
  _setCardLottie(card, url) {
    card.dataset.cardLottie = url || ""
    card.dataset.cardImage = ""
    // An animation fills the panel on its own terms — there is no cover-crop
    // for a focal point to move, so the card stops carrying one.
    delete card.dataset.cardFocalX
    delete card.dataset.cardFocalY
    delete card.dataset.cardFocalZoom
    // No photo, no re-crop record — see _setCardImage.
    delete card.dataset.cardImageSource
    delete card.dataset.cardImageCrop
    this._syncAdjustFab(card)
    card.dataset.cardImageCredit = ""
    card.dataset.cardImageCreditUrl = ""
    card.dataset.cardVideo = ""
    card.dataset.cardVideoPoster = ""
    // Same preference-not-tied-to-one-asset rule as a photo: survives
    // swapping to a different animation, cleared only when there's none left.
    if (!url) delete card.dataset.cardAnimateAsset
    this._syncAnimateAssetClass(card)
    const left = card.querySelector(".split-left")
    if (!left) return
    left.querySelector(".split-left-img[data-card-media]")?.remove()
    left.querySelector(".split-left-video[data-card-media]")?.remove()
    left.querySelector(".split-left-overlay[data-card-media]")?.remove()
    left.querySelector(".split-left-credit[data-card-media]")?.remove()
    let el = left.querySelector(".card-lottie[data-card-media]")
    if (!url) { el?.remove(); return }
    if (el) {
      // urlsValueChanged() re-renders the mounted player in place.
      el.dataset.lottiePlayerUrlsValue = JSON.stringify([ url ])
      return
    }
    el = document.createElement("div")
    el.className = "card-lottie"
    el.dataset.cardMedia = "true"
    el.dataset.controller = "lottie-player"
    el.dataset.lottiePlayerUrlsValue = JSON.stringify([ url ])
    el.dataset.lottiePlayerCurrentValue = "1"
    el.dataset.lottiePlayerLoopValue = "true"
    const mount = document.createElement("div")
    mount.className = "card-lottie-mount"
    mount.dataset.lottiePlayerTarget = "mount"
    el.appendChild(mount)
    left.prepend(el)
  }

  // Add/update/remove the subtle creator credit on a card's left panel.
  _renderCardCredit(left, afterEl, credit, creditUrl, verb = "Photo") {
    let el = left.querySelector(".split-left-credit[data-card-media]")
    if (!credit) { el?.remove(); return }
    if (!el) {
      el = document.createElement("div")
      el.className = "split-left-credit"
      el.dataset.cardMedia = "true"
      ;(afterEl || left.firstChild)?.after(el)
    }
    const label = `${verb} by ${credit}`
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
  }

  _notifyDirty() {
    // The survey-editor controller listens on `input` from the editor root,
    // but image swaps don't bubble such an event — dispatch one explicitly.
    this.element.dispatchEvent(new CustomEvent("input", { bubbles: true }))
  }

  _setApplyEnabled(enabled) {
    this.applyBtnTarget.disabled = !enabled
  }

  _parseUrls(raw) {
    if (!raw) return []
    try {
      const arr = JSON.parse(raw)
      return Array.isArray(arr) ? arr.filter(u => typeof u === "string" && u.length) : []
    } catch (_e) {
      return []
    }
  }

  // Populates (or hides) the "Recommended" section at the top of the
  // Library tab. Cloned thumbnails reuse the existing libraryItem target +
  // pickLibraryItem action so selection works identically to the
  // server-rendered items below.
  _renderRecommended(urls, label) {
    if (!this.hasRecommendedSectionTarget || !this.hasRecommendedGridTarget) return
    this.recommendedGridTarget.replaceChildren()
    if (!urls.length) {
      this.recommendedSectionTarget.hidden = true
      return
    }
    if (this.hasRecommendedLabelTarget) this.recommendedLabelTarget.textContent = label
    const frag = document.createDocumentFragment()
    for (const url of urls) {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "media-library-item"
      btn.title = url
      btn.style.backgroundImage = `url('${url.replace(/'/g, "\\'")}')`
      btn.dataset.url = url
      btn.dataset.mediaPickerTarget = "libraryItem"
      btn.dataset.action = "click->media-picker#pickLibraryItem"
      btn.setAttribute("aria-selected", "false")
      frag.appendChild(btn)
    }
    this.recommendedGridTarget.appendChild(frag)
    this.recommendedSectionTarget.hidden = false
  }
}
