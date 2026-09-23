import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { analyzeCard, analyzeVerto, typeLabel, CAPPED_LABEL_TYPES,
         COUNTED_LABEL_TYPES, SCALE_LABEL_MAX, optionLabelLimit } from "lib/verto_rules"
import { ROUTABLE_TYPES, OPTION_EDITED_TYPES, matchOpFor } from "lib/routable_types"
import { isPaged } from "lib/paged_types"
import { NON_QUESTION_TYPES } from "lib/question_types"
import { isFullScreenAnswer } from "lib/full_screen_types"
import { OPTION_STYLE_TYPES } from "lib/option_style_types"
import { styleFromRow } from "lib/option_styles"
import { hasFormatting } from "lib/rich_text"
import { cardEyebrow, MULTI_SELECT_TYPES } from "lib/card_eyebrow"
import { NPS_VESSELS, npsStageStyle, npsVesselSvg, npsVesselFor, npsCustomScale } from "lib/nps_vessels"


// Choice-shaped types — mirrors TokenGrading::CHOICE (app/lib/token_grading.rb).
// These default to a per-option token award but can opt into a flat award for
// completing the question at all (see setTokenAwardMode).
const CHOICE_TYPES = [ "multiple_choice", "select_many", "yes_no", "select_one_grid", "select_many_grid", "scenario" ]

// Flow colours — mirrors Survey::FLOW_COLORS (and the flow map's LANE_PALETTE)
// so a flow minted client-side gets the same palette the server would assign.
const FLOW_COLORS = [ "#8B85FF", "#01EACB", "#F59E0B", "#F472B6", "#38BDF8", "#A3E635" ]

// Where a card type keeps its option labels. The single definition of "an
// option label" on this side: _optionEls reads it to serialize a card, and the
// character counter reads it to know what it is counting. It used to be an
// object literal inside _optionEls, which was fine while serializing was the
// only caller — a second caller is exactly when a private literal becomes a
// second opinion waiting to drift.
const OPTION_LABEL_SELECTORS = {
  multiple_choice: ".pick-text", select_many: ".pick-text", yes_no: ".pick-text",
  prioritise: ".choice-list-label",
  select_one_grid: ".choice-label", select_many_grid: ".choice-label",
  range: ".slider-label-text", nps: ".slider-label-text",
  // Every caption, not just the two ends. While this matched only the two end
  // spans, serialize() rebuilt a rating card's options from those two nodes and
  // a generated or templated five-label card was cut to two on its first
  // autosave — the middle labels were being thrown away silently. The mid
  // captions are .rating-label too and sit between the ends in DOM order, so
  // the list comes back out in the right order.
  rating: ".rating-label",
  tap_card: ".rotate-card span[contenteditable]",
  scenario: ".pick-text"
}

// What the save response's `warnings` codes mean to a creator. The server
// (Survey.sanitize_cards_images! and SurveysController#update — grep
// `warnings << "`) reports every silent repair through this one array, and
// the editor used to answer all of them with "an image didn't stick": a deck
// holding a second welcome card, a retired card type or a consent gate after
// its first question was told to re-upload an image that was perfectly fine,
// on every autosave, forever. JsConstantParityTest pins this table to the
// server's codes, so a new code can't fall back to the image wording unseen;
// a genuinely unknown code still does, deliberately — a raw dotted key is
// worse than a slightly wrong sentence.
const SAVE_WARNING_KEYS = {
  image: "editor.save_warning",
  option_images: "editor.save_warning",
  background_image: "editor.save_warning",
  video: "editor.save_warning_media",
  lottie: "editor.save_warning_media",
  // A backdrop is a PICTURE on a card, so it takes the sentence that names the
  // card rather than the video/animation one — which, being first in the
  // server's list, would otherwise outrank `image` and suppress the naming
  // path for a card that lost both (see _saveWarningMessage).
  media_bg: "editor.save_warning",
  duplicate_welcome: "editor.save_warning_duplicate",
  duplicate_respondent_code: "editor.save_warning_duplicate",
  duplicate_points_intro: "editor.save_warning_duplicate",
  retired_card: "editor.save_warning_retired",
  consent_gate_moved: "editor.save_warning_consent_moved"
}

// The codes whose drop is a picture ON A CARD — the ones `warning_details`
// (cid per drop, and the statement index for a tap card) can point at, so the
// sentence can name the card and the page can stop showing the picture.
const CARD_IMAGE_CODES = [ "image", "option_images", "media_bg" ]

// Token-award rows are keyed by canonical option label, so the types whose
// labels are edited live in the card need their rows rebuilt as options change
// (see syncTokenRowsFor) — yes_no's canonicals are fixed, the flat-award types
// key nothing on labels, and tap_card is handled separately (statements).
const TOKEN_SYNCED_TYPES = [ "multiple_choice", "select_many", "select_one_grid", "select_many_grid", "scenario" ]

// ── Undo / redo ────────────────────────────────────────────────────────────
// (the model itself is described above _bindUndo, in the class)
const UNDO_MAX_ENTRIES = 100
// A rough budget for the html the two stacks retain, in UTF-16 code units. A
// card is 10-30k, so this is hundreds of changed cards before the oldest
// entries are let go.
const UNDO_MAX_CHARS = 8 * 1024 * 1024
// A run of typing is one entry until the creator pauses this long.
const UNDO_TYPING_MS = 700
// A held group (a gesture that spans an await) is force-closed after this,
// so a hung fetch cannot freeze the stack.
const UNDO_HOLD_MS = 20000
const UNDO_BLOCK_SELECTOR = ".quiz-correct-block, .token-award-block, .logic-branch-block"
// Classes that describe the screen, not the deck: a snapshot drops them so a
// restore never selects a card or restarts a pulse.
const UNDO_PRESENTATION_CLASSES = [ "selected", "card-flash", "card-optimising" ]
// Where ⌘Z belongs to this stack rather than to the browser: text inside a
// deck card (or one of its relocated blocks) and the Verto's name. Fields
// outside — the consent gate, the settings panels, the add-question modal —
// keep the browser's own undo.
const UNDO_OWNED_FIELDS = "[data-survey-editor-target='card'], .quiz-correct-block, .token-award-block, " +
  ".logic-branch-block, [data-survey-editor-target='vertoTitle'], [data-mobile-studio-target='titleText'], " +
  "[data-survey-editor-target='vertoTheme'], [data-mobile-studio-target='themeText']"
// The fields a caret can be put back into after an undo, indexed per card.
const UNDO_FIELD_SELECTOR = "[contenteditable='true'], input, textarea"

export default class extends Controller {
  static targets = ["card", "saveButton", "status", "tab", "feed", "localeCode", "vertoScore", "scoreBoard", "panelLight",
    "cardFlags", "panelOther", "panelRequired", "panelAskOnce", "responseScale",
                    "maxChoices", "maxChoicesPicker", "npsClassic", "panelNpsClassic", "locationScope",
                    "recallToggle", "panelRecall", "vertoTitle", "vertoTheme", "undoBtn", "redoBtn"]
  static values  = {
    url: String, title: String, theme: String, description: String,
    optimiseUrl: { type: String, default: "" },
    defaultLocale: { type: String, default: "en" },
    locales: { type: Array, default: [] },
    rtlLocales: { type: Array, default: [] },
    quiz: { type: Boolean, default: false },
    tokenisation: { type: Boolean, default: false },
    // Answer-branching: gates the per-option "go to…" route selects and their
    // serialization. logicConfig carries the static labels + end-screen list
    // the route dropdowns are built from (see refreshLogicTargets).
    logic: { type: Boolean, default: false },
    logicConfig: { type: Object, default: {} },
    // First-class named flows ({id, name, color, exit} — Survey#flows_list).
    // Copied to a mutable working set in connect(); serialize() sends it back.
    flows: { type: Array, default: [] },
    live: { type: Boolean, default: false },
    // Where one card's intro modal is saved on its own. A locked deck suppresses
    // autosave entirely (see flushSave), and the modal is the one content edit
    // such a deck may still take — SurveysController#update_card_modal.
    cardModalUrl: { type: String, default: "" },
    // The wording revision this page was rendered at. Sent back with every
    // save so the server can tell which translations the Language check screen
    // has changed since: serialize() rebuilds every language's i18n entry from
    // a store seeded at page load, so without this a tab older than a
    // reviewer's fix would write the old wording back over it. The number is
    // never updated client-side — a page that has not reloaded has not seen
    // anything newer, which is exactly what it is meant to admit.
    translationsRevision: { type: Number, default: 0 }
  }

  // Largest body flushSave will entrust to a keepalive request on unload. The
  // spec's ceiling is 64KB and it is shared across every in-flight keepalive
  // request, so this sits well under it: measured in Chromium, 32KB sends and
  // 63KB is rejected outright when anything else is in flight.
  static KEEPALIVE_MAX_BYTES = 32 * 1024

  _saveTimer = null
  _dirty = false

  connect() {
    this._activeLocale = this.defaultLocaleValue
    this._eyebrows = this._loadEyebrows()
    this._flows = JSON.parse(JSON.stringify(this.flowsValue || []))
    // Which flow each multi-flow cluster is showing (cluster key → flow id).
    this._activeFlowTabs = new Map()
    this._seedStore()
    this._bindUndo()
    this._bindLabelCap()
    this.refreshAll()
    // The state every later commit diffs against. Not on a live deck: it
    // records nothing, so there is nothing to diff.
    if (!this.liveValue) this._undoBase = this._snapshotDeck()

    // Safety net for the 1.5s autosave debounce: if the page is hidden or
    // navigated away while an edit is still pending, flush it immediately so the
    // draft on the server never lags behind what's on screen (the cause of
    // "edits not saved" / draft-vs-preview drift). pagehide covers bfcache and
    // mobile; visibilitychange covers tab-switch/app-background.
    // The event is passed through: on beforeunload — and only there — flushSave
    // may need to stop the navigation, because a deck too big for a keepalive
    // request cannot be delivered once the page is gone.
    this._flushHandler = (event) => this.flushSave(event)
    window.addEventListener("pagehide", this._flushHandler)
    window.addEventListener("beforeunload", this._flushHandler)
    document.addEventListener("visibilitychange", this._visibilityHandler = () => {
      if (document.visibilityState === "hidden") this.flushSave()
    })
    // The editor page also carries full-page POST→redirect forms (the
    // Tokenisation panel's toggle, token types, intro picker, the leaderboard
    // block…), and Turbo drives them: pagehide/beforeunload never fire, so an
    // edit still inside the 1.5s debounce was silently discarded and the
    // re-render restored DB state. Capture on WINDOW — Turbo's
    // FormSubmitObserver listens at document capture, and window capture
    // fires first — hold the form, finish the save, then resubmit.
    window.addEventListener("submit", this._submitFlushHandler = (e) => this._flushBeforeSubmit(e), true)
  }

  disconnect() {
    window.removeEventListener("pagehide", this._flushHandler)
    window.removeEventListener("beforeunload", this._flushHandler)
    window.removeEventListener("submit", this._submitFlushHandler, true)
    document.removeEventListener("visibilitychange", this._visibilityHandler)
    this._unbindUndo()
    this._hideLabelCount()
  }

  // ── Undo / redo ───────────────────────────────────────────────────────────
  // Snapshot-based, and every deck edit is in it — typing included.
  //
  // The previous stack was operation-based and covered nine structural
  // gestures; everything else (words, options, answer types, the card
  // switches, flows, routing, media, ✨ Optimise) marked the deck dirty and
  // pushed nothing, so the button sat greyed after most edits, and a ⌘Z after
  // one of them undid whatever structural change came before it instead. Its
  // comment gave two reasons. "serialize() reads live DOM and there is no
  // render-from-JSON path, so a snapshot couldn't be put back" — true, and
  // beside the point: a card is put back by morphing its OWN element
  // (attributes and children from the captured html), so the element identity
  // that _store and type-panel's block WeakMaps are keyed on survives, and a
  // deleted card is re-inserted as the same detached node. "Text is better
  // left to the browser" — a stack that owns some changes and not others is
  // exactly the one that greys out and misattributes (BUG-014's lesson, taken
  // to its end), so this one owns the deck's text too and claims ⌘Z inside
  // its fields; fields outside the deck keep the browser's undo.
  //
  // How: markDirty() is the one call every deck change already makes, so it is
  // where changes are noticed (_noteUndoChange). A commit takes a snapshot —
  // per card: the serialize() JSON as content identity, the outerHTML as the
  // thing to restore, its (possibly relocated) quiz/token/logic blocks and its
  // _store entry; plus the flows array, the title and the theme — diffs it against the
  // last committed one, and pushes {before, after} holding only what differed.
  // Presentation-only churn (selection, pulses, renumbering) is not a change:
  // the JSON decides. Typing coalesces until a pause (UNDO_TYPING_MS) or a move
  // to another field; every other gesture is one entry. Undo/redo reconcile
  // the feed to a side (order and membership first, then each changed card in
  // place), re-snapshot, and persist through the ordinary autosave.
  //
  // Outside it, by design: the in-feed gate cards and the settings panels
  // (both save through update_settings, and a settings form reloads the page,
  // which starts this history fresh), and any DOM change serialize() does not
  // carry — those do not persist either.

  // ── Grid tile labels: a cap, and a counter that shows it ─────────────────
  //
  // An image-grid tile is drawn at a fixed proportion with a line of label
  // under it, and 20 characters is what that line holds — measured at 16px, a
  // 393px phone gives the column ~172px and ~8.6px a character; a 280px Fold
  // gives about 14 characters. Past that a label wraps, the row grows, and the
  // card a respondent gets stops being the card the creator was shown.
  //
  // The number is NOT a new one: OPTION_LIMITS in lib/verto_rules has said 20
  // for grid tiles all along and the Rules of the Game panel already tells
  // creators to shorten past it. This makes the editor stop advising something
  // it doesn't enforce, and imports the figure rather than copying it.
  //
  // Delegated from the editor root rather than hooked per row, because these
  // labels are emitted from two places that have to mirror each other —
  // shared/_card_component.html.erb and lib/choice_templates.js — and that
  // file's own header records what happens when they drift.
  //
  // A LIST row is counted but not capped, and the asymmetry is the point
  // rather than an inconsistency: a list row spans the answer panel, so a long
  // label just makes the row taller and the square tile beside it does not
  // depend on the label at all. Nothing breaks, so nothing is refused — the
  // count is a nudge toward the Rules of the Game budget (40 for lists,
  // measured: an iPhone 15 list row fits ~32 characters a line against a grid
  // tile's ~22).
  _bindLabelCap() {
    // Capture, so a rich-text or picker handler can't swallow it first.
    this.element.addEventListener("beforeinput", (e) => this._capLabel(e), { capture: true })
    this.element.addEventListener("focusin",  (e) => this._showLabelCount(e))
    this.element.addEventListener("focusout", () => this._hideLabelCount())
    // Typing fires beforeinput then input; the counter reads the settled value.
    this.element.addEventListener("input", (e) => {
      const modalRole = e.target?.dataset?.role
      if (modalRole === "card-modal-title" || modalRole === "card-modal-body") {
        const card = e.target.closest("[data-survey-editor-target='card']")
        // The folded modal bar shows the creator's own heading, so it follows
        // the keystrokes rather than the heading it was rendered with.
        if (modalRole === "card-modal-title") this._paintCardModalLabel(card)
        // On a LOCKED deck the ordinary autosave never fires, so the modal
        // saves itself. On a draft this is a no-op and autosave carries it.
        this._saveCardModal(card)
      }
      const label = this._budgetedLabelOf(e.target)
      if (!label) return
      if (this._isCapped(label)) this._trimLabel(label)
      this._renderLabelCount(label)
    })
  }

  // The label being edited, if it has a budget. Two kinds qualify:
  //
  //   - an OPTION label on a counted type, resolved through
  //     OPTION_LABEL_SELECTORS rather than a hardcoded class, so a grid tile
  //     and a list row are found the same way;
  //   - a tap card's RESPONSE label, which is a separate list on the same card
  //     (a tap card's options are its statements) and so has to be matched on
  //     its own hook rather than through that table.
  _budgetedLabelOf(node) {
    const response = node?.closest?.("[data-tap-response-label]")
    if (response) return response.isContentEditable ? response : null

    const card = node?.closest?.("[data-survey-editor-target='card']")
    const type = card?.dataset.cardType
    if (!COUNTED_LABEL_TYPES.includes(type)) return null
    const sel = OPTION_LABEL_SELECTORS[type]
    const label = sel ? node.closest(sel) : null
    return label?.isContentEditable ? label : null
  }

  _isResponseLabel(label) {
    return !!label?.closest?.("[data-tap-response-label]")
  }

  // Whether this label's limit is a wall or a line on the floor. The kinds
  // that refuse the keystroke are the ones whose layout DEPENDS on the length:
  // a grid tile, a range slider's stops, and a tap card's responses. A list row
  // just gets taller, so its budget stays advisory. See _bindLabelCap.
  _isCapped(label) {
    if (this._isResponseLabel(label)) return true
    const type = label.closest("[data-survey-editor-target='card']")?.dataset.cardType
    return CAPPED_LABEL_TYPES.includes(type)
  }

  // The budget for the label being edited — 20 on a grid tile, 40 on a list
  // row, 17 on either scale's answer label — read from the rules module so the
  // counter and the Rules of the Game panel can never quote different numbers
  // at the same label.
  _limitFor(label) {
    if (this._isResponseLabel(label)) return SCALE_LABEL_MAX
    const type = label.closest("[data-survey-editor-target='card']")?.dataset.cardType
    return optionLabelLimit(type)
  }

  // Refuse anything that would make the label longer once it is at the cap.
  //
  // Blocks INSERTION, never deletion — a Verto written before the cap can hold
  // a 40-character label, and truncating it the moment someone put a cursor in
  // it would take 20 characters away that nobody asked to lose. Over-length
  // labels can still be edited down; they just can't grow.
  //
  // beforeinput rather than keydown: one handler covers typing, paste, drop,
  // autocomplete and IME commit, which is the whole surface. Length is counted
  // on textContent, not innerHTML — these labels carry rich-text markup and a
  // bold tag is not a character the respondent reads.
  //
  // This is the first of two passes. It can only act on inputs that declare
  // how much text they are about to insert, and not all of them do: a bulk
  // insert can arrive with `data` null and no dataTransfer, in which case
  // there is nothing here to measure and _trimLabel below catches it after
  // the fact. Doing it in this order matters — predicting first means the
  // ordinary keystroke at the cap is simply refused, with no character ever
  // painted and taken away again.
  _capLabel(event) {
    const label = this._budgetedLabelOf(event.target)
    if (!label || !this._isCapped(label)) return
    if (!event.inputType?.startsWith("insert")) return

    const incoming = event.data?.length ??
                     event.dataTransfer?.getData("text/plain")?.length ?? null
    if (incoming === null) return   // unmeasurable — leave it to the backstop

    const selected = this._selectionLengthIn(label)
    if (label.textContent.length - selected + incoming <= this._limitFor(label)) return

    event.preventDefault()
    this._renderLabelCount(label, { rejected: true })
  }

  // The backstop, run after the DOM has settled. Trims a label that got past
  // the guard above back to the cap.
  //
  // Scoped by whether the label was already COMPLIANT when it was focused: a
  // legacy 45-character label is left at 45 and can only ever shrink, while
  // one inside the cap is held to it however the text arrived. That
  // distinction is the whole reason this isn't a blanket
  // `textContent = slice(0, 20)`.
  //
  // Compliance is read at focus rather than from the beforeinput above,
  // because not every insertion fires beforeinput — document.execCommand does
  // not, and that is not a test artefact: anything driving the editor
  // programmatically takes the same path. Anchoring on focus means the
  // backstop holds whatever route the text came in by.
  //
  // Trims from the last text node backwards rather than reassigning
  // textContent, because these labels carry rich-text markup and flattening
  // them would silently drop a creator's bold on every overlong paste.
  _trimLabel(label) {
    const max = this._limitFor(label)
    if (label.textContent.length <= max) {
      // Brought under the cap by hand — hold it there from now on, so a legacy
      // label that has been tidied up doesn't stay exempt for the rest of the
      // session.
      this._labelCompliant = true
      return
    }
    if (!this._labelCompliant) return

    let excess = label.textContent.length - max
    const walker = document.createTreeWalker(label, NodeFilter.SHOW_TEXT)
    const texts = []
    while (walker.nextNode()) texts.push(walker.currentNode)
    for (const node of texts.reverse()) {
      if (excess <= 0) break
      const drop = Math.min(excess, node.data.length)
      node.data = node.data.slice(0, node.data.length - drop)
      excess -= drop
    }

    // Caret to the end, which is where someone who just typed or pasted
    // expects it — leaving it where the browser put it would drop it past the
    // text that no longer exists.
    const sel = window.getSelection?.()
    if (sel && label.contains(document.activeElement) || document.activeElement === label) {
      const range = document.createRange()
      range.selectNodeContents(label)
      range.collapse(false)
      sel?.removeAllRanges()
      sel?.addRange(range)
    }
    this._renderLabelCount(label, { rejected: true })
  }

  // How much of the label the pending input would replace — without it, typing
  // over a fully-selected 20-character label would be refused as if it were an
  // append, and the label could never be rewritten once full.
  _selectionLengthIn(label) {
    const sel = window.getSelection?.()
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return 0
    const range = sel.getRangeAt(0)
    return label.contains(range.commonAncestorContainer) ? range.toString().length : 0
  }

  // ── The counter ──────────────────────────────────────────────────────────
  // Same shape as the free-text counter respondents already get
  // (freeform_controller): "n/max characters", going hot when the limit is
  // reached. One node that follows the focus rather than one per option, which
  // on a ten-tile grid would be ten pieces of chrome for one that is in use.
  //
  // Two hot states, because there are two kinds of limit and they must not
  // look alike: .is-full is a wall (a grid tile at 20 — the next keystroke
  // does nothing) and .is-over is a line already crossed (a list row past 40 —
  // still typable). A creator who learns that pink means "stop" on a grid
  // would otherwise be confused when it doesn't on a list.
  _showLabelCount(event) {
    const label = this._budgetedLabelOf(event.target)
    if (!label) return
    // Read compliance here, not on input — see _trimLabel.
    this._labelCompliant = label.textContent.length <= this._limitFor(label)
    this._labelCounter ||= Object.assign(document.createElement("div"),
                                         { className: "option-limit-counter" })
    // A grid tile or list row can take the counter as a sibling. The two scales
    // cannot: a slider's labels are five columns of one row and a tap card's
    // are a strip, so a sixth child would shove the layout sideways under the
    // creator mid-keystroke. Those get it pinned to the widget instead.
    const pinned = label.closest(".slider-wrap, .rotate-wrap")
    this._labelCounter.classList.toggle("option-limit-counter--pinned", !!pinned)
    if (pinned) {
      pinned.appendChild(this._labelCounter)
    } else {
      this._labelCounter.style.left = this._labelCounter.style.top = ""
      label.after(this._labelCounter)
    }
    this._renderLabelCount(label)
  }

  // Park the pinned counter next to the label it is counting, inside the widget
  // it was appended to, without covering any of the OTHER labels.
  //
  // Anchored to the label rather than parked in a corner of the widget: at a
  // fixed bottom-centre it sat on the slider's own middle stop and on the tap
  // card's Add-statement button. Chrome that hides other people's words is
  // worse than chrome that shifts a row, which is the whole reason this floats
  // rather than sitting in flow.
  //
  // Then four candidate spots rather than one, because the same widget lays its
  // labels out more than one way and "above" is only right for some of them: a
  // horizontal slider's five stops are a row (above is clear), the SAME slider
  // on its vertical axis is a column (above is the previous stop), and a tap
  // strip past four is an arc, where neither is reliably true. Try above, below,
  // right, left, and take the first that lands on nothing.
  //
  // Measured from bounding rects rather than offsetLeft: the tap strip's pills
  // are absolutely positioned on an arc with a translate on them, so their
  // offset parent chain says nothing useful about where they actually are.
  PINNED_PEERS = ".slider-label-text, [data-tap-response-label]"

  _placeLabelCounter(label) {
    const el = this._labelCounter
    const host = el?.parentElement
    if (!host || !el.classList.contains("option-limit-counter--pinned")) return

    const h = host.getBoundingClientRect()
    const l = label.getBoundingClientRect()
    const c = el.getBoundingClientRect()
    const GAP = 6

    const peers = Array.from(host.querySelectorAll(this.PINNED_PEERS))
      .filter((n) => n !== label)
      .map((n) => n.getBoundingClientRect())
      .filter((r) => r.width > 0 && r.height > 0)

    // Host-relative, and never so far out that the counter leaves the widget.
    const inX = (x) => Math.min(Math.max(x, 2), Math.max(2, h.width - c.width - 2))
    const inY = (y) => Math.min(Math.max(y, 2), Math.max(2, h.height - c.height - 2))
    const midX = inX((l.left - h.left) + (l.width - c.width) / 2)
    const midY = inY((l.top - h.top) + (l.height - c.height) / 2)

    const spots = [
      [ midX, (l.top - h.top) - c.height - GAP ],          // above
      [ midX, (l.bottom - h.top) + GAP ],                  // below
      [ (l.right - h.left) + GAP, midY ],                  // right
      [ (l.left - h.left) - c.width - GAP, midY ]          // left
    ]

    const clear = ([ x, y ]) => {
      if (x < 0 || y < 0 || x + c.width > h.width || y + c.height > h.height) return false
      const box = { left: h.left + x, top: h.top + y,
                    right: h.left + x + c.width, bottom: h.top + y + c.height }
      return !peers.some((r) => box.left < r.right && box.right > r.left &&
                                box.top < r.bottom && box.bottom > r.top)
    }

    // Nothing clear anywhere (a widget smaller than the counter): keep it on the
    // label rather than flinging it somewhere arbitrary.
    const [ x, y ] = spots.find(clear) || [ midX, midY ]
    el.style.left = `${Math.round(x)}px`
    el.style.top = `${Math.round(y)}px`
  }

  _hideLabelCount() {
    this._labelCounter?.remove()
    this._countedLabel = null
  }

  _renderLabelCount(label = null, { rejected = false } = {}) {
    const el = this._labelCounter
    if (!el?.isConnected) return
    // When pinned it has no label sibling to fall back to, so remember which
    // label it is counting.
    const target = label || this._countedLabel || el.previousElementSibling
    if (!target) return
    this._countedLabel = target
    const limit = this._limitFor(target)
    if (limit == null) return
    const len = target.textContent.length
    el.textContent = `${len}/${limit} ${t("card.characters")}`
    // A capped label reads as full AT the limit — that is the moment the next
    // keystroke stops doing anything, so saying so a character early would be
    // a lie in the other direction. An advisory one only goes hot once the
    // limit is actually behind it, because reaching 40 on a list is fine.
    const capped = this._isCapped(target)
    el.classList.toggle("is-full", capped && len >= limit)
    el.classList.toggle("is-over", !capped && len > limit)
    // After the text is set, so the width it is centred on is the width it
    // will actually have.
    this._placeLabelCounter(target)
    // A flash on the keystroke that was refused, so the cap is felt and not
    // just silently ignored.
    if (rejected) {
      el.classList.remove("is-rejected")
      void el.offsetWidth   // restart the animation rather than let it no-op
      el.classList.add("is-rejected")
    }
  }

  _bindUndo() {
    this._undoStack = []
    this._redoStack = []
    this._undoBase  = null
    this._undoHold  = 0
    this._replaying = false
    this._refreshUndoButtons()

    this._undoKeyHandler = (event) => this._undoKeydown(event)
    document.addEventListener("keydown", this._undoKeyHandler)
    // The context menu's Undo and a phone's shake-to-undo arrive as a
    // beforeinput, not a keystroke.
    this._undoInputHandler = (event) => this._undoBeforeInput(event)
    document.addEventListener("beforeinput", this._undoInputHandler, true)
    // A run of typing closes when the creator moves on — to another field, or
    // to a click anywhere else — so the next gesture gets an entry of its own.
    // Capture phase: this has to run before the click's own handler mutates.
    this._undoFocusHandler   = (event) => this._closeTypingRunUnless(event.target)
    this._undoPointerHandler = (event) => this._closeTypingRunUnless(event.target)
    this.element.addEventListener("focusin", this._undoFocusHandler, true)
    this.element.addEventListener("pointerdown", this._undoPointerHandler, true)
  }

  _unbindUndo() {
    document.removeEventListener("keydown", this._undoKeyHandler)
    document.removeEventListener("beforeinput", this._undoInputHandler, true)
    this.element.removeEventListener("focusin", this._undoFocusHandler, true)
    this.element.removeEventListener("pointerdown", this._undoPointerHandler, true)
    clearTimeout(this._undoTypingTimer)
    clearTimeout(this._undoGestureTimer)
    clearTimeout(this._undoHoldTimer)
  }

  // ⌘Z / Ctrl+Z undo; ⌘⇧Z, Ctrl+⇧Z and Ctrl+Y redo.
  _undoKeydown(event) {
    if (event.isComposing || event.altKey) return
    const mod = event.metaKey || event.ctrlKey
    if (!mod) return
    const key  = (event.key || "").toLowerCase()
    const undo = key === "z" && !event.shiftKey
    const redo = (key === "z" && event.shiftKey) || (key === "y" && event.ctrlKey && !event.metaKey)
    if (!undo && !redo) return
    // A locked deck records nothing, so there is nothing to claim the key for
    // — and the intro modal, the one edit it still takes, keeps native undo.
    if (this.liveValue) return
    if (!this._ownsUndoKey(event.target)) return
    event.preventDefault()
    if (undo) this.undo()
    else this.redo()
  }

  _undoBeforeInput(event) {
    const type = event.inputType
    if (type !== "historyUndo" && type !== "historyRedo") return
    if (this.liveValue || !this._ownsUndoKey(event.target)) return
    event.preventDefault()
    if (type === "historyUndo") this.undo()
    else this.redo()
  }

  // Anywhere that is not a text field, or a text field the deck owns.
  _ownsUndoKey(target) {
    if (!(target instanceof Element)) return true
    const field = target.isContentEditable || [ "INPUT", "TEXTAREA", "SELECT" ].includes(target.tagName)
    return !field || !!target.closest(UNDO_OWNED_FIELDS)
  }

  // The chrome's ↩ / ↪ buttons — same stacks and live guard as the keys. Both
  // are disabled whenever their stack is empty; the checks in undo()/redo()
  // are belt and braces.
  undoClick() { if (!this.liveValue) this.undo() }
  redoClick() { if (!this.liveValue) this.redo() }

  undo() {
    this._flushUndoTimers()
    const entry = this._undoStack.pop()
    if (!entry) return
    this._applySnapshotSide(entry.before)
    this._redoStack.push(entry)
    this._refreshUndoButtons()
    this.flash(t("editor.undone"), "text-aquamarine")
    this._restoreFocus(entry.focus)
  }

  redo() {
    // A change typed since the undo closes the redo branch, the same way it
    // would in any editor — committing it here is what does that.
    this._flushUndoTimers()
    const entry = this._redoStack.pop()
    if (!entry) return
    this._applySnapshotSide(entry.after)
    this._undoStack.push(entry)
    this._refreshUndoButtons()
    this.flash(t("editor.redone"), "text-aquamarine")
    this._restoreFocus(entry.focus)
  }

  // Plural: the mobile studio's overflow menu carries a second Undo and Redo
  // (the desktop float bar's are hidden at phone width), and a button that
  // never greys out claims there is something to undo when there is not.
  _refreshUndoButtons() {
    const noUndo = !this._undoStack?.length
    const noRedo = !this._redoStack?.length
    this.undoBtnTargets.forEach(btn => { btn.disabled = noUndo })
    this.redoBtnTargets.forEach(btn => { btn.disabled = noRedo })
  }

  // ── Noticing changes ──────────────────────────────────────────────────────
  // Called by markDirty with whatever event reached it (often none). Typing —
  // an input event streaming from a text field, a slider or a colour well —
  // keeps one entry open until the creator pauses; anything else is a gesture
  // and commits on the next macrotask, so the several markDirty calls one
  // gesture makes (a type switch rebuilds, dispatches, syncs) land in one
  // entry. A macrotask rather than an animation frame: frames pause in a
  // background tab and are throttled under load, and nothing here paints.
  _noteUndoChange(event) {
    if (!this._undoBase) return
    if (this._undoHold > 0) { this._undoCommitWanted = true; return }
    if (this._undoKind(event) === "typing") {
      this._undoTypingField = document.activeElement
      clearTimeout(this._undoTypingTimer)
      this._undoTypingTimer = setTimeout(() => this._commitUndo(), UNDO_TYPING_MS)
      return
    }
    clearTimeout(this._undoTypingTimer)
    this._undoTypingTimer = null
    if (!this._undoGestureTimer) this._undoGestureTimer = setTimeout(() => this._commitUndo(), 0)
  }

  _undoKind(event) {
    if (!event) return "gesture"
    // The colour well fires per drag frame; each stop would be an entry.
    if (event.type === "option-style:changed") return "typing"
    if (event.type !== "input") return "gesture"
    return this._isStreamingInput(event.target) ? "typing" : "gesture"
  }

  _isStreamingInput(node) {
    if (!(node instanceof Element)) return false
    if (node.isContentEditable || node.tagName === "TEXTAREA") return true
    if (node.tagName !== "INPUT") return false
    const type = (node.type || "text").toLowerCase()
    return ![ "checkbox", "radio", "file", "button", "submit", "reset", "image" ].includes(type)
  }

  // Focus or a pointer landing outside the field being typed in ends its run.
  _closeTypingRunUnless(target) {
    if (!this._undoTypingTimer) return
    const field = this._undoTypingField
    if (field && target instanceof Node && field.contains(target)) return
    this._commitUndo()
  }

  _flushUndoTimers() {
    if (this._undoTypingTimer || this._undoGestureTimer) this._commitUndo()
  }

  // A gesture that spans an await (creating a flow mints it, then fetches its
  // starter card) holds the stack open so both halves land in one entry.
  beginUndoGroup() {
    this._undoHold++
    clearTimeout(this._undoHoldTimer)
    this._undoHoldTimer = setTimeout(() => { this._undoHold = 0; this._releaseUndoGroup() }, UNDO_HOLD_MS)
  }

  endUndoGroup() {
    if (this._undoHold > 0) this._undoHold--
    if (this._undoHold > 0) return
    clearTimeout(this._undoHoldTimer)
    this._releaseUndoGroup()
  }

  _releaseUndoGroup() {
    if (!this._undoCommitWanted) return
    this._undoCommitWanted = false
    this._commitUndo()
  }

  _commitUndo() {
    clearTimeout(this._undoTypingTimer)
    clearTimeout(this._undoGestureTimer)
    this._undoTypingTimer = this._undoGestureTimer = null
    if (this._undoHold > 0) { this._undoCommitWanted = true; return }
    if (!this._undoBase || this._replaying) return
    const focus = this._captureFocus()
    const next  = this._snapshotDeck(this._undoBase)
    const entry = this._diffSnapshots(this._undoBase, next)
    this._undoBase = next
    this._undoTypingField = null
    if (!entry) return
    entry.focus = focus
    entry.chars = this._entryChars(entry)
    this._undoStack.push(entry)
    this._redoStack.length = 0
    this._trimUndo()
    this._refreshUndoButtons()
  }

  // ── Snapshots ─────────────────────────────────────────────────────────────
  // One serialize() per snapshot. A card whose JSON matches the base's keeps
  // the base's record, so only what changed is re-captured.
  _snapshotDeck(base = null) {
    const cards   = this.serialize().cards || []
    const order   = this.cardTargets.slice()
    const records = new Map()
    order.forEach((el, i) => {
      const json = JSON.stringify(cards[i] ?? null)
      const prev = base?.records.get(el)
      records.set(el, prev && prev.json === json ? prev : this._captureCardRecord(el, json))
    })
    return { order, records, flows: JSON.stringify(this.flowsList()),
             title: this.titleValue || "", theme: this.themeValue || "" }
  }

  _captureCardRecord(el, json) {
    const blocks = {}
    Object.entries(this._undoBlocksFor(el)).forEach(([ kind, live ]) => {
      blocks[kind] = live ? this._captureBlockHtml(live) : null
    })
    return { el, json, blocks, html: this._captureCardHtml(el),
             store: JSON.stringify(this._store.get(el) ?? null) }
  }

  // A card's three relocatable blocks, wherever each currently lives: the
  // panel's registry first (it moves them into the sidebar for the selected
  // card), the card itself for one never registered.
  _undoBlocksFor(el) {
    const panel = this._typePanel()
    return {
      quiz:  panel?.quizBlockFor(el)  || el.querySelector(".quiz-correct-block"),
      token: panel?.tokenBlockFor(el) || el.querySelector(".token-award-block"),
      logic: panel?.logicBlockFor(el) || el.querySelector(".logic-branch-block")
    }
  }

  // The card's markup without its blocks (captured separately, since they may
  // be elsewhere) and without the classes that only describe the screen.
  _captureCardHtml(el) {
    const clone = el.cloneNode(true)
    clone.querySelectorAll(UNDO_BLOCK_SELECTOR).forEach(b => b.remove())
    clone.classList.remove(...UNDO_PRESENTATION_CLASSES)
    this._syncFormState(clone)
    return clone.outerHTML
  }

  _captureBlockHtml(block) {
    const clone = block.cloneNode(true)
    this._syncFormState(clone)
    return clone.outerHTML
  }

  // cloneNode carries a control's live value, checkedness and selection, but
  // outerHTML writes attributes only — so write the live state into the
  // attributes the parsed markup will read back as defaults. Token amounts,
  // the token on/off box, the quiz selects and textareas all live in
  // properties rather than markup; the logic selects don't need this
  // (refreshLogicTargets rebuilds them from data-logic-selected on every
  // repaint), and syncing them anyway costs nothing.
  _syncFormState(root) {
    root.querySelectorAll("input").forEach(input => {
      const type = (input.type || "text").toLowerCase()
      if (type === "checkbox" || type === "radio") input.toggleAttribute("checked", input.checked)
      else if (![ "file", "button", "submit", "reset", "image" ].includes(type)) input.setAttribute("value", input.value)
    })
    root.querySelectorAll("textarea").forEach(ta => { ta.textContent = ta.value })
    root.querySelectorAll("option").forEach(opt => opt.toggleAttribute("selected", opt.selected))
  }

  // Null when nothing the deck persists differs — a markDirty from a select
  // that landed on the value it already had, a repaint, a selection.
  _diffSnapshots(a, b) {
    const changed = []
    new Set([ ...a.records.keys(), ...b.records.keys() ]).forEach(el => {
      const ra = a.records.get(el), rb = b.records.get(el)
      if (!ra || !rb || ra.json !== rb.json) changed.push(el)
    })
    const orderChanged = a.order.length !== b.order.length || a.order.some((el, i) => el !== b.order[i])
    const flowsChanged = a.flows !== b.flows
    const titleChanged = a.title !== b.title
    const themeChanged = a.theme !== b.theme
    if (!changed.length && !orderChanged && !flowsChanged && !titleChanged && !themeChanged) return null
    const side = (s) => ({
      order:   s.order,
      records: changed.map(el => s.records.get(el)).filter(Boolean),
      flows:   flowsChanged ? s.flows : null,
      title:   titleChanged ? s.title : null,
      theme:   themeChanged ? s.theme : null
    })
    return { before: side(a), after: side(b) }
  }

  _entryChars(entry) {
    const weigh = (r) => r.html.length + (r.store?.length || 0) +
      Object.values(r.blocks).reduce((n, h) => n + (h?.length || 0), 0)
    return [ ...entry.before.records, ...entry.after.records ].reduce((n, r) => n + weigh(r), 0)
  }

  _trimUndo() {
    while (this._undoStack.length > UNDO_MAX_ENTRIES) this._undoStack.shift()
    let chars = 0
    for (let i = this._undoStack.length - 1; i >= 0; i--) {
      chars += this._undoStack[i].chars || 0
      if (chars > UNDO_MAX_CHARS) { this._undoStack.splice(0, i + 1); break }
    }
    this._pruneStore()
  }

  // _store is a strong Map, so a card that left the deck lives on for as long
  // as its key does. Keep every element a snapshot still names (an undo may
  // put it back), drop the rest — which bounds the detached nodes retained.
  _pruneStore() {
    const keep = new Set(this._undoBase?.order || [])
    const note = (side) => { side.order.forEach(el => keep.add(el)); side.records.forEach(r => keep.add(r.el)) }
    this._undoStack.forEach(e => { note(e.before); note(e.after) })
    this._redoStack.forEach(e => { note(e.before); note(e.after) })
    for (const el of [ ...this._store.keys() ]) {
      if (!el.isConnected && !keep.has(el)) this._store.delete(el)
    }
  }

  // ── Restoring a side ──────────────────────────────────────────────────────
  _applySnapshotSide(side) {
    this._replaying = true
    try {
      if (side.flows != null) this._flows = JSON.parse(side.flows)
      if (side.title != null) this._restoreTitle(side.title)
      if (side.theme != null) this._restoreTheme(side.theme)
      const removed = this._reconcileOrder(side.order)
      side.records.forEach(r => this._restoreCardRecord(r))
      // A style popover open on a row that just changed under it would edit
      // a row the markup no longer has.
      this.application.getControllerForElementAndIdentifier(this.element, "option-style")?.close()
      this._typePanel()?.afterUndoRestore?.({ removed, changed: side.records.map(r => r.el) })
      this.refreshAll()
      // The base is what is on screen NOW, re-read rather than assumed, so a
      // capture that drifted from the restore shows up as a diff instead of
      // hiding until the next edit.
      this._undoBase = this._snapshotDeck(this._undoBase)
      this.markDirty() // the ordinary autosave persists the restore
    } finally {
      this._replaying = false
    }
  }

  // Put the slots in `order`, re-inserting the ones that had left the feed
  // (the same detached nodes, so everything keyed on them still holds) and
  // removing the ones that are not in it. Flow header/tab rows displaced on
  // the way are rebuilt wholesale by the refreshAll() that follows, exactly as
  // after any reorder.
  _reconcileOrder(order) {
    const feed = this.hasFeedTarget ? this.feedTarget : null
    if (!feed) return []
    const wanted  = new Set(order)
    const removed = []
    feed.querySelectorAll(":scope > .card-slot").forEach(slot => {
      const card = slot.querySelector("[data-survey-editor-target='card']")
      if (card && !wanted.has(card)) { removed.push(card); slot.remove() }
    })
    const nextSlot = (node) => {
      let n = node.nextElementSibling
      while (n && !n.classList.contains("card-slot")) n = n.nextElementSibling
      return n
    }
    let prev = null
    order.forEach(el => {
      let slot = el.closest(".card-slot")
      if (!slot) {
        slot = document.createElement("div")
        slot.className = "card-slot"
        slot.appendChild(el)
      }
      if (prev) {
        if (nextSlot(prev) !== slot) prev.after(slot)
      } else {
        const first = feed.querySelector(":scope > .card-slot")
        if (first !== slot) {
          if (first) first.before(slot)
          else {
            const ty = feed.querySelector("[data-gate-cards-target='tyCta']")
            if (ty) ty.before(slot)
            else feed.appendChild(slot)
          }
        }
      }
      prev = slot
    })
    return removed
  }

  _restoreCardRecord(r) {
    const el   = r.el
    const live = this._undoBlocksFor(el)
    // Lift the blocks out before the morph replaces the children, so the
    // elements the panel's registry holds survive it.
    const wasInside = {}
    Object.entries(live).forEach(([ kind, block ]) => {
      wasInside[kind] = !!block && el.contains(block)
      if (wasInside[kind]) block.remove()
    })
    this._morphElement(el, r.html)
    const bound = {}
    Object.entries(r.blocks).forEach(([ kind, html ]) => {
      let block = live[kind]
      if (html) {
        if (block) this._morphElement(block, html)
        else { block = this._parseElement(html); wasInside[kind] = true }
        if (wasInside[kind]) el.appendChild(block)
      } else if (block) {
        block.remove()
        block = null
      }
      bound[kind] = block
    })
    this._typePanel()?.bindBlocks?.(el, bound)
    const entry = r.store ? JSON.parse(r.store) : null
    if (entry) this._store.set(el, entry)
    else this._store.delete(el)
    // The html was captured under whichever language tab was open then; the
    // words shown now come from the store for the tab open now.
    if (entry) {
      const active = this._activeLocale, primary = this.defaultLocaleValue
      this._writeCard(el, entry[active], entry[primary], active)
    }
    el.classList.remove(...UNDO_PRESENTATION_CLASSES)
  }

  _parseElement(html) {
    const tpl = document.createElement("template")
    tpl.innerHTML = (html || "").trim()
    return tpl.content.firstElementChild
  }

  // The element keeps its identity; its attributes and children become the
  // markup's. Unchanged attributes are left alone so Stimulus sees no churn.
  _morphElement(el, html) {
    const src = this._parseElement(html)
    if (!src) return
    for (const name of el.getAttributeNames()) {
      if (!src.hasAttribute(name)) el.removeAttribute(name)
    }
    for (const { name, value } of [ ...src.attributes ]) {
      if (el.getAttribute(name) !== value) el.setAttribute(name, value)
    }
    el.replaceChildren(...src.childNodes)
  }

  _restoreTitle(title) {
    this.titleValue = title
    if (this.hasVertoTitleTarget) this.vertoTitleTarget.textContent = title
    const pill = this.element.querySelector("[data-mobile-studio-target='titleText']")
    if (pill) pill.textContent = title
  }

  _restoreTheme(theme) {
    this.themeValue = theme
    if (this.hasVertoThemeTarget) this.vertoThemeTarget.textContent = theme
    const pill = this.element.querySelector("[data-mobile-studio-target='themeText']")
    if (pill) pill.textContent = theme
  }

  // ── Caret ────────────────────────────────────────────────────────────────
  // Where the creator was when the entry closed — a field in a card, by
  // index, or the Verto's name — so undoing a run of typing puts them back
  // there. Fields outside the deck (the panel switches, modals) are not
  // recorded: an undo of a gesture leaves focus where it is.
  _captureFocus() {
    const ae = document.activeElement
    if (!(ae instanceof Element)) return null
    if (ae.closest("[data-survey-editor-target='vertoTitle'], [data-mobile-studio-target='titleText']")) return { title: true }
    if (ae.closest("[data-survey-editor-target='vertoTheme'], [data-mobile-studio-target='themeText']")) return { theme: true }
    const card = ae.closest("[data-survey-editor-target='card']")
    if (!card) return null
    const index = [ ...card.querySelectorAll(UNDO_FIELD_SELECTOR) ].indexOf(ae)
    return index < 0 ? null : { card, index }
  }

  _restoreFocus(focus) {
    if (!focus) return
    let field = null
    if (focus.title || focus.theme) {
      const pill = this.element.querySelector(focus.title ? "[data-mobile-studio-target='titleText']" : "[data-mobile-studio-target='themeText']")
      const desk = focus.title ? (this.hasVertoTitleTarget ? this.vertoTitleTarget : null)
                               : (this.hasVertoThemeTarget ? this.vertoThemeTarget : null)
      field = [ pill, desk ].find(f => f && f.offsetParent !== null) || null
    } else if (focus.card?.isConnected) {
      field = [ ...focus.card.querySelectorAll(UNDO_FIELD_SELECTOR) ][focus.index] || null
    }
    // A field inside a folded modal or a hidden flow: the undo is done, the
    // caret just has nowhere visible to go.
    if (!field || !field.isConnected || field.offsetParent === null) return
    try {
      field.focus({ preventScroll: true })
      if (field.isContentEditable) {
        const range = document.createRange()
        range.selectNodeContents(field)
        range.collapse(false)
        const sel = window.getSelection()
        sel.removeAllRanges()
        sel.addRange(range)
      } else if (typeof field.setSelectionRange === "function") {
        const n = field.value.length
        field.setSelectionRange(n, n)
      }
    } catch (_) { /* a number input refuses a selection range — fine */ }
  }

  // Shared tail: renumber, repaint and schedule the save that persists the undo.
  _renumberAndPersist() {
    this.refreshAll()
    this.markDirty()
  }

  // Puts a server-rendered card back at the end of the feed. Used by the
  // "Recently deleted" list, which restores across a reload — where the detached
  // node above is long gone and only the stored card JSON remains.
  spliceRestoredCard(html, cardJson = null) {
    const feed = this.hasFeedTarget ? this.feedTarget : null
    if (!feed) return null

    const tmp = document.createElement("div")
    tmp.innerHTML = (html || "").trim()
    const card = tmp.firstElementChild
    if (!card) return null

    // The server-rendered wrap carries its own CTA rail (Add question
    // included), so the slot needs nothing besides the card.
    const slot = document.createElement("div")
    slot.className = "card-slot"
    slot.appendChild(card)

    // Appended rather than put back at its old index: the deck has moved on
    // since, and guessing a position it no longer has would be worse than a
    // predictable landing spot the creator can drag from.
    const lastSlot = [ ...feed.querySelectorAll(".card-slot") ].pop()
    if (lastSlot) lastSlot.after(slot)
    else feed.appendChild(slot)

    // Restored cards keep their translations: without seeding, the next
    // autosave wrote the restored card back monolingual (the BUG-030 shape).
    this.seedCardStore(card, cardJson)
    // Every other insertion path registers the card's quiz/token/logic blocks
    // with type-panel; without this the restored card's token controls — kept
    // display:none while in-card — could never be relocated into the sidebar,
    // so they were unreachable and unreadable for good.
    this._typePanel()?.registerCard(card)
    this._renumberAndPersist()
    return card
  }

  // Best-effort synchronous-ish flush of a pending autosave. Small decks go by
  // fetch with keepalive, the only kind of request that survives the page
  // unload (sendBeacon can't send a PATCH with a CSRF header); decks past what
  // keepalive can carry take the slower path below. No-op when nothing is
  // pending or the Verto is live (the server rejects edits to a published
  // Verto anyway).
  flushSave(event) {
    if (!this._dirty || this.liveValue) return
    if (!this.hasUrlValue || !this.urlValue) return
    clearTimeout(this._saveTimer)

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const headers = {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": csrfToken
    }
    let body
    try {
      body = JSON.stringify(this.serialize())
    } catch (_) {
      return // can't build a payload — leave _dirty set so the debounce retries
    }

    // A keepalive request is the only kind that outlives the page, but the Fetch
    // spec caps its body at 64KB and the browser REJECTS anything larger — an
    // asynchronous rejection the old `try` around fetch() could never catch. It
    // had already set _dirty = false, so on a deck over that size every pending
    // edit was dropped on refresh with nothing on screen to say so. Measured: a
    // 32KB body sends, 63KB+ does not, and the quota is shared with any other
    // keepalive request still in flight — hence the conservative ceiling.
    if (new Blob([ body ]).size <= this.constructor.KEEPALIVE_MAX_BYTES) {
      this._dirty = false
      fetch(this.urlValue, { method: "PATCH", keepalive: true, headers, body })
        // Still possible: the shared quota was already spent. Put the flag back
        // so a later flush (tab-switch, or the next edit's debounce) retries.
        .catch(() => { this._dirty = true })
      return
    }

    // Too big to survive the page going away. Send it normally — it lands if the
    // browser sticks around long enough — and on an actual navigation ask first,
    // so a creator with a long or multilingual deck is given the second it needs
    // instead of silently losing the edit. Browsers ignore custom wording here,
    // so there is no string to translate.
    fetch(this.urlValue, { method: "PATCH", headers, body })
      .then(() => { this._dirty = false })
      .catch(() => { /* stays dirty; the next flush or edit retries */ })
    if (event?.type === "beforeunload") {
      event.preventDefault()
      event.returnValue = ""
    }
  }

  // A pending edit must land before any of the editor page's own forms
  // navigates it away (Turbo intercepts them, so the unload flush above never
  // runs). Fail-open on purpose: if the save errors the form still proceeds —
  // that is exactly today's behaviour — and _flushingSubmit lets the resubmit
  // pass straight through to Turbo instead of looping back in here.
  async _flushBeforeSubmit(event) {
    if (this._flushingSubmit) return
    if (!this._dirty || this.liveValue) return
    const form = event.target
    if (!(form instanceof HTMLFormElement) || !this.element.contains(form)) return
    event.preventDefault()
    event.stopPropagation()
    this._flushingSubmit = true
    clearTimeout(this._saveTimer)
    try {
      await this._doSave()
    } finally {
      form.requestSubmit(event.submitter || undefined)
      this._flushingSubmit = false
    }
  }

  // ── Language tabs ──────────────────────────────────────
  // The DOM shows one locale at a time; per-card, per-locale text lives in
  // _store (keyed by the card element so add/delete/reorder stay consistent).
  // Structural edits are locked to the primary tab (CSS hides their controls
  // under .editing-translation), so translations only ever change text.

  switchLocale(event) {
    const locale = event.currentTarget.dataset.locale
    if (!locale || locale === this._activeLocale) return
    // A run of typing under the old tab is its own entry, not part of
    // whatever is typed under the new one.
    this._flushUndoTimers()
    this._captureLocale(this._activeLocale)
    this._activeLocale = locale
    this._applyLocale(locale)
    if (this.hasTabTarget) {
      this.tabTargets.forEach(t => t.classList.toggle("is-active", t.dataset.locale === locale))
    }
    // Reflect the choice in the compact dropdown button.
    const btn = event.currentTarget
    if (this.hasLocaleCodeTarget && btn.dataset.code) this.localeCodeTarget.textContent = btn.dataset.code
    this.element.classList.toggle("editing-translation", locale !== this.defaultLocaleValue)
    if (this.hasFeedTarget) {
      this.feedTarget.setAttribute("dir", this.rtlLocalesValue.includes(locale) ? "rtl" : "ltr")
    }
    this.refreshAll()
  }

  // Per-locale "how to answer" captions (e.g. "Choose one"), keyed by locale
  // then card type — see application_helper.rb#card_eyebrows_i18n. Read once
  // at connect(); the blob is re-rendered by the server on every full page
  // load, same as _seedStore's source.
  _loadEyebrows() {
    try {
      return JSON.parse(document.getElementById("card-eyebrows-i18n")?.textContent || "{}")
    } catch (_) {
      return {}
    }
  }

  _seedStore() {
    this._store = new Map()
    let data = []
    try { data = JSON.parse(document.getElementById("survey-cards-i18n")?.textContent || "[]") } catch (_) {}
    const primary = this.defaultLocaleValue
    this.cardTargets.forEach((el, i) => {
      const c = data[i] || {}
      const entry = {}
      entry[primary] = this._normContent(c)
      const i18n = c.i18n || {}
      Object.keys(i18n).forEach(loc => { entry[loc] = this._normContent(i18n[loc]) })
      this._store.set(el, entry)
    })
  }

  _normContent(c) {
    c = c || {}
    return {
      text: c.text || "",
      description: c.description || "",
      options: Array.isArray(c.options) ? c.options.slice() : [],
      // Tap-card response labels, positional against the card's scale — the
      // words only; a response's key, colour and glyph are language-neutral.
      responses: Array.isArray(c.responses) ? c.responses.slice() : [],
      pages: Array.isArray(c.pages) ? c.pages.map(p => ({ id: p?.id || "", text: p?.text || "", html: p?.html || null })) : [],
      // The intro modal's words, translated per language like everything else
      // here — a Spanish respondent meets a Spanish modal.
      modal_title: c.modal_title || "",
      modal_body: c.modal_body || "",
      // The anchor lines beside an NPS scale's ends — respondent-facing words,
      // translated per language like the rest.
      nps_low_label: c.nps_low_label || "",
      nps_high_label: c.nps_high_label || "",
      // Rich-text layer — meaningful on the PRIMARY entry only (translations
      // are plain by design; the server strips any html they might carry).
      text_html: c.text_html || null,
      description_html: c.description_html || null,
      modal_body_html: c.modal_body_html || null,
      options_html: Array.isArray(c.options_html) ? c.options_html.slice() : []
    }
  }

  // Option-label elements for a card, by type — the same nodes serialize reads.
  _optionEls(cardEl) {
    const sel = OPTION_LABEL_SELECTORS[cardEl.dataset.cardType]
    return sel ? Array.from(cardEl.querySelectorAll(sel)) : []
  }

  // A tap card's response labels. Kept out of OPTION_LABEL_SELECTORS on
  // purpose: that table maps a type to its OPTIONS, and a tap card's options
  // are its statements. The responses are a second, independent list on the
  // same card, and conflating them would have the statements overwritten by
  // the answer scale on every language switch.
  _responseLabelEls(cardEl) {
    return Array.from(cardEl.querySelectorAll("[data-tap-response-label]"))
  }

  // Scenario narrative-page text elements, excluding the answer page (whose
  // options are read by _optionEls above) — id comes from the owning
  // .book-page, not the text node itself.
  _pageEls(cardEl) {
    return Array.from(cardEl.querySelectorAll(".book-page:not(.is-answer) .book-page-text"))
  }

  _readCard(cardEl) {
    const titleEl = cardEl.querySelector(".q-title, .activity-title")
    const descEl  = cardEl.querySelector(".q-subtitle, .activity-desc")
    const optEls  = this._optionEls(cardEl)
    return {
      // innerText, NOT textContent, for the two fields a creator writes
      // paragraphs into. Enter in a contenteditable wraps each line in a
      // <div>, and textContent joins block boundaries with NOTHING — a
      // welcome card written as three paragraphs came back from reload as
      // one lump ("ideally need it to remember the spacing/line breaks",
      // Feedback 17). innerText yields \n at those boundaries, the stored
      // text keeps it, and white-space: pre-line on .q-title/.q-subtitle
      // renders it — a stable round-trip, because _writeCard's textContent
      // write puts the \n straight back and innerText re-reads it.
      // Options and response labels stay on textContent on purpose: they are
      // single-line by design and a stray Enter should not become a break.
      text: this._readPlain(titleEl),
      description: this._readPlain(descEl),
      options: optEls.map(el => el.textContent.trim()),
      responses: this._responseLabelEls(cardEl).map(el => el.textContent.trim()),
      pages: this._pageEls(cardEl).map(el => ({
        id: el.closest(".book-page")?.dataset.pageId || "",
        text: el.textContent.trim(),
        html: this._readHtml(el)
      })),
      // The intro modal's words. innerText for the body for the same reason
      // the question uses it — a creator writes paragraphs into it and the
      // line breaks have to survive the round trip. The title is one line, so
      // textContent, like an option label.
      modal_title: this._modalTitleEl(cardEl)?.textContent.trim() || "",
      modal_body: this._readPlain(this._modalBodyEl(cardEl)),
      // The NPS anchor lines: one line each, like an option label.
      nps_low_label: this._npsAnchorEl(cardEl, "low")?.textContent.trim() || "",
      nps_high_label: this._npsAnchorEl(cardEl, "high")?.textContent.trim() || "",
      text_html: this._readHtml(titleEl),
      description_html: this._readHtml(descEl),
      modal_body_html: this._readHtml(this._modalBodyEl(cardEl)),
      options_html: optEls.map(el => this._readHtml(el))
    }
  }

  // The modal's two editable nodes. Scoped to THIS card's own modal layer:
  // every card in the feed carries one, so an unscoped query would read the
  // first card's modal onto every card in the deck.
  _modalLayer(cardEl)   { return cardEl.querySelector("[data-role='card-modal']") }
  _modalTitleEl(cardEl) { return cardEl.querySelector("[data-role='card-modal-title']") }
  _modalBodyEl(cardEl)  { return cardEl.querySelector("[data-role='card-modal-body']") }
  // The anchor line beside one end of an NPS scale (`low` / `high`) — the
  // sibling column beside the digits, never one of the digits themselves.
  _npsAnchorEl(cardEl, which) { return cardEl.querySelector(`[data-role='nps-anchor-${which}']`) }

  // Line-break-preserving plain text. trim() only cuts the ends; interior
  // newlines survive. The collapse handles how engines count an EMPTY line:
  // <div><br></div> contributes the block boundary's newline AND the <br>'s,
  // so one blank line read back as two. Two newlines — one blank line — is
  // what the creator saw; runs beyond that are the double-count, not intent.
  _readPlain(el) {
    return (el?.innerText || "").replace(/\n{3,}/g, "\n\n").trim()
  }

  // The rich-text layer of an editable region — innerHTML, but ONLY when
  // formatting elements are actually present, so a deck nobody has formatted
  // reads (and therefore serialises) byte-identically to the plain-text era.
  //
  // The div normalisation is the formatted half of the line-break fix above:
  // when a creator bolds a word AND breaks lines, this layer engages, and the
  // sanitiser strips <div> (not in the allowlist) while KEEPING its content —
  // which joins the lines exactly like textContent did. <br> is allowed, so
  // block boundaries become <br> before storing. A leading <div> is the first
  // line rather than a break, hence the strip of one leading <br>; trailing
  // empty divs would render as blank lines the plain layer trims, hence the
  // trailing strip.
  _readHtml(el) {
    if (!el || !hasFormatting(el)) return null
    return el.innerHTML
      .replace(/<div[^>]*>/gi, "<br>")
      .replace(/<\/div>/gi, "")
      .replace(/^<br>/i, "")
      .replace(/(<br>)+$/i, "")
  }

  _writeCard(cardEl, content, fallback, locale) {
    content = content || {}; fallback = fallback || {}
    // Switching back to the primary tab must restore the rich-text layer —
    // writing textContent here (as translations do) would flatten the
    // formatting in the DOM, and the next autosave would then persist the
    // loss. The html is our own previously-captured markup, not user input
    // from this call site.
    const primary = locale === this.defaultLocaleValue
    const write = (el, html, text) => {
      if (primary && html) el.innerHTML = html
      else el.textContent = text
    }
    const titleEl = cardEl.querySelector(".q-title, .activity-title")
    if (titleEl) write(titleEl, content.text_html, content.text || fallback.text || titleEl.textContent)
    const descEl = cardEl.querySelector(".q-subtitle, .activity-desc")
    if (descEl) write(descEl, content.description_html, content.description || fallback.description || "")
    // The intro modal. Blank rather than falling back to the primary wording:
    // every other field here falls back because the player renders the primary
    // for an untranslated field, and so does this one — but an empty node is
    // what makes the placeholder show, which is the editor's own way of saying
    // "this language has no words for this yet". The stored primary is
    // untouched either way; serialize() only writes a translation it was given.
    const modalTitleEl = this._modalTitleEl(cardEl)
    if (modalTitleEl) modalTitleEl.textContent = content.modal_title || ""
    const modalBodyEl = this._modalBodyEl(cardEl)
    if (modalBodyEl) write(modalBodyEl, content.modal_body_html, content.modal_body || "")
    // The NPS anchor lines. Blank rather than falling back, for the modal's
    // reason: an empty node shows the placeholder, which is the editor's way
    // of saying this language has no words for it yet.
    for (const which of [ "low", "high" ]) {
      const el = this._npsAnchorEl(cardEl, which)
      if (el) el.textContent = content[`nps_${which}_label`] || ""
    }
    const opts = content.options || [], fopts = fallback.options || []
    const optsHtml = content.options_html || []
    this._optionEls(cardEl).forEach((el, k) => {
      write(el, optsHtml[k], (opts[k] && opts[k].trim()) || fopts[k] || el.textContent)
    })
    // Response labels, positional against the scale, same fall-back-per-slot
    // rule as options. Always plain: a response label has no rich-text layer.
    const resps = content.responses || [], fresps = fallback.responses || []
    this._responseLabelEls(cardEl).forEach((el, k) => {
      el.textContent = (resps[k] && resps[k].trim()) || fresps[k] || el.textContent
    })
    // Pages align by id (not index) — a creator plausibly reorders narrative
    // pages after translating them, unlike options.
    const pages = content.pages || [], fpages = fallback.pages || []
    this._pageEls(cardEl).forEach(el => {
      const id = el.closest(".book-page")?.dataset.pageId || ""
      const tr = pages.find(p => p.id && p.id === id)
      const fb = fpages.find(p => p.id && p.id === id)
      if (primary && tr && tr.html) el.innerHTML = tr.html
      else el.textContent = (tr && tr.text.trim()) || (fb && fb.text) || el.textContent
    })
    // The "how to answer" caption isn't authored text (it's derived from the
    // card's type), so it isn't in the i18n store above — look it up straight
    // from the eyebrows blob for the locale being shown.
    const eyebrowEl = cardEl.querySelector(".q-eyebrow")
    if (eyebrowEl && locale) {
      const caption = cardEyebrow(this._eyebrows, locale, cardEl.dataset.cardType,
                                  cardEl.dataset.cardMaxChoices)
      if (caption) eyebrowEl.textContent = caption
    }
    this.refreshCard(cardEl)
  }

  _captureLocale(locale) {
    this.cardTargets.forEach(el => {
      const entry = this._store.get(el) || {}
      entry[locale] = this._readCard(el)
      this._store.set(el, entry)
    })
  }

  _applyLocale(locale) {
    const primary = this.defaultLocaleValue
    this.cardTargets.forEach(el => {
      const entry = this._store.get(el) || {}
      this._writeCard(el, entry[locale], entry[primary], locale)
    })
  }

  // ── Rules of the Game — the live traffic-light analysis ──────────────────
  // Repaint every card's light plus the overall Verto score. Cheap enough
  // (~16 cards) to run wholesale on structural changes and locale switches.
  refreshAll() {
    this.renumberCards()
    this.cardTargets.forEach(c => this.refreshCard(c))
    this.refreshScore()
    // Let passive listeners (the Flows panel) repaint from the fresh state.
    // Render-only on their side — never mutate/markDirty from this event.
    this.dispatch("refreshed")
  }

  // ── Reorder ──────────────────────────────────────────────────────────────
  // Move a question up/down by swapping its slot with the neighbouring one. The
  // welcome card stays pinned first. No server call needed: autosave serialises
  // cards in document order, so reordering the DOM reorders the saved deck.

  moveCardUp(event) {
    event.stopPropagation()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const slot = card?.closest(".card-slot")
    const hit = this._reorderNeighbor(card, slot, -1)
    const prevCard = hit?.slot.querySelector("[data-survey-editor-target='card']")
    // The welcome card is pinned first — EXCEPT against a consent gate, which
    // may sit either side of it ("Hello → consent" or "consent → Hello" are
    // both legitimate). The ordering was already reachable by pressing ▼ on
    // the welcome card, but the gate's own ▲ sat greyed with no hint that the
    // other gesture existed — a feature half of its users would call missing.
    const pinned = prevCard?.dataset.cardType === "welcome_card" &&
                   card?.dataset.cardType !== "consent_gate"
    if (!slot || !hit || !prevCard || pinned) return
    if (hit.hopped) hit.slot.after(slot)   // hopped a flow run ⇒ land just after it
    else hit.slot.before(slot)
    this._afterReorder(card)
  }

  // The server hoists a consent gate back ahead of the first question on every
  // save (Survey.hoist_consent_gate), so letting the gate move down past a
  // question here would show the creator an order the save silently reverts.
  _gateBlockedBelow(card, hit) {
    if (card?.dataset.cardType !== "consent_gate") return false
    const nextCard = hit?.slot.querySelector("[data-survey-editor-target='card']")
    return !!nextCard && !NON_QUESTION_TYPES.includes(nextCard.dataset.cardType)
  }

  moveCardDown(event) {
    event.stopPropagation()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const slot = card?.closest(".card-slot")
    const hit = this._reorderNeighbor(card, slot, 1)
    if (!slot || !hit) return
    if (this._gateBlockedBelow(card, hit)) return
    if (hit.hopped) hit.slot.before(slot)  // hopped a flow run ⇒ land just before it
    else hit.slot.after(slot)
    this._afterReorder(card)
  }

  // The slot a reorder should swap with, respecting flows: a flow member only
  // reorders WITHIN its flow (order inside a flow is meaning — the compiled
  // chain — so it never drifts out by nudging), and a spine card hops a whole
  // flow run as one unit instead of burrowing into it. Walks over the flow
  // painter's header/cluster chrome. Returns { slot, hopped } or null at a
  // boundary; `hopped` = flow-member slots were skipped on the way.
  _reorderNeighbor(card, slot, dir) {
    if (!card || !slot) return null
    const moverFlow = card.dataset.cardFlowId || null
    let el = dir < 0 ? slot.previousElementSibling : slot.nextElementSibling
    let hopped = false
    while (el) {
      if (el.classList.contains("card-slot")) {
        const otherFlow = el.querySelector("[data-survey-editor-target='card']")?.dataset.cardFlowId || null
        if (moverFlow) return otherFlow === moverFlow ? { slot: el, hopped: false } : null
        if (!otherFlow) return { slot: el, hopped }
        hopped = true // spine mover: skip the flow run and keep walking
      }
      el = dir < 0 ? el.previousElementSibling : el.nextElementSibling
    }
    return null
  }

  _afterReorder(card) {
    this.renumberCards()
    this.markDirty() // repaints the score + schedules the autosave that persists order
    card.scrollIntoView({ behavior: "smooth", block: "nearest" })
    card.classList.remove("card-flash")
    void card.offsetWidth // restart the pulse so the move reads as a move
    card.classList.add("card-flash")
    setTimeout(() => card.classList.remove("card-flash"), 1300)
  }

  // ── Drag-and-drop reorder ─────────────────────────────────────────────────
  // Native HTML5 drag events, not a package — SortableJS (or similar) has no
  // idea about the invariants below and would happily drop a flow member
  // outside its flow, or a question ahead of the welcome card. Touch keeps
  // ▲/▼: native drag doesn't reach touch devices without a polyfill this
  // deck doesn't carry.

  // The full set of legal drop gaps for `card` (currently at `slot`) — the
  // SAME rules moveCardUp/moveCardDown already enforce one step at a time
  // (flow membership via _reorderNeighbor's own walk, welcome pinned first,
  // a gate never ends up below a question), generalised from "how far can one
  // ▲/▼ press move it" to "everywhere a drag could legally drop it". Walks
  // outward in both directions, reusing _reorderNeighbor iteratively — it
  // only ever reads `slot`'s siblings, so feeding it each hit's own slot
  // continues the same walk further out — until a boundary invariant stops
  // it, which is also the exact point no FURTHER gap in that direction could
  // be legal either (the boundary only gets closer, never further away), so
  // it's safe to stop collecting there rather than merely skip one.
  //
  // Returns [{ ref, dir, hopped }]: dir<0 entries came from walking up
  // (earlier in the doc), dir>0 from walking down; `ref` + `hopped` are
  // exactly what moveCardUp/moveCardDown already key their own before/after
  // placement off (see _applyGap).
  _legalGapsFor(card, slot) {
    const type = card.dataset.cardType
    const gaps = []
    for (const dir of [ -1, 1 ]) {
      let cursor = slot
      let hit = this._reorderNeighbor(card, cursor, dir)
      while (hit) {
        const targetType = hit.slot.querySelector("[data-survey-editor-target='card']")?.dataset.cardType
        // Mirrors moveCardUp's inline pin check: nothing but a consent gate
        // may land at or ahead of the welcome card.
        if (targetType === "welcome_card" && type !== "consent_gate") break
        // Mirrors _gateBlockedBelow: a gate can walk down only as far as the
        // last card still ahead of every question.
        if (dir > 0 && this._gateBlockedBelow(card, hit)) break
        gaps.push({ ref: hit.slot, dir, hopped: hit.hopped })
        cursor = hit.slot
        hit = this._reorderNeighbor(card, cursor, dir)
      }
    }
    return gaps
  }

  // The same before/after choice moveCardUp/moveCardDown already make from
  // { dir, hopped }: lands BEFORE ref moving up without a hop, or moving down
  // WITH one — a hop always lands on the near side of whatever run it
  // jumped, which flips which edge counts as "near" per direction.
  _applyGap(slot, gap) {
    const landsBefore = (gap.dir < 0) !== gap.hopped
    if (landsBefore) gap.ref.before(slot)
    else gap.ref.after(slot)
  }

  dragStart(event) {
    event.stopPropagation()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const slot = card?.closest(".card-slot")
    if (!card || !slot) { event.preventDefault(); return }

    this._dragCard  = card
    this._dragSlot  = slot
    this._dragGaps  = this._legalGapsFor(card, slot)
    this._dragMoved = false

    event.dataTransfer.effectAllowed = "move"
    // Some engines refuse to start a drag at all with no data set.
    event.dataTransfer.setData("text/plain", card.dataset.cardCid || "")

    slot.classList.add("is-dragging")
    this._dragGaps.forEach(g => g.ref.classList.add("is-drop-target"))
  }

  // Delegated on the feed (data-survey-editor-target="feed"), not per-slot:
  // one listener has to answer for wherever the pointer currently is.
  dragOver(event) {
    if (!this._dragSlot) return
    const slot = event.target.closest?.(".card-slot")
    const gap  = slot && this._dragGaps.find(g => g.ref === slot)
    if (!gap) return
    event.preventDefault() // only ever allowed over a legal gap — see above
    event.dataTransfer.dropEffect = "move"
    if (this._dragHoverSlot !== slot) {
      this._dragHoverSlot?.classList.remove("is-drop-here-before", "is-drop-here-after")
      const before = (gap.dir < 0) !== gap.hopped
      slot.classList.add(before ? "is-drop-here-before" : "is-drop-here-after")
      this._dragHoverSlot = slot
    }
  }

  drop(event) {
    if (!this._dragSlot) return
    event.preventDefault()
    const slot = event.target.closest?.(".card-slot")
    const gap  = slot && this._dragGaps.find(g => g.ref === slot)
    if (!gap) return
    this._applyGap(this._dragSlot, gap)
    this._dragMoved = true
  }

  // Fires on the drag SOURCE (the grip) whether the drop landed or was
  // cancelled, so this — not drop — is the one place cleanup belongs. The
  // markDirty inside _afterReorder is what makes the whole gesture one undo
  // entry: dragOver only paints, drop moves the slot once.
  dragEnd() {
    if (this._dragMoved) this._afterReorder(this._dragCard)
    this._dragGaps?.forEach(g => g.ref.classList.remove("is-drop-target"))
    this._dragHoverSlot?.classList.remove("is-drop-here-before", "is-drop-here-after")
    this._dragSlot?.classList.remove("is-dragging")
    this._dragCard = this._dragSlot = this._dragGaps = this._dragHoverSlot = null
    this._dragMoved = false
  }

  // Re-stamp each card's number, progress bar and reorder-button state after a
  // structural change (insert / delete / reorder), so the "Card N" labels and
  // the data-card-num the score board jumps by stay consistent with the DOM.
  renumberCards() {
    const cards  = this.cardTargets
    const totalQ = cards.filter(c => !NON_QUESTION_TYPES.includes(c.dataset.cardType)).length
    let qIdx = 0
    cards.forEach((card, i) => {
      const num = i + 1
      card.dataset.cardNum = String(num)
      // Number only — the "Card" word is a separate .rail-label span in the
      // pill, hidden when the rail collapses to a numbered circle.
      const numEl = card.querySelector("[data-role='card-number']")
      if (numEl) numEl.textContent = String(num)

      const isQ = !NON_QUESTION_TYPES.includes(card.dataset.cardType)
      if (isQ) qIdx++
      const pct  = isQ && totalQ > 0 ? Math.round((qIdx / totalQ) * 100) : 5
      const fill = card.querySelector(".panel-progress-fill")
      if (fill) fill.style.width = `${pct}%`
    })
    this._updateMoveButtonStates(cards)
    // Keep every route dropdown's target list in sync with the current deck.
    this.refreshLogicTargets()
    // …and the flow rails/headers in step with membership + order.
    this._paintFlowChrome()
  }

  // Disable "up" on the first movable card (and any card sitting just below the
  // welcome card) and "down" on the last, so the boundaries are obvious.
  _updateMoveButtonStates(cards) {
    cards.forEach(card => {
      const slot = card.closest(".card-slot")
      const up   = card.querySelector("[data-role='move-up']")
      const down = card.querySelector("[data-role='move-down']")
      if (up) {
        const prevCard = this._reorderNeighbor(card, slot, -1)?.slot
          .querySelector("[data-survey-editor-target='card']")
        // Mirror of moveCardUp's pin rule: a consent gate may hop the welcome.
        up.disabled = !prevCard ||
          (prevCard.dataset.cardType === "welcome_card" && card.dataset.cardType !== "consent_gate")
      }
      if (down) {
        const hit = this._reorderNeighbor(card, slot, 1)
        down.disabled = !hit || this._gateBlockedBelow(card, hit)
      }
    })
  }

  // The card object the analyzer scores: the text/options currently on screen
  // (so the score reflects the locale being edited) plus the Other toggle,
  // which counts toward a grid's even/≤10 rule.
  _cardData(cardEl) {
    const c = this._readCard(cardEl)
    return {
      type: cardEl.dataset.cardType,
      text: c.text,
      description: c.description,
      options: c.options,
      pages: c.pages,
      allowOther: cardEl.dataset.cardAllowOther === "true",
      // Read by analyzeVerto's code_after_ask_once check. Without this line
      // that check is dead code that always passes.
      askOnce: cardEl.dataset.cardAskOnce === "true",
      // Read by analyzeCard's capped-quiz check — a cap below the number of
      // correct answers makes a graded card impossible to get right. Counted
      // only on a QUIZ: a deck that has quiz turned off can still be carrying
      // `correct` marks from when it was on, and nothing grades them, so the
      // trap the check describes doesn't exist there.
      maxChoices: parseInt(cardEl.dataset.cardMaxChoices, 10) || 0,
      correctCount: this.quizValue
        ? cardEl.querySelectorAll('[data-picker-target="item"][data-correct="true"]').length
        : 0,
      // Demographic cards are exempt from the option-shape rules (their
      // option lists are platform-set taxonomies) — see verto_rules.js.
      demographic: cardEl.dataset.cardDemographic === "true",
      // An NPS scored against "exactly 11" is right until the creator has
      // deliberately turned the classic 0-10 off — after which the rule is
      // marking them down for the choice the switch exists to offer. Same
      // three-state read as everywhere else: the flag when it is there, the
      // labels when it isn't.
      npsCustomScale: cardEl.dataset.cardType === "nps" &&
        npsCustomScale(c.options, cardEl.dataset.cardNpsCustomScale)
    }
  }

  refreshCard(card) {
    // Before the traffic-light early-return below: the folded modal bar exists
    // on every card type, including the ones that carry no light at all.
    this._paintCardModalLabel(card)
    const light = card.querySelector("[data-role='card-light']")
    if (!light) {
      // Not a scored question (welcome/token-checkpoint) — hide the pinned
      // sidebar mirror if this is the card currently open in the panel.
      if (this.hasPanelLightTarget && this._typePanelActiveCard() === card) this.panelLightTarget.hidden = true
      return
    }
    this._paintCardLight(card, analyzeCard(this._cardData(card)))
  }

  _paintCardLight(card, result) {
    if (!result) return
    const light = card.querySelector("[data-role='card-light']")
    if (light) this._applyLightVisuals(light, result)

    // Mirror onto the pinned sidebar light so the score stays visible
    // whichever sub-tab (Question type / Tokenomics / Quiz mode) is open.
    if (this.hasPanelLightTarget && this._typePanelActiveCard() === card) {
      this._applyLightVisuals(this.panelLightTarget, result)
    }

    const panel = card.querySelector("[data-role='card-analysis']")
    if (panel) panel.innerHTML = this._panelHtml(t("editor.rules.title"), result.checks)
  }

  _applyLightVisuals(light, result) {
    light.hidden = false
    // classList (not className) so each element's own base classes — plain
    // .card-light inline, .card-light.panel-card-light pinned — survive.
    light.classList.remove("is-green", "is-yellow", "is-red")
    light.classList.add(`is-${result.rating}`)
    light.setAttribute("title", t("editor.rules.card_aria"))
    const word = light.querySelector("[data-role='card-light-word']")
    const score = light.querySelector("[data-role='card-light-score']")
    if (word) word.textContent = this._ratingWord(result.rating)
    if (score) score.textContent = result.score
  }

  // The card currently open in the right-hand panel (type-panel controller),
  // if any — shared root element, so we can reach across controllers.
  _typePanelActiveCard() {
    return this._typePanel()?.activeCardEl || null
  }

  _typePanel() {
    return this.application.getControllerForElementAndIdentifier(this.element, "type-panel")
  }

  // Clicking the pinned sidebar light jumps to the card's own analysis
  // breakdown in the feed (the pinned light has no room for the checklist).
  togglePanelCardAnalysis(event) {
    const card = this._typePanelActiveCard()
    const panel = card?.querySelector("[data-role='card-analysis']")
    if (!panel) return
    const open = panel.hidden
    panel.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
    if (open) card.scrollIntoView({ behavior: "smooth", block: "center" })
  }

  refreshScore() {
    if (!this.hasVertoScoreTarget) return
    // Score cards carry their wiring too (cid / routes / next / flow_id), so
    // a branched Verto is judged on the longest respondent path and per-flow
    // variety instead of the flat deck — see analyzeVerto. The compile pass
    // keeps member `next` chains current even before the next autosave.
    const cardData = this.cardTargets.map(el => {
      const d = this._cardData(el)
      if (el.dataset.cardCid) d.cid = el.dataset.cardCid
      if (el.dataset.cardFlowId && this.flowById(el.dataset.cardFlowId)) d.flow_id = el.dataset.cardFlowId
      try {
        const nx = el.dataset.cardNext ? JSON.parse(el.dataset.cardNext) : null
        if (nx && (nx.card || nx.end)) d.next = nx
      } catch (_) { /* malformed — score as unwired */ }
      if (this.logicValue) {
        const logic = this._readLogic(el, el.dataset.cardType)
        if (this._hasLogic(logic)) d.logic = logic
      }
      return d
    })
    this._compileFlows(cardData)
    const result = analyzeVerto(cardData, { flows: this.flowsList() })

    // Paint the score tab. Use classList (not className) so the tab's own
    // classes — right-tab, verto-score, is-active — survive the repaint.
    const el = this.vertoScoreTarget
    el.classList.remove("is-green", "is-yellow", "is-red")
    el.classList.add(`is-${result.rating}`)
    const num  = el.querySelector("[data-role='verto-score-num']")
    const word = el.querySelector("[data-role='verto-score-word']")
    if (num)  num.textContent  = result.score
    if (word) word.textContent = this._ratingWord(result.rating)

    if (this.hasScoreBoardTarget) this._renderScoreBoard(result, cardData)
  }

  // Group every result into the red / amber / green sections of the score tab.
  // Whole-Verto checks ride along under a "Whole Verto" label; each card lands
  // in its own section carrying the checks that still need work.
  _renderScoreBoard(verto, cardData) {
    const board = { red: [], yellow: [], green: [] }
    // INFO is a non-scoring tip — surface it among the "could improve" items.
    const bucket = (rating) => board[rating === "info" ? "yellow" : rating]

    verto.checks.forEach(c => bucket(c.rating).push({ verto: true, text: c.text }))

    this.cardTargets.forEach((cardEl, i) => {
      const result = analyzeCard(cardData[i])
      if (!result) return // welcome cards aren't questions, so they aren't scored
      bucket(result.rating).push({
        verto: false,
        num: cardEl.dataset.cardNum,
        type: cardData[i].type,
        fixes: result.checks.filter(c => c.rating !== "green").map(c => c.text)
      })
    })

    this.scoreBoardTarget.innerHTML = ["red", "yellow", "green"]
      .map(rating => this._sectionHtml(rating, board[rating])).join("")
  }

  _sectionHtml(rating, items) {
    const head =
      `<div class="score-section-head"><span class="rule-dot"></span>` +
      `<span>${this._esc(this._ratingWord(rating))}</span>` +
      `<span class="score-count">${items.length}</span></div>`
    const body = items.length
      ? `<div class="score-rows">${items.map(it => this._scoreRowHtml(it)).join("")}</div>`
      : `<div class="score-empty">${this._esc(t("editor.rules.section_empty"))}</div>`
    return `<div class="score-section is-${rating}">${head}${body}</div>`
  }

  _scoreRowHtml(it) {
    if (it.verto) {
      return `<div class="score-row score-row-verto">` +
        `<div class="score-row-card">${this._esc(t("editor.rules.whole_verto"))}</div>` +
        `<div class="score-fix">${this._esc(it.text)}</div></div>`
    }
    const label = this._esc(`${t("editor.rules.card_n", { n: it.num })} · ${typeLabel(it.type)}`)
    const fixes = it.fixes.map(f => `<div class="score-fix">${this._esc(f)}</div>`).join("")
    const jump = `<button type="button" class="score-row-main" data-card-num="${this._esc(it.num)}" ` +
      `data-action="click->survey-editor#jumpToCard">` +
      `<div class="score-row-card">${label}</div>${fixes}</button>`
    // "Optimise" — an AI fix for the listed issues. Only on cards that have
    // fixes, and never while the Verto is live (editing is locked).
    const optimise = (it.fixes.length && this.optimiseUrlValue && !this.liveValue)
      ? `<button type="button" class="score-optimise-btn" data-card-num="${this._esc(it.num)}" ` +
        `data-issues="${this._esc(JSON.stringify(it.fixes))}" ` +
        `data-action="click->survey-editor#optimiseCard">✨ ${this._esc(t("editor.optimise"))}</button>`
      : ""
    return `<div class="score-row score-row-actionable">${jump}${optimise}</div>`
  }

  // AI-fix the issues on one card: send its current content + the flagged
  // issues, swap in the optimised version the server renders, and re-score.
  async optimiseCard(event) {
    event.stopPropagation()
    const btn  = event.currentTarget
    const num  = btn.dataset.cardNum
    const card = this.cardTargets.find(c => c.dataset.cardNum === num)
    if (!card || !this.optimiseUrlValue) return

    const idx = this.cardTargets.indexOf(card)
    let issues = []
    try { issues = JSON.parse(btn.dataset.issues || "[]") } catch (_) { /* none */ }

    btn.disabled = true
    const original = btn.textContent
    btn.textContent = t("editor.optimising")
    card.classList.add("card-optimising")

    try {
      const res = await fetch(this.optimiseUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": this._csrf() },
        // The card's FULL current JSON, not just its readable content.
        //
        // This used to send `{ type, ...this._readCard(card) }` — five keys:
        // type, text, description, options, pages. The server merges the AI's
        // rewrite ONTO whatever it is given and re-renders from the result, so
        // every key absent from the payload was absent from the card
        // afterwards: its cid (which other cards' logic routes point AT), its
        // image, required flag, logic routes, flow membership, Common Question
        // provenance, quiz correct answers and token values — eleven fields,
        // gone on one click of ✨ Optimise.
        //
        // serialize().cards[idx] is the same idiom flows#duplicateCard uses to
        // get one card's complete object.
        body: JSON.stringify({
          index:  idx,
          issues: issues,
          card:   this.serialize().cards[idx] || { type: card.dataset.cardType, ...this._readCard(card) }
        })
      })
      const json = await res.json()
      if (!json.ok) throw new Error(json.error || t("editor.optimise_failed"))
      this._replaceCard(card, json.html, json.card)
    } catch (err) {
      // Surface the failure where the click happened — a silent no-move reads
      // like a broken button — and keep the detail in the status flash.
      card.classList.remove("card-optimising")
      btn.disabled = false
      btn.textContent = original
      btn.classList.add("is-error")
      setTimeout(() => btn.classList.remove("is-error"), 2600)
      this.flash(t("editor.optimise_failed", { msg: err.message }), "text-hot-pink")
    }
  }

  // Replace a card element with freshly rendered HTML and reseed its store entry
  // (so language tabs + autosave keep its translations), then re-score + save.
  // Teach the translation store about a card that arrived after connect().
  //
  // _seedStore() reads a JSON blob rendered into the page, so it only ever
  // knows the deck as it was at page load. A card added afterwards — generated,
  // spliced into a flow — carries per-locale text the server has already paid
  // Claude for, and without this the store never learned about it: the next
  // autosave captured only the language on screen and wrote the card back
  // monolingual, silently discarding the rest.
  seedCardStore(el, cardJson) {
    if (!el || !cardJson) return

    const entry = {}
    entry[this.defaultLocaleValue] = this._normContent(cardJson)
    const i18n = cardJson.i18n || {}
    Object.keys(i18n).forEach(loc => { entry[loc] = this._normContent(i18n[loc]) })
    this._store.set(el, entry)

    // If a translation tab is open, show that language on the new card rather
    // than leaving the primary sitting under the wrong tab.
    if (this._activeLocale !== this.defaultLocaleValue) {
      this._writeCard(el, entry[this._activeLocale], entry[this.defaultLocaleValue], this._activeLocale)
    }
  }

  //
  // Morphed in place rather than swapped: the element is what _store, the
  // type panel's block registry, its activeCardEl and the undo snapshots all
  // hold, so it stays and only its attributes and children change. (The swap
  // used to leave activeCardEl pointing at the detached node, with the card's
  // sidebar blocks parked for good.) The rendered html brings fresh
  // quiz/token/logic blocks, so the ones bound before it — wherever the panel
  // had relocated them — go.
  _replaceCard(oldEl, html, cardJson) {
    if (!this._parseElement(html)) return

    const panel = this._typePanel()
    Object.values(this._undoBlocksFor(oldEl)).forEach(block => {
      if (block && !oldEl.contains(block)) block.remove()
    })
    this._morphElement(oldEl, html)
    panel?.rebindCard?.(oldEl)
    if (panel?.activeCardEl === oldEl) panel.reselectCard?.(oldEl)

    this.seedCardStore(oldEl, cardJson)

    this.refreshCard(oldEl)
    this.refreshScore()
    this.markDirty()
    oldEl.classList.remove("card-optimising")
    oldEl.classList.add("card-flash")
    setTimeout(() => oldEl.classList.remove("card-flash"), 1300)
  }

  _csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  // Scroll the feed to a card named in the score board and pulse it, so the
  // creator can go straight from "what to fix" to the card itself.
  jumpToCard(event) {
    const num = event.currentTarget.dataset.cardNum
    const card = this.cardTargets.find(c => c.dataset.cardNum === num)
    if (!card) return
    this.focusFlowForCard(card) // reveal it if its flow is tabbed away
    card.scrollIntoView({ behavior: "smooth", block: "center" })
    card.classList.remove("card-flash")
    void card.offsetWidth // restart the animation if the card was just pulsed
    card.classList.add("card-flash")
    setTimeout(() => card.classList.remove("card-flash"), 1300)
  }

  _panelHtml(title, checks, footer) {
    const rows = checks.map(c => (
      `<li class="rule-check is-${c.rating}"><span class="rule-dot"></span>` +
      `<span class="rule-text">${this._esc(c.text)}</span></li>`
    )).join("")
    return `<div class="rule-panel-title">${this._esc(title)}</div>` +
           `<ul class="rule-list">${rows}</ul>${footer || ""}`
  }

  _ratingWord(rating) {
    return t(`editor.rules.rating_${rating}`)
  }

  _esc(s) {
    return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }

  toggleCardAnalysis(event) {
    event.stopPropagation() // don't also select/apply the type underneath
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const panel = card?.querySelector("[data-role='card-analysis']")
    if (!panel) return
    const open = panel.hidden
    panel.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
  }

  // ── Card settings (Answer Type tab) — Allow-Other / Required ──────────
  // The switches live in the panel, so they act on the currently selected
  // card; state is recorded on the wrap's data attributes, which is where
  // serialize() reads it from.
  _selectedCard() {
    return this.cardTargets.find(c => c.classList.contains("selected")) || null
  }

  // Show the switches for a question card (with its current state) or hide
  // them for welcome/checkpoint cards and empty selection. Called by
  // type-panel on select, type apply and delete.
  syncCardFlags(card) {
    if (!this.hasCardFlagsTarget) return
    // The respondent-code card's own switch, before the early return below:
    // it is a NON-question card, so the flags block never shows for it and its
    // toggle would never be reached if it lived inside one.
    if (this.hasRecallToggleTarget) {
      const isCode = card?.dataset.cardType === "respondent_code"
      this.recallToggleTarget.hidden = !isCode
      if (isCode && this.hasPanelRecallTarget) {
        this.panelRecallTarget.checked = card.dataset.cardRecall === "true"
      }
    }
    const isQ = card && !NON_QUESTION_TYPES.includes(card.dataset.cardType)
    this.cardFlagsTarget.hidden = !isQ
    if (!isQ) return
    if (this.hasPanelOtherTarget)    this.panelOtherTarget.checked    = card.dataset.cardAllowOther === "true"
    if (this.hasPanelRequiredTarget) this.panelRequiredTarget.checked = card.dataset.cardRequired === "true"
    if (this.hasPanelAskOnceTarget)  this.panelAskOnceTarget.checked  = card.dataset.cardAskOnce === "true"
    this._syncResponseScale(card)
    this._syncMaxChoices(card)
    this._syncNpsClassic(card)
    this._syncLocationScope(card)
  }

  // Location cards only: the "Search for" block (location_scope_controller),
  // which owns its own markup and writes the card's location data attributes.
  _syncLocationScope(card) {
    if (!this.hasLocationScopeTarget) return
    const isLocation = card?.dataset.cardInput === "location"
    this.locationScopeTarget.hidden = !isLocation
    if (!isLocation) return
    const scope = this.application.getControllerForElementAndIdentifier(this.locationScopeTarget, "location-scope")
    scope?.load(card)
  }

  // NPS cards only: is this card still on the classic 0-10?
  //
  // Read off the CARD rather than off a stored flag alone, for the same reason
  // NpsHelper#nps_custom_scale? does — the flag is only written when a creator
  // turns the classic off, so its absence has to be answered by the labels.
  // Otherwise every deck predating the switch would have opened claiming to be
  // classic while showing an agree scale.
  _syncNpsClassic(card) {
    if (!this.hasNpsClassicTarget) return
    const isNps = card?.dataset.cardType === "nps"
    this.npsClassicTarget.hidden = !isNps
    if (!isNps || !this.hasPanelNpsClassicTarget) return
    this.panelNpsClassicTarget.checked = !npsCustomScale(this._npsLabels(card), card.dataset.cardNpsCustomScale)
  }

  _npsLabels(card) {
    return Array.from(card.querySelectorAll(".nps-slider-labels .slider-label-text"))
                .map(el => el.textContent.trim())
  }

  // The switch itself. Turning the classic ON is the destructive direction —
  // it re-cuts the labels to 0-10 — and that is what it is for: "make this a
  // real NPS again". Turning it off changes no label, it only unlocks them.
  //
  // Delegated to the card's own card-editor for the rebuild, the same split
  // setResponseScale uses: this panel knows which card is selected, the card's
  // controller knows how a scale is drawn.
  togglePanelNpsClassic(event) {
    const card = this._selectedCard()
    if (!card) return
    const classic = event.currentTarget.checked

    if (classic) delete card.dataset.cardNpsCustomScale
    else card.dataset.cardNpsCustomScale = "true"

    const slider = card.querySelector(".nps-slider")
    const editor = slider && this.application.getControllerForElementAndIdentifier(slider, "card-editor")
    if (editor) editor.setNpsClassic(classic)

    this.markDirty()
  }

  // The strip's ＋ and × change the same number the picker reports, so the
  // picker has to follow them. Without this it only ever updated when a card
  // was selected: add two answers to a three-point scale and the panel went on
  // claiming 3 while the card showed 5 — the picker disagreeing with the card
  // it is pointing at.
  syncResponseScaleEvent(event) {
    const card = event.target?.closest?.("[data-survey-editor-target='card']")
    if (card && card === this._selectedCard()) this._syncResponseScale(card)
  }

  // The 2-6 scale picker: tap cards only, with the current size marked. Counted
  // off the rendered strip rather than the stored `responses`, because a card
  // that has never been re-scaled has no stored set and is still on three.
  _syncResponseScale(card) {
    if (!this.hasResponseScaleTarget) return
    const isTap = card?.dataset.cardType === "tap_card"
    this.responseScaleTarget.hidden = !isTap
    if (!isTap) return
    const count = card.querySelectorAll("[data-tap-response]").length
    this.responseScaleTarget.querySelectorAll(".response-scale-btn").forEach((btn) => {
      btn.classList.toggle("is-active", Number(btn.dataset.responseCount) === count)
      btn.setAttribute("aria-pressed", String(Number(btn.dataset.responseCount) === count))
    })
  }

  // Reseed the selected tap card's scale from a preset. Delegated to the card's
  // own card-editor controller, which owns the strip markup — this panel knows
  // which card is selected, not how a response is drawn.
  setResponseScale(event) {
    const card = this._selectedCard()
    if (!card) return
    const count = Number(event.currentTarget.dataset.responseCount)
    const wrap = card.querySelector("[data-controller~='card-editor']")
    const editor = wrap && this.application.getControllerForElementAndIdentifier(wrap, "card-editor")
    if (!editor) return
    editor.setResponsePreset(count)
    this._syncResponseScale(card)
    this.markDirty()
  }

  // The option list moves under this picker constantly — a ＋ or a × on a
  // select_many, a type switch on a grid (which has no add/remove affordance
  // of its own, so a switch is the ONLY thing that changes its count). Either
  // way a picker still offering "up to 4" on a card down to three answers is
  // the picker disagreeing with the card it points at, so it re-ranges on both
  // events. Same defect syncResponseScaleEvent exists for.
  syncMaxChoicesEvent(event) {
    const from = event.target?.closest?.("[data-survey-editor-target='card']")
    const card = this._selectedCard()
    // A type switch dispatches from the PANEL rather than the card, so there is
    // no owning card to match against — fall back to the selection, which is
    // the card the panel is pointing at.
    if (card && (!from || from === card)) this._syncMaxChoices(card)
  }

  // The 2…N cap picker: select-many types only, buttons built from the card's
  // LIVE option count rather than a fixed preset list (the tap scale above can
  // be server-rendered because TapScales is a constant; this range is per-card).
  //
  // The last button is "All" and carries 0, meaning no stored key at all. That
  // is the whole reason a limit isn't stored as the option count: "as many as
  // there are answers" has to keep being true when a sixth answer is added.
  _syncMaxChoices(card) {
    if (!this.hasMaxChoicesTarget || !this.hasMaxChoicesPickerTarget) return
    const type  = card?.dataset.cardType
    const count = MULTI_SELECT_TYPES.includes(type)
      ? this._optionEls(card).map(el => el.textContent.trim()).filter(Boolean).length
      : 0
    // Below three there is no cap to offer: the only legal values are 2…N-1.
    this.maxChoicesTarget.hidden = count < 3
    if (count < 3) return

    // A cap the option list has shrunk past is no cap at all — the server
    // sanitiser drops it on the next save, so correct the DOM now rather than
    // let the card advertise a ceiling that won't survive.
    let current = parseInt(card.dataset.cardMaxChoices, 10) || 0
    if (current < 2 || current >= count) {
      current = 0
      delete card.dataset.cardMaxChoices
    }

    const wanted = [ ...Array(count - 2).keys() ].map(i => i + 2).concat([ 0 ])
    const rendered = Array.from(this.maxChoicesPickerTarget.querySelectorAll(".response-scale-btn"))
      .map(b => Number(b.dataset.maxChoices))
    if (String(rendered) !== String(wanted)) {
      this.maxChoicesPickerTarget.innerHTML = wanted.map(n => `
        <button type="button" class="response-scale-btn" data-max-choices="${n}"
                data-action="click->survey-editor#setMaxChoices">${n || t("card.max_choices_all")}</button>`).join("")
    }
    this.maxChoicesPickerTarget.querySelectorAll(".response-scale-btn").forEach((btn) => {
      const on = Number(btn.dataset.maxChoices) === current
      btn.classList.toggle("is-active", on)
      btn.setAttribute("aria-pressed", String(on))
    })
  }

  // Set (or with "All", clear) the selected card's cap. The how-to line above
  // the question is the ONLY place a respondent learns the rule — the player
  // refuses the extra tap in silence — so it is rewritten here rather than
  // waiting for a reload.
  setMaxChoices(event) {
    const card = this._selectedCard()
    if (!card) return
    const n = Number(event.currentTarget.dataset.maxChoices) || 0
    if (n >= 2) card.dataset.cardMaxChoices = String(n)
    else delete card.dataset.cardMaxChoices

    const eyebrowEl = card.querySelector(".q-eyebrow")
    if (eyebrowEl) {
      eyebrowEl.textContent = cardEyebrow(this._eyebrows, this._activeLocale,
                                          card.dataset.cardType, card.dataset.cardMaxChoices,
                                          eyebrowEl.textContent)
    }
    // The player's own picker reads this off the list element, and the editor
    // card is the same markup — keep the preview honest about its own rule.
    // picker#maxValueChanged does the repaint; writing the attribute is enough.
    card.querySelectorAll("[data-picker-mode-value='multi']").forEach(ul => {
      ul.dataset.pickerMaxValue = String(n)
    })
    this._syncMaxChoices(card)
    this.refreshCard(card)
    this.markDirty()
  }

  togglePanelOther(event) {
    const card = this._selectedCard()
    if (!card) return
    const on = event.currentTarget.checked
    card.dataset.cardAllowOther = on ? "true" : "false"
    const wrap = card.querySelector(".other-cta-wrap")
    if (wrap) wrap.hidden = !on
    this.refreshCard(card)
    this.markDirty()
  }

  // Required is a pure data flag (no card-light effect) — record it, flip the
  // chrome-row chip so the deck stays scannable, and autosave.
  togglePanelRequired(event) {
    const card = this._selectedCard()
    if (!card) return
    const on = event.currentTarget.checked
    card.dataset.cardRequired = on ? "true" : "false"
    const chip = card.querySelector("[data-role='required-chip']")
    if (chip) chip.hidden = !on
    this.markDirty()
  }

  // Ask-once: on a repeat play by the same device identity, this question is
  // skipped once it has an answer (player_controller seeds the remembered
  // answer and navigation passes over the card). Same write-to-dataset shape
  // as Required above; serialize() reads it back as `ask_once`.
  togglePanelAskOnce(event) {
    const card = this._selectedCard()
    if (!card) return
    card.dataset.cardAskOnce = event.currentTarget.checked ? "true" : "false"
    this.markDirty()
  }

  // Whether entering the code may fill in ask-once answers this person gave on
  // another device. Same write-to-dataset shape as the flags above;
  // serialize() reads it back as `recall`, and the server refuses the key on
  // any card that is not a respondent_code (Survey.sanitize_cards_images!).
  togglePanelRecall(event) {
    const card = this._selectedCard()
    if (!card) return
    card.dataset.cardRecall = event.currentTarget.checked ? "true" : "false"
    this.markDirty()
  }

  // ── The intro modal ───────────────────────────────────────────────────────
  // The creator writes it where the respondent will meet it: an editable
  // replica floating over the card, exactly like the consent gate and the
  // thank-you screen. There is no stored "modal on" flag — the words are the
  // modal (Survey.sanitize_cards_images!) — so the on/off state lives entirely
  // in the DOM as .has-card-modal, and what it controls is whether the replica
  // is visible and whether its nodes hold anything for serialize() to read.

  toggleCardModal(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!card) return
    const split = card.querySelector(".split-card")
    if (!split) return
    // Already on: this is a "take me to it", not a toggle. Removing is the
    // replica's own Remove button — the same rule the card itself follows,
    // where the one delete CTA lives on the thing being deleted and is never
    // mirrored somewhere a stray click can reach it.
    if (split.classList.contains("has-card-modal")) { this._focusCardModal(card); return }
    split.classList.add("has-card-modal")
    this._paintCardModalBtn(card)
    this._focusCardModal(card)
    // Nothing is dirty yet — an open, empty modal stores nothing. It becomes a
    // real edit on the first keystroke, which markDirty picks up like any other
    // typing in the feed.
  }

  // Fold / unfold the replica. Folded it is a slim bar carrying the creator's
  // own heading; unfolded it is the card a respondent will actually see, which
  // is accurate and therefore in the way of the question underneath.
  toggleCardModalFold(event) {
    const layer = event.currentTarget.closest("[data-role='card-modal']")
    if (!layer) return
    const folded = layer.classList.toggle("is-folded")
    event.currentTarget.setAttribute("aria-expanded", String(!folded))
    event.currentTarget.setAttribute("title", t(folded ? "editor.modal_expand" : "editor.modal_collapse"))
    if (!folded) this._modalTitleEl(layer.closest("[data-survey-editor-target='card']"))?.focus({ preventScroll: true })
  }

  // Folded, the bar's label is the modal's heading — so it has to follow what
  // the creator types rather than being stamped once at render. Falls back to
  // the generic label for a modal with no heading yet, which is what makes an
  // empty one still readable as a modal.
  _paintCardModalLabel(card) {
    const label = card.querySelector("[data-role='card-modal-chrome-label']")
    if (!label) return
    const title = this._modalTitleEl(card)?.textContent.trim()
    label.textContent = title || t("editor.modal_chrome")
  }

  removeCardModal(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!card) return
    const btn = event.currentTarget
    // Arm before destroying, the same two-tap the card's own delete uses, and
    // only when there is something to lose: undo here is the browser's
    // contenteditable undo, which cannot put back text this method clears
    // programmatically. An empty modal closes on the first tap.
    if (this._modalHasWords(card) && !btn.classList.contains("is-armed")) {
      btn.classList.add("is-armed")
      btn.textContent = t("editor.modal_remove_confirm")
      clearTimeout(this._modalRemoveTimer)
      this._modalRemoveTimer = setTimeout(() => {
        btn.classList.remove("is-armed")
        btn.textContent = t("editor.modal_remove")
      }, 3000)
      return
    }
    clearTimeout(this._modalRemoveTimer)
    btn.classList.remove("is-armed")
    btn.textContent = t("editor.modal_remove")

    card.querySelector(".split-card")?.classList.remove("has-card-modal")
    // Back to the resting state, so turning one on again opens the same way it
    // did the first time rather than mid-expanded from a modal that is gone.
    this._modalLayer(card)?.classList.add("is-folded")
    // Blank the nodes rather than just hiding them: serialize() reads the DOM,
    // so leaving the words in a hidden layer would keep storing a modal the
    // creator has removed. Every language's entry goes with it — the modal is
    // gone from the deck, not from one tab.
    const title = this._modalTitleEl(card), body = this._modalBodyEl(card)
    if (title) title.textContent = ""
    if (body) body.textContent = ""
    this._paintCardModalLabel(card)
    const entry = this._store.get(card)
    if (entry) {
      Object.values(entry).forEach(content => {
        if (!content) return
        content.modal_title = ""
        content.modal_body = ""
        content.modal_body_html = null
      })
    }
    this._paintCardModalBtn(card)
    // Removing has to reach the server by the same door typing does. On a
    // locked deck markDirty is a no-op, so without this the modal would vanish
    // from the editor and go on greeting respondents.
    this._saveCardModal(card)
    this.markDirty()
  }

  // ── Saving a modal on a LOCKED deck ───────────────────────────────────────
  // A live Verto (or any that has collected an answer) suppresses autosave
  // outright — serialize() rebuilds the whole deck from the DOM, and that is
  // precisely what the lock exists to refuse. The modal is the one content edit
  // such a deck may take, so it goes out on its own: one cid, three strings,
  // through an endpoint that cannot reshape a deck (see
  // SurveysController#update_card_modal).
  //
  // Only on a locked deck. On a draft the ordinary autosave already carries the
  // modal with everything else, and a second writer would race it.

  _saveCardModal(card) {
    if (!this.liveValue || !this.cardModalUrlValue) return
    const cid = card?.dataset.cardCid
    // No cid, nothing to address. A card minted in this session has none until
    // the server mints one — but a card added in this session only exists on a
    // deck that is not locked, so this cannot strand a modal a creator typed.
    if (!cid) return

    this._modalSaveTimers ||= {}
    clearTimeout(this._modalSaveTimers[cid])
    this._modalSaveTimers[cid] = setTimeout(() => this._flushCardModal(card, cid), 700)
  }

  async _flushCardModal(card, cid) {
    const bodyEl = this._modalBodyEl(card)
    this.flash(t("editor.saving"), "text-smoke/60")
    try {
      const res = await fetch(this.cardModalUrlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: JSON.stringify({
          cid,
          modal_title: this._modalTitleEl(card)?.textContent.trim() || "",
          modal_body: this._readPlain(bodyEl),
          modal_body_html: this._readHtml(bodyEl)
        })
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const time = new Date().toLocaleTimeString()
      this.flash(t("editor.saved", { time }), "text-aquamarine")
    } catch (_) {
      // Said out loud rather than shown as "Saved" over an edit that never
      // landed: this deck is collecting answers, and a creator fixing a
      // question people are misreading needs to know whether the fix is live.
      this.flash(t("editor.save_failed", { msg: "" }), "text-hot-pink")
    }
  }

  _modalHasWords(card) {
    return !!(this._modalTitleEl(card)?.textContent.trim() ||
              this._modalBodyEl(card)?.textContent.trim())
  }

  // The rail control reads its card's state: an invitation while there is no
  // modal, a report once there is one.
  _paintCardModalBtn(card) {
    const btn = card.querySelector("[data-role='card-modal-btn']")
    if (!btn) return
    const on = !!card.querySelector(".split-card.has-card-modal")
    btn.classList.toggle("is-on", on)
    btn.setAttribute("aria-pressed", String(on))
    const label = btn.querySelector("[data-role='card-modal-btn-label']")
    if (label) label.textContent = on ? t("editor.modal_on") : t("editor.modal_add")
  }

  _focusCardModal(card) {
    const el = this._modalTitleEl(card) || this._modalBodyEl(card)
    if (!el) return
    // Unfold first — the nodes are display:none while the bar is folded, and
    // focus() on a hidden node silently does nothing.
    const layer = this._modalLayer(card)
    layer?.classList.remove("is-folded")
    const fold = layer?.querySelector(".card-modal-fold")
    if (fold) {
      fold.setAttribute("aria-expanded", "true")
      fold.setAttribute("title", t("editor.modal_collapse"))
    }
    card.scrollIntoView({ behavior: "smooth", block: "center" })
    el.focus({ preventScroll: true })
  }

  // Range-card reaction-animation theme. Record it on the wrap (serialize()
  // carries it into the card JSON) and swap the left-panel Lottie's URL set so
  // the preview updates live (lottie-player#urlsValueChanged re-renders).
  setRangeTheme(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!card) return
    const theme = event.currentTarget.value
    card.dataset.cardRangeTheme = theme
    const wrap = card.querySelector(".nps-lottie")
    const urls = this._rangeThemeUrls[theme]
    if (wrap && urls) wrap.dataset.lottiePlayerUrlsValue = JSON.stringify(urls)
    this.markDirty()
  }

  // NPS-card container silhouette. Same contract as setRangeTheme above —
  // record it on the wrap for serialize(), then redraw so the creator sees the
  // vessel they picked without a round-trip. The redraw is the shared
  // lib/nps_vessels drawing, i.e. the same one the type panel uses and a mirror
  // of the Ruby that rendered what is on screen now.
  setNpsShape(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!card) return
    const shape = npsVesselFor(event.currentTarget.value)
    card.dataset.cardNpsShape = shape

    const stage = card.querySelector(".nps-slider-stage")
    const control = stage?.querySelector(".nps-control")
    if (stage && control) {
      const v = NPS_VESSELS[shape]
      // The stage's custom properties are the vessel's own geometry (where its
      // liquid sits empty and full, and the digit column's inset off the same
      // two numbers), so they have to move WITH the silhouette or the labels
      // stop lining up with the fill.
      stage.setAttribute("style", npsStageStyle(v))
      control.className = `nps-control nps-shape-${shape}`
      control.innerHTML = npsVesselSvg(shape, v)
    }
    this.markDirty()
  }

  // { slug: [5 asset URLs] } from the editor's range-theme-picker blob, used to
  // swap the live preview when the theme changes.
  get _rangeThemeUrls() {
    if (this.__rangeThemeUrls) return this.__rangeThemeUrls
    const map = {}
    try {
      const data = JSON.parse(document.getElementById("range-theme-picker")?.textContent || "{}")
      ;(data.themes || []).forEach(th => { map[th.slug] = th.urls })
    } catch (_) { /* leave empty */ }
    this.__rangeThemeUrls = map
    return map
  }

  // ── Rename ───────────────────────────────────────────────────────────────
  // titleValue is what serialize() sends as `title`, and #update already
  // accepts it — the plumbing existed, but nothing ever reassigned the value,
  // so the editor had no way to rename a Verto. Reuses the ordinary autosave:
  // markDirty schedules the same 1.5s save every other edit uses.

  renameVerto(event) {
    const el = this.vertoTitleTarget
    const next = el.textContent.replace(/\s+/g, " ").trim()
    // A blank is not a rename, it's a name mid-retype. Keep titleValue on the
    // last good name so no save carries a blank AND so restoreRenameIfBlank
    // below has something to put back — it reads titleValue, so clobbering it
    // here made that guard restore the blank over the blank.
    if (!next) return
    if (next === this.titleValue) return
    this.titleValue = next
    // The event goes through so the undo stack can tell a keystroke here from
    // a gesture: this action is bound with :stop, so the root's own
    // input->markDirty never sees it.
    this.markDirty(event)
  }

  // Enter would insert a newline into a single-line title; commit instead.
  commitRename(event) {
    event.preventDefault()
    this.vertoTitleTarget.blur()
  }

  // An emptied title falls back to the last saved name rather than saving a
  // blank one — the dashboard shows the title first now, so a blank would
  // leave the tile with nothing to call itself.
  restoreRenameIfBlank() {
    const el = this.vertoTitleTarget
    if (el.textContent.trim()) return
    el.textContent = this.titleValue
  }

  // ── Theme ────────────────────────────────────────────────────────────────
  // The same three moves for the theme span beside the name. The theme is
  // what respondents call the Verto — the player's tab title, the link
  // preview, the dashboard tile's big line — and nothing could change it
  // after the wizard, so a copy's "(Copy)" was permanent. serialize() sends
  // it as `theme`; #update caps it and stores it.

  renameTheme(event) {
    const next = this.vertoThemeTarget.textContent.replace(/\s+/g, " ").trim()
    if (!next) return
    if (next === this.themeValue) return
    this.themeValue = next
    this.markDirty(event) // the event, so the undo stack groups it as typing (see renameVerto)
  }

  commitTheme(event) {
    event.preventDefault()
    this.vertoThemeTarget.blur()
  }

  restoreThemeIfBlank() {
    const el = this.vertoThemeTarget
    if (el.textContent.trim()) return
    el.textContent = this.themeValue
  }

  markDirty(event) {
    // Repaint the card being edited (or everything on a structural change) and
    // the overall score, so the lights track edits as they're typed.
    const active = document.activeElement?.closest?.("[data-survey-editor-target='card']")
    if (active) { this.refreshCard(active); this.refreshScore() } else { this.refreshAll() }

    // A locked deck has no deck-wide save to schedule — the server refuses one
    // (423) and flushSave has always bailed here. _doSave did not, which went
    // unnoticed only because the locked feed swallowed every click: nothing
    // could type, so markDirty never ran. The intro modal types there now, and
    // it carries its own save (_saveCardModal), so this returns after the
    // repaint rather than queueing a request that exists to be rejected.
    if (this.liveValue) return

    // Every deck change passes through here, which is what makes this the
    // place the undo stack notices them. An undo's own repaint-and-save must
    // not be noticed as a further change (_replaying).
    if (!this._replaying) this._noteUndoChange(event)

    this.flash(t("editor.unsaved"), "text-light-yellow")
    this._dirty = true
    // Bumped on every edit so a save that completes can tell whether the deck
    // still matches what it sent — see _doSave.
    this._editGen = (this._editGen || 0) + 1
    clearTimeout(this._saveTimer)
    this._saveTimer = setTimeout(() => this._doSave(), 1500)
  }

  serialize() {
    // Sync whatever language is on screen, then build each card from the store:
    // top-level fields are the PRIMARY language; every other language goes under
    // i18n with options normalised to the primary's count/order (alignment).
    this._captureLocale(this._activeLocale)
    const primary   = this.defaultLocaleValue
    const secondary = this.localesValue.filter(l => l !== primary)

    const cards = this.cardTargets.map(card => {
      const type  = card.dataset.cardType
      const out   = { type }
      const entry = this._store.get(card) || {}
      const prim  = entry[primary] || this._readCard(card)

      // Stable card id — carried through every rebuild so answer-branching
      // routes (which target a card by cid, never index) never break. New cards
      // with no cid yet get one server-side (Survey.sanitize_cards_images!).
      if (card.dataset.cardCid) out.cid = card.dataset.cardCid

      out.text = (prim.text || "").trim()
      if (prim.description && prim.description.trim()) out.description = prim.description.trim()

      // Rich-text layer: emitted only when formatting exists (see _readHtml),
      // so an unformatted deck serialises byte-identically to before. The
      // server drops any html that no longer reads as its plain twin
      // (RichTextSanitizer.clean_equivalent) — plain text stays canonical.
      if (out.text && prim.text_html) out.text_html = prim.text_html
      if (out.description && prim.description_html) out.description_html = prim.description_html

      // The intro modal. Emitted only when there are words — presence IS the
      // flag server-side (Survey.sanitize_cards_images!), so a card whose
      // modal editor is open but still empty serialises byte-identically to
      // before this feature existed, and Remove — which blanks the nodes
      // rather than hiding them — deletes the modal on the next autosave with
      // no separate key to keep in step.
      const modalTitle = (prim.modal_title || "").trim()
      const modalBody  = (prim.modal_body || "").trim()
      if (modalTitle) out.modal_title = modalTitle
      if (modalBody) {
        out.modal_body = modalBody
        if (prim.modal_body_html) out.modal_body_html = prim.modal_body_html
      }

      // A card's left panel holds a Lottie animation OR a video OR a photo.
      // Carry whichever it is — plus the creator credit — through autosave,
      // since the editor rebuilds cards from the DOM and would otherwise drop
      // these. Same exclusivity order as the server sanitiser.
      const lottie = card.dataset.cardLottie
      const video = lottie ? "" : card.dataset.cardVideo
      const image = lottie ? "" : card.dataset.cardImage
      if (lottie) {
        out.lottie = lottie
      } else if (video) {
        out.video = video
        if (card.dataset.cardVideoPoster) out.video_poster = card.dataset.cardVideoPoster
        // A clip is cropped by the panel exactly as a photo is, so it carries
        // the same focal pair — repositioning is the only reframing a video
        // can have, which makes dropping it here the difference between the
        // control working and silently undoing itself on the next autosave.
        this._writeFocal(out, card)
      } else if (image) {
        out.image = image
        // Where that image sits in the frames that crop it: --focal-y in the
        // mobile header, --focal-x in the desktop panel. Only carried when
        // moved off centre — the server drops a 50 anyway.
        this._writeFocal(out, card)
        // The re-crop record: the pre-crop original and where this crop sits
        // in it — what lets "Crop & zoom" zoom back OUT later. Rides the
        // card's dataset the same way the image itself does, so it has to be
        // re-serialised here or one autosave would silently strip it.
        if (card.dataset.cardImageSource) {
          out.image_source = card.dataset.cardImageSource
          const cropRaw = card.dataset.cardImageCrop
          if (cropRaw) {
            try { out.image_crop = JSON.parse(cropRaw) } catch (_e) { /* junk rect — dropped */ }
          }
        }
      }
      // Slow push-in/out on the card's own imagery — meaningless for video,
      // so only carried alongside a photo or animation.
      if ((lottie || image) && card.dataset.cardAnimateAsset === "true") out.animate_asset = true
      if (video || image) {
        const credit    = card.dataset.cardImageCredit
        const creditUrl = card.dataset.cardImageCreditUrl
        if (credit) out.image_credit = credit
        if (creditUrl) out.image_credit_url = creditUrl
      }
      // The animation backdrop rides on the card row as JSON, because the
      // colour/image pair has no text node in the card to be re-derived from —
      // exactly like option_styles. Dropped for a card whose panel is a photo
      // or video, mirroring the server's own rule.
      //
      // "Mirroring" is the whole of it, and this line did not: the rule has a
      // RANGE exception (a range card's panel is its reaction animation, so a
      // backdrop shows through it whatever else the card is carrying), stated
      // in ApplicationHelper#card_takes_backdrop?, in
      // Survey.sanitize_cards_images! and in media_picker#_cardTakesBackground
      // — and missing here. A range card still holding an `image` (switch a
      // photo card to Range and it does: the panel stops drawing the picture
      // but nothing clears it) therefore rendered its backdrop, offered the
      // Background control, repainted live — and then omitted media_bg from
      // every autosave. Nothing was dropped server-side, so there was no
      // warning either: "the background image I add to a range question
      // doesn't save, I have to re-add every time I load the editor".
      // Four places, one rule. Change one and change all four.
      // …and the three types whose answer takes the whole phone screen, which
      // carry a MOBILE background whatever else they hold. Missing them here
      // reproduced the exact bug the paragraph above describes, on the newest
      // types rather than on range: the backdrop painted live, autosave left it
      // out, the server dropped nothing so warned about nothing, and it was
      // gone on the next reload.
      const takesBackdrop = type === "range" || !!lottie || isFullScreenAnswer(type) ||
                            (!video && !image)
      if (takesBackdrop && card.dataset.cardMediaBg) {
        try {
          const bg = JSON.parse(card.dataset.cardMediaBg)
          if (bg && (bg.color || bg.image)) out.media_bg = bg
        } catch (_) { /* malformed — let the server default apply */ }
      }
      if (card.dataset.cardAllowOther === "true") out.allow_other = true
      if (card.dataset.cardRequired === "true") out.required = true
      if (card.dataset.cardAskOnce === "true") out.ask_once = true
      if (card.dataset.cardRecall === "true") out.recall = true

      // Structural flags the DOM never re-derives — an open_ended input
      // flavour (e.g. the birth-date "month" picker) and the demographic
      // marker — so autosave doesn't silently strip them the first time an
      // otherwise-unrelated field on the card is edited.
      if (card.dataset.cardInput) out.input = card.dataset.cardInput
      if (card.dataset.cardDemographic === "true") out.demographic = true
      // Which opt-in demographic question this is (heritage/neurodiversity) —
      // the discriminator the answer sync and results segments slice on. Not
      // emitting it here would strip it on the first autosave, degrading the
      // card to an unkeyed demographic MC that then collides with the gender
      // finder. Sanitised server-side against DemographicQuestions::DEMOGRAPHIC_KEYS.
      if (card.dataset.cardDemographicKey) out.demographic_key = card.dataset.cardDemographicKey
      // Which country's heritage taxonomy this card was built from. Nothing in
      // the editor displays it, so without carrying it here the first autosave
      // would drop it and the Verto would forget its Heritage card was ever
      // tailored — a later country change would then have nothing to compare
      // against. Sanitised server-side against WorldRegions.
      if (card.dataset.cardHeritageCountry) out.heritage_country = card.dataset.cardHeritageCountry
      // A location card's search narrowing (LocationScope) — written by the
      // location-scope panel, JSON on the wrap like the pages and options.
      // Nothing on the card redraws it, so without carrying it here the first
      // autosave would drop it. Sanitised server-side.
      if (card.dataset.cardInput === "location") {
        for (const [attr, key] of [["cardLocationPlaces", "location_places"],
                                   ["cardLocationCountries", "location_countries"],
                                   ["cardLocationCities", "location_cities"]]) {
          try {
            const v = JSON.parse(card.dataset[attr] || "[]")
            if (Array.isArray(v) && v.length) out[key] = v
          } catch (_) { /* drop malformed */ }
        }
      }

      // Common Question provenance — the ids that let results aggregate the
      // same question across Vertos. Nothing in the editor displays them, so
      // without carrying them here the first autosave would quietly orphan a
      // question the wizard (or the library picker) attached, and the rollup
      // would stop counting it with no visible symptom.
      if (card.dataset.cardCommonQuestionId) {
        out.common_question_id = Number(card.dataset.cardCommonQuestionId)
      }
      if (card.dataset.cardCommonQuestionSetId) {
        out.common_question_set_id = Number(card.dataset.cardCommonQuestionSetId)
      }

      // Framework provenance — which Awareness/Intention/Agency competency the
      // card sits under, its enabling condition, and the plain-language outcome.
      // SurveyGenerator tags every generated card with these and the editor
      // DISPLAYS them, in the "Why this card?" panel. They were the one carried
      // field with no line here, so the first autosave stripped them from every
      // card in the deck and that panel went permanently empty — including for
      // cards the creator never touched.
      if (card.dataset.cardCompetency) out.competency = card.dataset.cardCompetency
      if (card.dataset.cardCondition)  out.condition  = card.dataset.cardCondition
      if (card.dataset.cardOutcome)    out.outcome    = card.dataset.cardOutcome

      // AI-extracted photographable subject (CardSubjectExtractor), read by
      // AssetPopulator#card_query to anchor Pexels queries on Shuffle. Nothing
      // in the editor displays or edits it, so without carrying it here the
      // first autosave would silently drop it.
      if (card.dataset.cardSubject) out.subject = card.dataset.cardSubject

      // Range cards carry the reaction-animation theme picked in the editor.
      // Server-side sanitize drops it if it isn't a known slug on a range card.
      if (type === "range" && card.dataset.cardRangeTheme) out.range_theme = card.dataset.cardRangeTheme
      // NPS cards carry the container silhouette picked in the editor, same
      // gate: the server drops it if it isn't a vessel it can draw on an NPS
      // card, and its absence means "use the Verto-themed default".
      if (type === "nps" && card.dataset.cardNpsShape) out.nps_shape = card.dataset.cardNpsShape
      // …and whether the creator has taken it off the classic 0-10. Emitted
      // only when true, because absent is not "classic" — it is "nobody has
      // said", which the labels then answer (NpsHelper#nps_custom_scale?).
      if (type === "nps" && card.dataset.cardNpsCustomScale === "true") out.nps_custom_scale = true
      // …and the two anchor lines beside its ends. Each emitted only when it
      // has words: absent is the one representation of "no anchor", and the
      // server drops a blank or an anchor on any other type.
      const npsLow  = type === "nps" ? (prim.nps_low_label  || "").trim() : ""
      const npsHigh = type === "nps" ? (prim.nps_high_label || "").trim() : ""
      if (npsLow)  out.nps_low_label  = npsLow
      if (npsHigh) out.nps_high_label = npsHigh
      // Refresh the type panel's switch-away-and-back memory here, as the
      // option snapshot below is refreshed: the server writes
      // data-card-nps-anchors once, at page render, and only for an nps card —
      // so left alone it holds the words the page booted with (or none at all
      // for a card captioned since), and type_panel#_npsAnchorsFor falls back
      // to a stale value the moment the live column is gone.
      if (type === "nps") {
        if (npsLow || npsHigh) {
          card.dataset.cardNpsAnchors = JSON.stringify({ low: npsLow, high: npsHigh })
        } else {
          delete card.dataset.cardNpsAnchors
        }
      }
      // ...and the slider layout toggle (auto/horizontal/vertical), same gate.
      if (type === "range" && card.dataset.cardSliderAxis) out.slider_axis = card.dataset.cardSliderAxis
      // Select-many cards may cap how many answers a respondent ticks. Only
      // emitted when a cap is actually set — absent is "as many as there are
      // answers", and the server re-checks it against the option list it
      // receives (Survey.sanitize_cards_images!).
      if (MULTI_SELECT_TYPES.includes(type) && card.dataset.cardMaxChoices) {
        out.max_choices = parseInt(card.dataset.cardMaxChoices, 10)
      }

      // Range labels are POSITIONAL — each one names a fixed stop on a 5-point
      // track, so a blank is an unnamed stop, not an option to discard.
      // Dropping it would shorten the scale and shuffle every label after it
      // (the server re-spreads what it receives). Every other type treats a
      // blank as "not an option" and drops it as before.
      const trimmedOpts = (prim.options || []).map(o => (o || "").trim())
      const primOpts    = type === "range" ? trimmedOpts : trimmedOpts.filter(Boolean)
      if (primOpts.length) out.options = primOpts

      // Per-option rich text, filtered in lockstep with primOpts so indexes
      // keep matching what the server stores.
      const pairedOptHtml  = trimmedOpts.map((o, i) => [ o, (prim.options_html || [])[i] || null ])
      const alignedOptHtml = (type === "range" ? pairedOptHtml : pairedOptHtml.filter(([ o ]) => o)).map(([ , h ]) => h)
      if (primOpts.length && alignedOptHtml.some(Boolean)) out.options_html = alignedOptHtml

      // Narrative pages, in document order — id-and-text pairs so translations
      // (below) can align by id instead of position. Every PAGED type, not just
      // scenario: this read "type === 'scenario'" while the server had already
      // added consent_gate to PAGED_TYPES, so a consent gate autosaved with no
      // pages at all and the sanitiser rewrote them to [].
      const primPages = isPaged(type)
        ? (prim.pages || []).map(p => {
            const page = { id: p.id || "", text: (p.text || "").trim() }
            if (p.html) page.html = p.html
            return page
          }).filter(p => p.text)
        : []
      if (primPages.length) out.pages = primPages

      // Refresh the type panel's switch-away-and-back memory. data-card-options
      // and data-card-pages were written once by the server at page render and
      // never again, so after any edit they described a card that no longer
      // existed — and re-applying a type rebuilt from them. Writing them here
      // makes the snapshot mean "the last state that was saved", which is what
      // the panel needs it to mean.
      if (primOpts.length) card.dataset.cardOptions = JSON.stringify(primOpts)
      if (primPages.length) card.dataset.cardPages = JSON.stringify(primPages)

      // Per-option visual overrides, read off the option rows themselves —
      // the style lives on the li (data-option-*), so DOM order IS the
      // positional alignment with `options`: deleting or reordering an option
      // carries its style with it, no splice bookkeeping (unlike the
      // positional option_images array above). Filtered in lockstep with
      // primOpts so indexes keep matching what the server stores.
      if (OPTION_STYLE_TYPES.includes(type)) {
        const styleEls = this._optionEls(card)
        const rawStyles = trimmedOpts.map((o, i) => [ o, styleFromRow(styleEls[i]?.closest("li")) ])
        const aligned = (type === "range" ? rawStyles : rawStyles.filter(([o]) => o)).map(([, s]) => s || null)
        if (aligned.some(Boolean)) {
          out.option_styles = aligned
          card.dataset.cardOptionStyles = JSON.stringify(aligned)
        } else {
          delete card.dataset.cardOptionStyles
        }
      }

      // tap_card statement backgrounds (populated by AssetPopulator, or
      // generated/picked in the editor). Carried through autosave regardless
      // of the card's CURRENT type — not just while it's tap_card — so
      // switching away and back restores them instead of the server silently
      // losing them on the next save while some other type is active.
      // Survey.sanitize_cards_images! has no type gate on option_images
      // (unlike pages/range_theme), so it's safe to carry this through even
      // on a card that isn't tap_card right now. Only bound the array to the
      // current option count while tap_card is actually active — primOpts is
      // some OTHER type's options otherwise, and truncating against it would
      // destroy statements this card isn't even showing right now.
      //
      // Guard against primOpts reading empty for a genuine tap_card: that
      // means _optionEls found no ".rotate-card span[contenteditable]"
      // nodes, which is a serialization miss, not "this card has zero
      // statements" — a tap_card always renders at least one. Slicing
      // against a length of 0 would wipe every stored option_image, so an
      // empty read is treated as untrustworthy and the array is carried
      // through unsliced instead.
      try {
        const optImgs = JSON.parse(card.dataset.cardOptionImages || "[]")
        if (Array.isArray(optImgs) && optImgs.length) {
          out.option_images = (type === "tap_card" && primOpts.length) ? optImgs.slice(0, primOpts.length) : optImgs
        }
      } catch (_) { /* ignore malformed */ }

      // Where each of those statement pictures sits inside its card — same
      // positional array, bounded the same way, carried through a type switch
      // for the same reason. Only emitted when something in it is set: the
      // server drops an all-centre array, and sending one on every save would
      // put a key on every tap card in the deck for nothing.
      try {
        const optFocals = JSON.parse(card.dataset.cardOptionFocals || "[]")
        if (Array.isArray(optFocals) && optFocals.some(Boolean)) {
          out.option_focals = (type === "tap_card" && primOpts.length) ? optFocals.slice(0, primOpts.length) : optFocals
        }
      } catch (_) { /* ignore malformed */ }

      // tap_card response scale — the 2-6 answers each statement is judged on.
      // Read off the strip, which is the record (see card_editor#_rewriteStrip),
      // and mirrored back onto the row so a type switch away and back rebuilds
      // the creator's scale instead of the default three. Only emitted while
      // the card IS a tap card: `responses` is meaningless on any other type
      // and the server drops it there anyway.
      let primResponses = []
      if (type === "tap_card") {
        const responses = this._readResponses(card)
        primResponses = responses.map(r => r.label || "")
        if (responses.length) {
          out.responses = responses
          card.dataset.cardResponses = JSON.stringify(responses)
        } else {
          delete card.dataset.cardResponses
        }
      } else if (card.dataset.cardResponses) {
        try {
          const carried = JSON.parse(card.dataset.cardResponses)
          if (Array.isArray(carried) && carried.length) out.responses = carried
        } catch (_) { /* ignore malformed */ }
      }

      // Quiz: a card with a marked correct answer carries `correct` (+ optional
      // `explanation`); leaving it unmarked keeps the card as a measurement Q.
      if (this.quizValue) {
        const correct = this._readCorrect(card, type)
        if (this._hasCorrect(correct)) {
          out.correct = correct
          const expl = this._quizScope(card).querySelector("[data-quiz-explanation]")?.value?.trim()
          if (expl) out.explanation = expl
        }
      }

      // Tokenisation: choice/tap_card carry per-option/per-direction `tokens`;
      // scale/open/prioritise carry a flat `token_award`. Leaving every amount
      // at 0 keeps the card unawarded (TokenGrading.awarding? stays false).
      // Choice-shaped cards can opt into a flat award too (token_award_mode).
      // Per-card free-text cap. Only serialised when it differs from the default,
      // so a deck nobody has changed stays free of the key (the sanitiser drops
      // a default-valued one anyway).
      const limitSel = card.querySelector("[data-char-limit]")
      if (limitSel) {
        const limit = parseInt(limitSel.value, 10)
        if (limit && limit !== 200) out.char_limit = limit
      }

      if (this.tokenisationValue) {
        const { tokens, token_award } = this._readTokens(card, type)
        if (tokens && Object.keys(tokens).length) out.tokens = tokens
        if (token_award && Object.keys(token_award).length) out.token_award = token_award
        if (CHOICE_TYPES.includes(type) && this._tokenAwardMode(card) === "completion") {
          out.token_award_mode = "completion"
        }
        // Only an explicit OFF is serialised. Absent means enabled, so this
        // never appears on a deck the creator hasn't touched — and unlike
        // all-zero amounts (which the serialiser drops), it survives the save,
        // which is the whole point: it distinguishes "no points here" from
        // "not set up yet".
        const enabledBox = this._tokenScope(card).querySelector("[data-token-enabled]")
        if (enabledBox && !enabledBox.checked) out.tokens_enabled = false
      }

      // Answer-branching: single-pick cards carry per-option `routes` (+ an
      // optional `default`). Leaving every option on "Continue" keeps the card
      // linear (LogicGraph.routing? stays false).
      if (this.logicValue) {
        const logic = this._readLogic(card, type)
        if (this._hasLogic(logic)) out.logic = logic
      }
      // The unconditional flow pointer (any card type), set by the flow map to
      // chain branch cards and rejoin. Carried on the wrap so it round-trips.
      const nextRaw = card.dataset.cardNext
      if (nextRaw) {
        try {
          const n = JSON.parse(nextRaw)
          if (n && ((n.card && n.card !== "") || (n.end && n.end !== ""))) out.next = n
        } catch (_) { /* drop malformed */ }
      }
      // Optional branch name (flow map), stored on the lane's entry card.
      const laneLabel = (card.dataset.cardLaneLabel || "").trim()
      if (laneLabel) out.lane_label = laneLabel
      // First-class flow membership. Only a known flow's id is carried —
      // Survey.reconcile_flows! would drop a ghost id server-side anyway.
      const flowId = card.dataset.cardFlowId
      if (flowId && this.flowById(flowId)) out.flow_id = flowId

      const i18n = {}
      secondary.forEach(loc => {
        const t = entry[loc]
        if (!t) return
        const tEntry = {}
        if ((t.text || "").trim()) tEntry.text = t.text.trim()
        if ((t.description || "").trim()) tEntry.description = t.description.trim()
        // Only offered where the primary HAS a modal: a translation can't
        // introduce one the source language doesn't have, and the server drops
        // an orphaned entry anyway.
        if (modalTitle && (t.modal_title || "").trim()) tEntry.modal_title = t.modal_title.trim()
        if (modalBody && (t.modal_body || "").trim()) tEntry.modal_body = t.modal_body.trim()
        // The NPS anchor lines, same rule as the modal: only where the primary
        // has one, and only when this language has words for it.
        if (npsLow  && (t.nps_low_label  || "").trim()) tEntry.nps_low_label  = t.nps_low_label.trim()
        if (npsHigh && (t.nps_high_label || "").trim()) tEntry.nps_high_label = t.nps_high_label.trim()
        if (primOpts.length) {
          const topts = t.options || []
          tEntry.options = primOpts.map((p, k) => ((topts[k] || "").trim()) || p)
        }
        if (primPages.length) {
          const tpages = t.pages || []
          tEntry.pages = primPages.map(p => {
            const match = tpages.find(tp => tp.id && tp.id === p.id)
            return { id: p.id, text: (match && match.text.trim()) || p.text }
          })
        }
        // Response labels align positionally against the primary scale, exactly
        // like options — a slot with no translation falls back to the primary
        // wording, which is what the player renders for it anyway.
        if (primResponses.length) {
          const tresp = t.responses || []
          tEntry.responses = primResponses.map((p, k) => ((tresp[k] || "").trim()) || p)
        }
        if (Object.keys(tEntry).length) i18n[loc] = tEntry
      })
      if (Object.keys(i18n).length) out.i18n = i18n

      return out
    })

    // Compile flow membership + exits down to the per-card `next` chain (the
    // runtime primitive) — see _compileFlows / FlowCompiler.
    this._compileFlows(cards)

    return { title: this.titleValue, theme: this.themeValue, description: this.descriptionValue, cards, flows: this.flowsList(),
             // Whether this page could see token controls at all: they render
             // only when tokenisation is on at page load, so a page from
             // before it was switched on provably knows nothing about tokens
             // and the server must not read its silence as deletion.
             tokens_authoritative: !!this.tokenisationValue,
             // The wording revision this page was rendered at — see the value's
             // own comment. Absent on an older cached client, which the server
             // reads as maximally stale rather than as up to date.
             translations_revision: this.translationsRevisionValue }
  }

  // ── Quiz: correct-answer marking ─────────────────────────────────────────

  _hasCorrect(c) {
    if (c === null || c === undefined || c === "") return false
    if (Array.isArray(c)) return c.length > 0
    if (typeof c === "object") return Object.keys(c).length > 0
    return true
  }

  // Quiz-correct-block / token-award-block may currently be relocated into
  // the sidebar's Tokenomics/Quiz mode sub-tabs (see type-panel controller's
  // selectCard) rather than sitting inside `card` — look them up by the
  // registry (element reference, location-independent) so reads/writes keep
  // working wherever the block currently lives. Falls back to searching
  // `card` itself for a block that was never relocated (e.g. no card has
  // been selected in the panel yet).
  _quizScope(card)  { return this._typePanel()?.quizBlockFor(card)  || card }
  _tokenScope(card) { return this._typePanel()?.tokenBlockFor(card) || card }
  // The routing selects live in a block that the type panel relocates into the
  // sidebar's Branching tab for the selected card, so read/write them wherever
  // that block currently sits (falling back to the card if never relocated).
  _logicScope(card) { return this._typePanel()?.logicBlockFor(card) || card }

  // Public: the branching-block scope for a card by cid — used by the flow map
  // to drive the same route selects after they've been relocated to the sidebar.
  logicScopeForCid(cid) {
    const wrap = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(cid)}"]`)
    return wrap ? this._logicScope(wrap) : null
  }

  // The card media's focal pair, onto whichever branch of serialize() is
  // carrying media. Centre is the default everywhere and the server drops a 50,
  // so an untouched card emits neither key and serialises byte-identically to
  // before this axis existed.
  _writeFocal(out, card) {
    for (const [ key, attr ] of [ [ "focal_x", "cardFocalX" ], [ "focal_y", "cardFocalY" ] ]) {
      const value = parseInt(card.dataset[attr], 10)
      if (Number.isFinite(value) && value !== 50) out[key] = Math.min(100, Math.max(0, value))
    }
    // How far past cover-fit it is punched in — what gives an axis that already
    // fits the frame something to slide. Cover-fit is the default, so a 1 is
    // sent as nothing and the server drops it anyway.
    const zoom = parseFloat(card.dataset.cardFocalZoom)
    if (Number.isFinite(zoom) && zoom > 1) out.focal_zoom = Math.min(3, zoom)
  }

  // A tap card's response scale, read off the strip that renders it. The DOM is
  // the record here exactly as it is for option rows: a response's style lives
  // on the element as data-option-* (written by the 🎨 popover), its label is
  // the contenteditable inside it, and its key never moves — which is the whole
  // point of the key being separate from the label, since answers already
  // collected are stored against it.
  _readResponses(card) {
    return Array.from(card.querySelectorAll("[data-tap-response]")).flatMap((el) => {
      const key = (el.dataset.responseKey || "").trim()
      if (!key) return []
      const out = { key }
      const label = el.querySelector("[data-tap-response-label]")?.textContent?.trim()
      if (label) out.label = label
      if (el.dataset.responseGlyph) out.glyph = el.dataset.responseGlyph
      if (el.dataset.optionIcon) out.icon = el.dataset.optionIcon
      if (el.dataset.optionEmoji) out.emoji = el.dataset.optionEmoji
      if (el.dataset.optionColor) out.color = el.dataset.optionColor
      if (el.classList.contains("is-strong")) out.strong = true
      return [ out ]
    })
  }

  // The marked correct answer for a card, in the shape QuizGrading expects.
  _readCorrect(card, type) {
    const labelOf = item => {
      if (type === "yes_no") return (item.dataset.canonical || "").trim()
      const lbl = item.querySelector(".pick-text, .choice-label")
      return (lbl?.textContent.trim()) || (item.dataset.canonical || "").trim()
    }
    switch (type) {
      case "multiple_choice": case "yes_no": case "select_one_grid": case "scenario": {
        const el = card.querySelector('[data-picker-target="item"][data-correct="true"]')
        return el ? labelOf(el) : null
      }
      case "select_many": case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-picker-target="item"][data-correct="true"]'))
                    .map(labelOf).filter(Boolean)
      case "tap_card": {
        // Any key on this card's scale is a markable answer. It used to be
        // "yes" or "no" only, which was fine when those were the only answers
        // worth being right about; on a five-point scale the correct answer is
        // as likely to be "Strongly agree", and a hardcoded pair would silently
        // refuse to record it.
        const keys = new Set(this._readResponses(card).map(r => r.key))
        const map = {}
        this._quizScope(card).querySelectorAll(".quiz-tap-row").forEach(row => {
          const dir = row.dataset.correctDir
          if (dir && keys.has(dir)) map[(row.dataset.statement || "").trim()] = dir
        })
        return map
      }
      case "range": case "nps": case "rating": {
        const v = this._quizScope(card).querySelector("[data-quiz-correct]")?.value
        return (v === undefined || v === null || v === "") ? null : Number(v)
      }
      case "open_ended": {
        const ta = this._quizScope(card).querySelector("[data-quiz-accepted]")
        return ta ? ta.value.split("\n").map(s => s.trim()).filter(Boolean) : null
      }
      default: return null
    }
  }

  // ── Tokenisation: per-option / per-card token-amount marking ─────────────

  // Every non-zero token-amount input inside `container`, as {token_id => n}.
  _tokenAmounts(container) {
    const out = {}
    container.querySelectorAll(".token-amount-input").forEach(input => {
      const id = input.dataset.tokenId
      const n  = parseInt(input.value, 10)
      if (id && n) out[id] = n
    })
    return out
  }

  // This card's token config, in the shape TokenGrading expects: `tokens` for
  // choice/tap_card (keyed by canonical option/statement), `token_award` for
  // the flat-award types.
  // Which award mode a choice-shaped card is currently set to — whichever
  // [data-token-mode-section] is visible (toggled by setTokenAwardMode).
  _tokenAwardMode(card) {
    const completion = this._tokenScope(card).querySelector('[data-token-mode-section="completion"]')
    return completion && !completion.hidden ? "completion" : "per_answer"
  }

  _readTokens(card, type) {
    switch (type) {
      case "multiple_choice": case "select_many": case "yes_no":
      case "select_one_grid": case "select_many_grid": case "scenario": {
        // Relocated into the sidebar's Tokenomics tab (see
        // _card_component.html.erb) — not inline on the option itself, so
        // read via the token scope, not `card` directly.
        const scope = this._tokenScope(card)
        if (this._tokenAwardMode(card) === "completion") {
          const row = scope.querySelector('[data-token-mode-section="completion"] .token-award-row')
          return { token_award: row ? this._tokenAmounts(row) : {} }
        }
        // One .token-award-row per option.
        const tokens = {}
        scope.querySelectorAll('[data-token-mode-section="per_answer"] .token-award-row[data-canonical]').forEach(row => {
          const label  = (row.dataset.canonical || "").trim()
          const inputs = row.querySelector(".token-inputs")
          if (!label || !inputs) return
          const amt = this._tokenAmounts(inputs)
          if (Object.keys(amt).length) tokens[label] = amt
        })
        return { tokens }
      }
      case "tap_card": {
        const tokens = {}
        this._tokenScope(card).querySelectorAll(".token-tap-row").forEach(row => {
          const statement = (row.dataset.statement || "").trim()
          if (!statement) return
          const dirs = {}
          row.querySelectorAll(".token-inputs").forEach(dirBlock => {
            const dir = dirBlock.dataset.direction
            const amt = this._tokenAmounts(dirBlock)
            if (dir && Object.keys(amt).length) dirs[dir] = amt
          })
          if (Object.keys(dirs).length) tokens[statement] = dirs
        })
        return { tokens }
      }
      case "range": case "nps": case "rating": case "open_ended": case "prioritise": {
        const row = this._tokenScope(card).querySelector(".token-award-row")
        return { token_award: row ? this._tokenAmounts(row) : {} }
      }
      default:
        return {}
    }
  }

  // Mirror of syncBranchingEvent for the token award rows, which have the same
  // staleness: rendered once server-side, keyed by canonical option label /
  // tap statement. Without this, renaming an option orphaned its amounts — the
  // next autosave wrote `tokens` under the OLD label, the inputs read back 0,
  // and TokenGrading matched nothing while the card still claimed to award.
  syncTokenRowsEvent(event) {
    const card = event.target?.closest?.("[data-survey-editor-target='card']")
    if (!card) return
    if (event.type === "focusout" &&
        !event.target.closest?.(".pick-text, .choice-label, .rotate-card span[contenteditable]")) return
    this.syncTokenRowsFor(card)
  }

  syncTokenRowsFor(cardEl) {
    if (!this.tokenisationValue || !cardEl) return
    // Canonicals are PRIMARY-language labels; a rename on a translation tab is
    // a translation, not a re-key.
    if (this._activeLocale !== this.defaultLocaleValue) return
    const type = cardEl.dataset.cardType
    if (type === "tap_card") return this._syncTapTokenRows(cardEl)
    if (!TOKEN_SYNCED_TYPES.includes(type)) return

    const scope   = this._tokenScope(cardEl)
    const section = scope.querySelector('[data-token-mode-section="per_answer"]')
    if (!section) return

    // Prior amounts per option — by uid (survives renames), then by label,
    // then by position, exactly like syncBranchingFor.
    const byUid = new Map(), byLabel = new Map(), byIndex = []
    section.querySelectorAll(".token-award-row[data-canonical]").forEach(row => {
      const inputs = row.querySelector(".token-inputs")
      const amt    = inputs ? this._tokenAmounts(inputs) : {}
      byIndex.push(amt)
      if (row.dataset.optUid) byUid.set(row.dataset.optUid, amt)
      byLabel.set((row.dataset.canonical || "").trim(), amt)
    })

    // Fresh inputs are cloned from the completion row, which is always
    // server-rendered with one input per token type whatever mode is showing —
    // no client-side copy of the token-type table needed.
    const template = scope.querySelectorAll('[data-token-mode-section="completion"] .token-amount-input')
    if (!template.length) return

    section.textContent = ""
    this._optionEls(cardEl).forEach((optEl, i) => {
      const label = optEl.textContent.trim()
      if (!label) return
      let uid = optEl.dataset.optUid
      if (!uid) { uid = String(this._optUidSeq = (this._optUidSeq || 0) + 1); optEl.dataset.optUid = uid }
      const amt = byUid.has(uid) ? byUid.get(uid)
                : byLabel.has(label) ? byLabel.get(label)
                : (byIndex[i] || {})
      section.appendChild(this._tokenAwardRow(uid, label, amt, template))
    })
  }

  // One per-answer award row, matching _card_component.html.erb's markup.
  _tokenAwardRow(uid, label, amounts, template) {
    const row = document.createElement("div")
    row.className = "token-award-row"
    row.dataset.canonical = label
    row.dataset.optUid = uid
    const shown = document.createElement("span")
    shown.className = "token-award-label"
    shown.textContent = label
    const inputs = document.createElement("div")
    inputs.className = "token-inputs"
    template.forEach(tpl => {
      const input = tpl.cloneNode(false)
      input.value = amounts[input.dataset.tokenId] || 0
      inputs.appendChild(input)
    })
    row.append(shown, inputs)
    return row
  }

  // tap_card keys amounts by statement, with per-direction blocks inside each
  // row — same carry discipline, whole-row clone as the template.
  _syncTapTokenRows(cardEl) {
    const scope = this._tokenScope(cardEl)
    const rows  = [ ...scope.querySelectorAll(".token-tap-row") ]
    if (!rows.length) return

    const harvest = row => {
      const dirs = {}
      row.querySelectorAll(".token-inputs").forEach(block => {
        if (block.dataset.direction) dirs[block.dataset.direction] = this._tokenAmounts(block)
      })
      return dirs
    }
    const byUid = new Map(), byLabel = new Map(), byIndex = []
    rows.forEach(row => {
      const dirs = harvest(row)
      byIndex.push(dirs)
      if (row.dataset.optUid) byUid.set(row.dataset.optUid, dirs)
      byLabel.set((row.dataset.statement || "").trim(), dirs)
    })

    const templateRow = rows[0]
    const parent = templateRow.parentElement
    rows.forEach(row => row.remove())
    this._optionEls(cardEl).forEach((optEl, i) => {
      const label = optEl.textContent.trim()
      if (!label) return
      let uid = optEl.dataset.optUid
      if (!uid) { uid = String(this._optUidSeq = (this._optUidSeq || 0) + 1); optEl.dataset.optUid = uid }
      const dirs = byUid.has(uid) ? byUid.get(uid)
                 : byLabel.has(label) ? byLabel.get(label)
                 : (byIndex[i] || {})
      const row = templateRow.cloneNode(true)
      row.dataset.statement = label
      row.dataset.optUid = uid
      row.querySelector(".token-award-label").textContent = label
      row.querySelectorAll(".token-inputs").forEach(block => {
        const dir = block.dataset.direction
        block.querySelectorAll(".token-amount-input").forEach(input => {
          input.dataset.tokenStatement = label
          input.value = (dirs[dir] || {})[input.dataset.tokenId] || 0
        })
      })
      parent.appendChild(row)
    })
  }

  // ── Flows: first-class named branches ───────────────────────────────────
  // A flow is a named, coloured group of cards (membership rides on the wrap
  // as data-card-flow-id, mirroring card["flow_id"]). The flows array itself
  // is authoring metadata; _compileFlows() compiles membership + exit down to
  // the per-card `next` pointers the player already resolves — the JS mirror
  // of FlowCompiler (app/lib/flow_compiler.rb), which re-runs server-side on
  // every save as the authoritative backstop. Keep the two in sync.

  flowsList() { return this._flows || [] }

  flowById(id) { return this.flowsList().find(f => f.id === id) || null }

  // A flow's member wraps, in deck (document) order — flow order IS deck order.
  flowMemberWraps(id) {
    if (!id) return []
    return this.cardTargets.filter(c => c.dataset.cardFlowId === id)
  }

  // The cid a route targeting this flow resolves to: its first member's.
  flowEntryCid(id) {
    const members = this.flowMemberWraps(id)
    return members.length ? (members[0].dataset.cardCid || null) : null
  }

  addFlow({ name, color, exit } = {}) {
    const flows = this.flowsList()
    const flow = {
      id: this._mintFlowId(),
      name: (name || "").trim().slice(0, 60) || `Flow ${flows.length + 1}`,
      color: color || FLOW_COLORS[flows.length % FLOW_COLORS.length]
    }
    const ex = this._validFlowExit(exit)
    if (ex) flow.exit = ex
    flows.push(flow)
    this.refreshAll()
    this.markDirty()
    return flow
  }

  renameFlow(id, name) {
    const flow = this.flowById(id)
    const clean = (name || "").trim().slice(0, 60)
    if (!flow || !clean || flow.name === clean) return
    flow.name = clean
    this.refreshAll()
    this.markDirty()
  }

  // exit: { card } | { end } | null (null ⇒ fall through linearly after the flow).
  setFlowExit(id, exit) {
    const flow = this.flowById(id)
    if (!flow) return
    const ex = this._validFlowExit(exit)
    if (ex) flow.exit = ex
    else delete flow.exit
    this.refreshAll()
    this.markDirty()
  }

  // Assign a card to a flow (flowId null ⇒ leave its flow). Membership only
  // ever changes through here / removeFlow — reordering cards never re-parents
  // them, so a move can split a flow's visual run but not its membership.
  setCardFlow(cardEl, flowId) {
    if (!cardEl) return
    if (flowId && this.flowById(flowId)) {
      cardEl.dataset.cardFlowId = flowId
    } else {
      delete cardEl.dataset.cardFlowId
      delete cardEl.dataset.cardNext // compiled plumbing goes with the membership
    }
    this.refreshAll()
    this.markDirty()
  }

  // Delete a flow. Dissolve (default) keeps the member cards, clearing their
  // membership + compiled `next` chain; deleteCards removes their slots too
  // (routes that pointed at them reset via refreshLogicTargets' target-gone
  // fallback on the next repaint).
  removeFlow(id, { deleteCards = false } = {}) {
    this.flowMemberWraps(id).forEach(wrap => {
      if (deleteCards) {
        ;(wrap.closest(".card-slot") || wrap).remove()
      } else {
        delete wrap.dataset.cardFlowId
        delete wrap.dataset.cardNext
      }
    })
    this._flows = this.flowsList().filter(f => f.id !== id)
    this.refreshAll()
    this.markDirty()
  }

  _mintFlowId() {
    const used = new Set(this.flowsList().map(f => f.id))
    let id
    do {
      const bytes = crypto.getRandomValues(new Uint8Array(4))
      id = "f_" + Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
    } while (used.has(id))
    return id
  }

  // Mirror of FlowCompiler.valid_exit: a single-key authoring target or null.
  // { end } finishes on a branch screen, { flow } chains into another flow
  // (resolved to its entry at compile time so it tracks reorders), { card }
  // converges on a specific card. Priority end > flow > card.
  _validFlowExit(target) {
    if (!target || typeof target !== "object") return null
    if (target.end != null && String(target.end) !== "") return { end: String(target.end) }
    if (target.flow != null && String(target.flow) !== "") return { flow: String(target.flow) }
    if (target.card != null && String(target.card) !== "") return { card: String(target.card) }
    return null
  }

  // Mirror of FlowCompiler.resolve_exit: the runtime target the last member's
  // `next` carries — a flow exit resolves to that flow's entry card, or null
  // when it's empty/unknown (fail safe: fall through linearly).
  _resolveFlowExit(target, cards) {
    const ex = this._validFlowExit(target)
    if (!ex || ex.flow == null) return ex
    const entry = cards.find(c => c.flow_id === ex.flow)
    return entry && entry.cid ? { card: entry.cid } : null
  }

  // Mirror of FlowCompiler.compile!: chain each flow's members with `next`
  // pointers and point the last at the exit. Runs inside serialize() so the
  // flow map (which renders from serialize()) and autosave payloads agree
  // mid-edit. Also writes the computed pointer back onto each member wrap's
  // data-card-next — the wrap dataset is the editor's source of truth for
  // `next` (the flow map's _setNext writes it, serialize() reads it), so a
  // stale value there would resurrect an old pointer on a later edit. A
  // member with no cid yet (fresh card, server stamps cids) is skipped as a
  // chain TARGET client-side; the server compile completes the chain on save.
  _compileFlows(cards) {
    const wraps = this.cardTargets
    this.flowsList().forEach(flow => {
      const memberIdxs = []
      cards.forEach((c, i) => { if (c.flow_id === flow.id) memberIdxs.push(i) })
      memberIdxs.forEach((cardIdx, k) => {
        const last = k === memberIdxs.length - 1
        let next = null
        if (!last) {
          const targetCid = cards[memberIdxs[k + 1]].cid
          next = targetCid ? { card: targetCid } : null
        } else {
          next = this._resolveFlowExit(flow.exit, cards)
        }
        if (next) {
          cards[cardIdx].next = next
          if (wraps[cardIdx]) wraps[cardIdx].dataset.cardNext = JSON.stringify(next)
        } else {
          delete cards[cardIdx].next
          if (wraps[cardIdx]) delete wraps[cardIdx].dataset.cardNext
        }
      })
    })
    return cards
  }

  // Paint flow identity onto the feed: a coloured rail on member slots (via
  // --flow-color) and, per contiguous stretch of flow cards, a row of header
  // pills — one pill when a single flow sits there, one pill PER FLOW when
  // sibling flows do (UK | UAE | USA). With siblings, only the active pill's
  // flow is shown; tapping another pill (or swiping the row) switches flows,
  // landing on the SAME card position in the next flow so "flow 1 card 3 →
  // flow 3 card 3" is one tap (see _switchFlow). Presentation only —
  // membership lives on the wraps, and hidden slots still serialize/compile
  // exactly like visible ones.
  _paintFlowChrome() {
    this.element.querySelectorAll(".flow-header-row, .flow-tabs-row").forEach(el => el.remove())
    const flowsById = new Map(this.flowsList().map(f => [ f.id, f ]))
    const counts = new Map()
    this.cardTargets.forEach(c => {
      const fid = c.dataset.cardFlowId
      if (fid && flowsById.has(fid)) counts.set(fid, (counts.get(fid) || 0) + 1)
    })

    // Rails + collect the member run structure in document order.
    const entries = []
    this.cardTargets.forEach(card => {
      const slot = card.closest(".card-slot")
      if (!slot) return
      slot.classList.remove("flow-hidden")
      const flow = flowsById.get(card.dataset.cardFlowId)
      if (flow) {
        slot.dataset.flowId = flow.id
        slot.style.setProperty("--flow-color", flow.color)
        slot.classList.add("in-flow")
      } else {
        delete slot.dataset.flowId
        slot.style.removeProperty("--flow-color")
        slot.classList.remove("in-flow")
      }
      entries.push({ slot, flow })
    })

    // Clusters: maximal consecutive stretches of flow slots (any flows).
    let cluster = null
    const clusters = []
    entries.forEach(e => {
      if (e.flow) {
        if (!cluster) { cluster = { slots: [], flowOrder: [] }; clusters.push(cluster) }
        cluster.slots.push(e)
        if (!cluster.flowOrder.includes(e.flow)) cluster.flowOrder.push(e.flow)
      } else {
        cluster = null
      }
    })

    clusters.forEach(cl => {
      const first = cl.slots[0].slot
      if (cl.flowOrder.length === 1) {
        const flow = cl.flowOrder[0]
        first.before(this._flowHeaderRow(flow, counts.get(flow.id) || 0))
        return
      }
      // Multi-flow cluster: show the remembered tab (jumps into a hidden
      // flow go through focusFlowForCard, which updates the memory first).
      const key = cl.flowOrder.map(f => f.id).sort().join("|")
      let active = this._activeFlowTabs.get(key)
      if (!cl.flowOrder.some(f => f.id === active)) active = cl.flowOrder[0].id
      this._activeFlowTabs.set(key, active)
      cl.slots.forEach(e => e.slot.classList.toggle("flow-hidden", e.flow.id !== active))
      first.before(this._flowTabsRow(cl, key, active, counts))
    })
  }

  // Sibling-flow pills above a multi-flow stretch: [● UK 3] [● UAE 3] [● USA 3]
  // — the same little header pill each flow already gets on its own, just one
  // per flow, active lit and siblings ghosted. No extra chrome: the pills ARE
  // the switcher (tap one, or swipe across the row).
  _flowTabsRow(cluster, key, activeId, counts) {
    const row = document.createElement("div")
    row.className = "flow-tabs-row"
    row.setAttribute("role", "tablist")
    const ids = cluster.flowOrder.map(f => f.id)
    cluster.flowOrder.forEach(flow => {
      const pill = document.createElement("button")
      pill.type = "button"
      pill.className = "flow-header-row flow-tab-pill"
      pill.setAttribute("role", "tab")
      pill.setAttribute("aria-selected", String(flow.id === activeId))
      pill.classList.toggle("is-active", flow.id === activeId)
      pill.style.setProperty("--flow-color", flow.color)
      const dot = document.createElement("span")
      dot.className = "flow-header-dot"
      dot.setAttribute("aria-hidden", "true")
      const name = document.createElement("span")
      name.className = "flow-header-name"
      name.textContent = flow.name
      const count = document.createElement("span")
      count.className = "flow-header-count"
      count.textContent = t("editor.flows.header_count", { count: counts.get(flow.id) || 0 })
      pill.append(dot, name, count)
      pill.addEventListener("click", () => this._switchFlow(key, flow.id))
      row.appendChild(pill)
    })
    // Swiping across the row steps to the neighbouring flow.
    row.addEventListener("pointerdown", (e) => { this._flowSwipeX = e.clientX })
    row.addEventListener("pointerup", (e) => {
      const dx = e.clientX - (this._flowSwipeX ?? e.clientX)
      this._flowSwipeX = null
      if (Math.abs(dx) < 48) return
      const i = ids.indexOf(this._activeFlowTabs.get(key) || activeId)
      this._switchFlow(key, ids[(i + (dx < 0 ? 1 : -1) + ids.length) % ids.length])
    })
    return row
  }

  // Switch a cluster to another flow, preserving CARD POSITION: whatever
  // ordinal the creator was on in the old flow (the selected card, else the
  // member nearest the viewport centre), land on — and select — the same
  // ordinal in the new one, so same-position cards can be compared and
  // restyled flow by flow without scrolling.
  _switchFlow(clusterKey, toFlowId) {
    const fromId = this._activeFlowTabs.get(clusterKey)
    if (fromId === toFlowId) return
    let ordinal = 0
    if (fromId) {
      const fromMembers = this.flowMemberWraps(fromId)
      const selected = this._typePanelActiveCard()
      const selIdx = selected ? fromMembers.indexOf(selected) : -1
      ordinal = selIdx >= 0 ? selIdx : this._viewportFocalOrdinal(fromMembers)
    }
    this._activeFlowTabs.set(clusterKey, toFlowId)
    this._paintFlowChrome()
    const targets = this.flowMemberWraps(toFlowId)
    const target = targets[Math.min(ordinal, targets.length - 1)]
    if (!target) return
    target.scrollIntoView({ behavior: "smooth", block: "center" })
    target.click() // select it, so the right panel is ready to edit
  }

  // Which member (by index) currently sits closest to the viewport centre.
  _viewportFocalOrdinal(wraps) {
    const mid = window.innerHeight / 2
    let best = 0, bestDist = Infinity
    wraps.forEach((w, i) => {
      const r = w.getBoundingClientRect()
      const dist = Math.abs((r.top + r.bottom) / 2 - mid)
      if (dist < bestDist) { best = i; bestDist = dist }
    })
    return best
  }

  // Make sure a card is visible before jumping to it: if it sits in a
  // cluster's hidden flow, switch its cluster to that flow. Public — the
  // Flows panel, score board and flow map all jump through here.
  focusFlowForCard(cardEl) {
    const flowId = cardEl?.dataset.cardFlowId
    if (!flowId) return
    const slot = cardEl.closest(".card-slot")
    if (!slot || !slot.classList.contains("flow-hidden")) return
    for (const [ key ] of this._activeFlowTabs) {
      if (key.split("|").includes(flowId)) this._activeFlowTabs.set(key, flowId)
    }
    this._paintFlowChrome()
  }

  _flowHeaderRow(flow, count) {
    const row = document.createElement("div")
    row.className = "flow-header-row"
    row.dataset.flowId = flow.id
    row.style.setProperty("--flow-color", flow.color)
    const dot = document.createElement("span")
    dot.className = "flow-header-dot"
    dot.setAttribute("aria-hidden", "true")
    const name = document.createElement("span")
    name.className = "flow-header-name"
    name.textContent = flow.name
    const meta = document.createElement("span")
    meta.className = "flow-header-count"
    meta.textContent = t("editor.flows.header_count", { count })
    row.append(dot, name, meta)
    return row
  }

  // ── Answer-branching: per-option routing ────────────────────────────────

  // This card's routing config, in the shape LogicGraph expects. Reads the
  // inline per-option <select data-logic-route> plus the card's default
  // ("otherwise") select. Every option-bearing type routes; the match op is
  // the type's answer shape (equals / contains / first — lib/routable_types).
  _readLogic(card, type) {
    if (!ROUTABLE_TYPES.includes(type)) return null
    const op = matchOpFor(type)
    const scope = this._logicScope(card)
    const routes = []
    scope.querySelectorAll("[data-logic-route][data-canonical]").forEach(sel => {
      const label = (sel.dataset.canonical || "").trim()
      const to    = this._logicTargetFromValue(sel.value)
      if (label && to) routes.push({ match: { op, value: label }, to })
    })
    const logic = {}
    if (routes.length) logic.routes = routes
    const defSel = scope.querySelector("[data-logic-default]")
    const def    = defSel ? this._logicTargetFromValue(defSel.value) : null
    if (def) logic.default = def
    return this._hasLogic(logic) ? logic : null
  }

  _hasLogic(logic) {
    return !!(logic && ((Array.isArray(logic.routes) && logic.routes.length) || logic.default))
  }

  // Decode a route select value: "" (continue/linear), "card:<cid>",
  // "end:<id>", or "flow:<id>" — a flow resolves to its entry (first member)
  // card, recomputed here on every serialize so the route tracks the FLOW
  // through reorders, not a frozen cid. An empty flow resolves to Continue
  // (the panel warns about it) rather than a dangling target.
  _logicTargetFromValue(value) {
    if (!value) return null
    if (value.startsWith("end:"))  { const id  = value.slice(4); return id  ? { end: id }   : null }
    if (value.startsWith("card:")) { const cid = value.slice(5); return cid ? { card: cid } : null }
    if (value.startsWith("flow:")) {
      const entry = this.flowEntryCid(value.slice(5))
      return entry ? { card: entry } : null
    }
    return null
  }

  // Rebuild the <option> list of every inline route select from the CURRENT
  // deck, so targets always reflect live reorders/inserts/deletes. Each select
  // keeps its chosen value via data-logic-selected; a target that has since
  // vanished falls back to "Continue". Cheap enough (~16 cards) to run whole.
  refreshLogicTargets() {
    if (!this.logicValue) return
    const selects = this.element.querySelectorAll("[data-logic-route], [data-logic-default]")
    if (!selects.length) return
    const cfg   = this.logicConfigValue || {}
    const ends  = Array.isArray(cfg.ends) ? cfg.ends : []
    const flows = this.flowsList().map(f => ({ ...f, entryCid: this.flowEntryCid(f.id) }))
    const entryToFlow = new Map(flows.filter(f => f.entryCid).map(f => [ f.entryCid, f.id ]))
    // Flow members stay off the plain card list — a flow is targeted as a
    // whole (its optgroup entry), not by an individual member card.
    const memberCids = new Set(
      this.cardTargets.filter(c => c.dataset.cardFlowId && this.flowById(c.dataset.cardFlowId))
                      .map(c => c.dataset.cardCid).filter(Boolean)
    )
    const cards = this.cardTargets.map(c => ({
      cid: c.dataset.cardCid,
      num: c.dataset.cardNum,
      label: (c.querySelector(".q-title, .activity-title")?.textContent || "").trim().slice(0, 40)
    }))
    const cardLabel = c => c.label ? `→ Card ${c.num}: ${c.label}` : `→ Card ${c.num}`
    selects.forEach(sel => {
      // The block may have been relocated into the sidebar's Branching tab, so
      // fall back to the block's own owner-cid when it's no longer in a card.
      const ownerCid = sel.closest("[data-survey-editor-target='card']")?.dataset.cardCid
                    || sel.closest("[data-logic-block]")?.dataset.ownerCid
      let chosen = sel.dataset.logicSelected || ""
      // Upgrade a raw card target to its flow when that cid is a flow's entry:
      // from here on the route tracks the FLOW, so reordering members (which
      // changes which card is the entry) re-resolves automatically.
      if (chosen.startsWith("card:") && entryToFlow.has(chosen.slice(5))) {
        chosen = `flow:${entryToFlow.get(chosen.slice(5))}`
        sel.dataset.logicSelected = chosen
      }
      sel.innerHTML = ""
      sel.appendChild(this._logicOption("", cfg.continue || t("editor.logic_continue")))
      if (flows.length) {
        const group = document.createElement("optgroup")
        group.label = t("editor.flows.group")
        flows.forEach(f => {
          const label = f.entryCid ? t("editor.flows.option", { name: f.name })
                                   : `${t("editor.flows.option", { name: f.name })} ${t("editor.flows.empty_suffix")}`
          group.appendChild(this._logicOption(`flow:${f.id}`, label))
        })
        sel.appendChild(group)
      }
      ends.forEach(e => sel.appendChild(this._logicOption(`end:${e.id}`, `${cfg.finishPrefix || "Finish"} · ${e.label}`)))
      cards.forEach(c => {
        if (!c.cid || c.cid === ownerCid || memberCids.has(c.cid)) return
        sel.appendChild(this._logicOption(`card:${c.cid}`, cardLabel(c)))
      })
      // A legacy/map-set route can point INTO a flow (a hidden member cid) —
      // keep it resolvable rather than silently resetting it to Continue.
      if (chosen.startsWith("card:") && memberCids.has(chosen.slice(5))) {
        const c = cards.find(x => x.cid === chosen.slice(5))
        if (c) sel.appendChild(this._logicOption(`card:${c.cid}`, cardLabel(c)))
      }
      // Per-answer selects (not the "otherwise") close with a create action:
      // picking it spins up a flow named after the answer (see logicRouteChanged).
      if (!this.liveValue && sel.hasAttribute("data-logic-route")) {
        sel.appendChild(this._logicOption("__new_flow__", t("editor.flows.new_from_answer")))
      }
      sel.value = chosen
      if (sel.value !== chosen) { sel.value = ""; sel.dataset.logicSelected = "" } // target gone ⇒ fall through
    })
  }

  _logicOption(value, label) {
    const o = document.createElement("option")
    o.value = value
    o.textContent = label
    return o
  }

  // Persist the creator's route choice so a later refresh keeps it, then save.
  logicRouteChanged(event) {
    const sel = event.currentTarget
    // The "+ New flow from this answer…" action option: hand off to the Flows
    // panel (which creates the flow + its first card, then wires this select)
    // and restore the previous selection meanwhile.
    if (sel.value === "__new_flow__") {
      sel.value = sel.dataset.logicSelected || ""
      this.application.getControllerForElementAndIdentifier(this.element, "flows")
        ?.createFromRouteSelect(sel)
      return
    }
    sel.dataset.logicSelected = sel.value
    this.markDirty()
  }

  // Keep a routable card's Branching-tab rows in step with its live answer
  // options: one row per option, in document order, each remembering its chosen
  // route. Fires when options are added/removed (card-editor:changed) or an
  // option label is edited (focusout). Routes are keyed by the option label (its
  // canonical), so each chosen target is carried across the rebuild by a stable
  // per-option uid — surviving renames — with the row label and the select's
  // canonical updated to the option's current text.
  syncBranchingEvent(event) {
    const card = event.target?.closest?.("[data-survey-editor-target='card']")
    if (!card) return
    // On focusout, only react to leaving an option label — not every field blur.
    if (event.type === "focusout" && !event.target.closest?.(".pick-text")) return
    this.syncBranchingFor(card)
  }

  syncBranchingFor(cardEl) {
    if (!this.logicValue || !cardEl) return
    // Only types whose option LISTS are edited live in the card need their
    // branching rows rebuilt (yes_no is fixed; the scales key routes by
    // numeric position and don't expose their option lists in the editor).
    if (!OPTION_EDITED_TYPES.includes(cardEl.dataset.cardType)) return
    const scope = this._logicScope(cardEl)
    const list  = scope.querySelector(".logic-branch-list")
    if (!list) return

    // Prior chosen route per option — by uid (survives renames), then by label,
    // then by position (covers a rename made before any uid was assigned).
    const byUid = new Map(), byLabel = new Map(), byIndex = []
    list.querySelectorAll(".logic-branch-row").forEach(row => {
      const sel = row.querySelector("[data-logic-route]")
      if (!sel) return
      const val = sel.dataset.logicSelected || sel.value || ""
      byIndex.push(val)
      if (row.dataset.optUid) byUid.set(row.dataset.optUid, val)
      if (sel.dataset.canonical) byLabel.set(sel.dataset.canonical, val)
    })

    // Rebuild one row per current option, in order, carrying each route across.
    list.textContent = ""
    this._optionEls(cardEl).forEach((optEl, i) => {
      const label = optEl.textContent.trim()
      if (!label) return
      let uid = optEl.dataset.optUid
      if (!uid) { uid = String(this._optUidSeq = (this._optUidSeq || 0) + 1); optEl.dataset.optUid = uid }
      const val = byUid.has(uid) ? byUid.get(uid)
                : byLabel.has(label) ? byLabel.get(label)
                : (byIndex[i] || "")
      list.appendChild(this._branchRow(uid, label, val))
    })
    this.refreshLogicTargets() // fill the (possibly new) selects' option lists + values
  }

  // One "AnswerLabel → [route select]" row, matching shared/_logic_branch_block.
  _branchRow(uid, label, selected) {
    const row = document.createElement("li")
    row.className = "logic-branch-row"
    row.dataset.optUid = uid
    const answer = document.createElement("span")
    answer.className = "logic-branch-answer"
    answer.textContent = label
    const arrow = document.createElement("span")
    arrow.className = "logic-branch-arrow"
    arrow.setAttribute("aria-hidden", "true")
    arrow.textContent = "→"
    const sel = document.createElement("select")
    sel.className = "logic-route-select"
    sel.setAttribute("data-logic-route", "")
    sel.dataset.canonical = label
    sel.dataset.logicSelected = selected || ""
    sel.dataset.action = "input->survey-editor#logicRouteChanged change->survey-editor#logicRouteChanged"
    sel.onclick = (e) => e.stopPropagation()
    row.append(answer, arrow, sel)
    return row
  }

  // Mark / unmark an option as correct. Single-choice acts like a radio.
  toggleCorrect(event) {
    event.stopPropagation()
    const btn  = event.currentTarget
    const item = btn.closest('[data-picker-target="item"]')
    if (!item) return
    const turnOn = item.dataset.correct !== "true"
    if (btn.dataset.pickerMode === "single") {
      item.closest(".choice-list, .choice-grid")
          ?.querySelectorAll('[data-picker-target="item"]')
          .forEach(el => { el.dataset.correct = "false" })
    }
    item.dataset.correct = turnOn ? "true" : "false"
    this.markDirty()
  }

  // Set / clear the correct swipe direction for one tap_card statement.
  toggleTapCorrect(event) {
    event.stopPropagation()
    const btn = event.currentTarget
    const row = btn.closest(".quiz-tap-row")
    if (!row) return
    row.dataset.correctDir = (row.dataset.correctDir === btn.dataset.dir) ? "" : btn.dataset.dir
    row.querySelectorAll(".quiz-tap-btn").forEach(b => b.classList.toggle("is-on", b.dataset.dir === row.dataset.correctDir))
    this.markDirty()
  }

  // Switch a choice-shaped card between awarding tokens per chosen option
  // and a flat award just for completing the question (see
  // TokenGrading.completion_award?). Both sections stay in the DOM (this
  // just swaps which is visible) so switching back and forth never loses
  // amounts already entered on either side.
  setTokenAwardMode(event) {
    const btn   = event.currentTarget
    const mode  = btn.dataset.mode
    const block = btn.closest(".token-award-block")
    if (!block) return
    block.querySelectorAll(".token-mode-btn").forEach(b => b.classList.toggle("is-active", b.dataset.mode === mode))
    block.querySelectorAll("[data-token-mode-section]").forEach(sec => {
      sec.hidden = sec.dataset.tokenModeSection !== mode
    })
    this.markDirty()
  }

  async save(event) {
    event?.preventDefault()
    if (this.hasSaveButtonTarget) this.saveButtonTarget.disabled = true
    this.flash(t("editor.saving"), "text-smoke/60")
    clearTimeout(this._saveTimer)
    await this._doSave()
    if (this.hasSaveButtonTarget) this.saveButtonTarget.disabled = false
  }

  async _doSave() {
    if (!this.hasUrlValue || !this.urlValue) return
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      // Which revision this request is about to carry. Captured before
      // serialize() builds the body, so anything typed while the request is in
      // flight lands on a LATER generation and the completion below leaves
      // _dirty alone.
      const gen = this._editGen
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify(this.serialize())
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const json = await res.json()
      // Only clear the flag if nothing was edited while this request was out.
      // A bare `this._dirty = false` here marked those edits clean: markDirty
      // had already re-armed the 1.5s timer, but flushSave — the
      // pagehide/visibilitychange safety net — skips when _dirty is false, so
      // closing the tab inside that window silently dropped them.
      if (gen === this._editGen) this._dirty = false
      // The save itself succeeded, but the server may have silently repaired
      // the deck — dropped an oversized/invalid image, removed a duplicate
      // welcome card, moved the consent gate (sanitize_cards_images! fixes
      // rather than erroring) — so say WHICH, instead of just "Saved".
      if (Array.isArray(json.warnings) && json.warnings.length) {
        const details = Array.isArray(json.warning_details) ? json.warning_details : []
        this._clearDroppedMedia(details)
        this.flash(this._saveWarningMessage(json.warnings, details), "text-hot-pink")
      } else {
        this.flash(t("editor.saved", { time: new Date(json.updated_at).toLocaleTimeString() }), "text-aquamarine")
      }
    } catch (err) {
      this.flash(t("editor.save_failed", { msg: err.message }), "text-hot-pink")
    }
  }

  // The sentence for a save response's `warnings` — the FIRST code the table
  // knows (the server lists a card's media codes before the deck-level
  // structural passes, so a dropped image outranks a moved gate), one sentence
  // only because the status pill is a single nowrap line. Membership in
  // SAVE_WARNING_KEYS decides the fallback, not a t() miss: t() returns the
  // raw dotted key for an unknown one.
  //
  // When the server also says WHICH card lost its picture (`warning_details`),
  // the sentence names it by number. "An image didn't stick" was true of the
  // deck and said nothing about the card: a creator who had just uploaded a
  // picture read it as being about that one — which had saved fine — while the
  // card that had actually lost its image went unchecked.
  _saveWarningMessage(codes, details = []) {
    const code = codes.find((c) => SAVE_WARNING_KEYS[c])
    const key  = SAVE_WARNING_KEYS[code] || "editor.save_warning"
    if (key === "editor.save_warning") {
      const card = this._droppedImageCard(details)
      if (card) return t("editor.save_warning_card", { n: card.dataset.cardNum })
    }
    return t(key)
  }

  // The first card the response names as having lost a picture, or null.
  _droppedImageCard(details) {
    for (const d of details) {
      if (!CARD_IMAGE_CODES.includes(d?.code)) continue
      const card = this._cardByCid(d.cid)
      if (card) return card
    }
    return null
  }

  _cardByCid(cid) {
    if (!cid) return null
    return this.cardTargets.find((c) => c.dataset.cardCid === String(cid)) || null
  }

  // Take a dropped picture off the page as well. serialize() rebuilds every
  // card from the DOM and nothing reads the deck back from a save, so an image
  // the server had already refused stayed on screen looking saved — and was
  // re-sent, re-dropped and re-warned on every autosave until a reload. Written
  // through the media picker's own writers (the ones setup_status uses too),
  // which mark nothing dirty: no save is scheduled, and the next genuine edit
  // simply sends what the server already holds. A card whose panel is an
  // animation keeps it — _setCardImage blanks the lottie as well, and the
  // server kept that one.
  _clearDroppedMedia(details) {
    const picker = this.application.getControllerForElementAndIdentifier(this.element, "media-picker")
    if (!picker) return
    details.forEach((d) => {
      const card = this._cardByCid(d?.cid)
      if (!card) return
      if (d.code === "image" && !card.dataset.cardLottie) picker._setCardImage(card, "")
      if (d.code === "option_images" && Number.isInteger(d.index)) picker._setTapOptionImage(card, d.index, "")
      // A refused backdrop image, for the same reason: left on the card it
      // would be re-sent, re-dropped and re-warned on every autosave. The
      // colour stays — only the picture was refused.
      if (d.code === "media_bg") {
        const kept = picker._readAnimBg(card)
        picker._writeAnimBg({ color: kept.color }, card, { notify: false })
      }
    })
  }

  // Plural, like undoBtnTargets: the mobile studio hides the float bar this
  // pill lives in, so a creator typing on a phone had no save state at all —
  // the words were written, to an element CSS had taken off the screen. The
  // chrome carries its own chip; both are fed from here so there is still one
  // sentence about saving, said in two places.
  flash(text, klass) {
    this.statusTargets.forEach((el) => {
      el.textContent = text
      el.className = `text-xs ${klass}`
    })
  }

  // Save-status relay for the in-feed consent/thank-you gate cards —
  // gate_cards_controller persists them via update_settings rather than the
  // card autosave, so their saves surface in the same top-left status pill.
  gateStatus(event) {
    const { state, time, msg } = event.detail || {}
    if (state === "saving")     this.flash(t("editor.saving"), "text-smoke/60")
    else if (state === "saved") this.flash(t("editor.saved", { time }), "text-aquamarine")
    else if (state === "error") this.flash(t("editor.save_failed", { msg }), "text-hot-pink")
  }

  // Same pill, for an IMPORT's imagery arriving behind the creator. Until this
  // existed the editor said nothing at all while FinishVertoSetupJob ran, so a
  // deck that was about to fill with pictures was indistinguishable from one
  // that never would — which is how "images didn't generate" gets reported for
  // a job that was working. See setup_status_controller.js.
  setupStatus(event) {
    const { state } = event.detail || {}
    if (state === "running")   this.flash(t("editor.setup_finding_images"), "text-smoke/60")
    else if (state === "done") this.flash(t("editor.setup_images_ready"), "text-aquamarine")
  }
}
