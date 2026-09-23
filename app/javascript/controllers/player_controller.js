import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { haptic } from "lib/haptics"
import { presetFor, DEFAULT_TAP_COUNT } from "lib/tap_scales"
import { visibleBandEnd } from "lib/visible_band"
import { NON_QUESTION_TYPES } from "lib/question_types"

const MAP_MIN_SCALE = 1
const MAP_MAX_SCALE = 8

// Mirrors Player::MIN_PASSWORD. Duplicated rather than threaded through as a
// Stimulus value because the same number appears in the partial's `minlength`
// and in the hint under the field, and the server enforces it regardless —
// this only lets the browser say so before the round trip.
const JOIN_MIN_PASSWORD = 12

// The join endpoint's refusals, mapped to what the person is told. Anything
// unlisted falls through to join_failed: a new server-side code must not
// render as a blank error or as a raw key.
const JOIN_ERRORS = {
  email:          "player.join_invalid",
  password_short: "player.join_password_short",
  credentials:    "player.join_credentials",
  too_many:       "player.join_too_many",
  unavailable:    "player.join_unavailable",
  use_google:     "player.join_use_google"
}

// Cards that ask for agreement rather than an answer, and drive their own
// navigation. "consent_gate" is the multi-page card type a creator can place
// and reorder like any other. The survey-level gate (from consent_text) is no
// longer a card at all — it renders as the bottom banner in
// player/_consent_banner, whose whole state is the overlay's
// data-consent-pending attribute. A Verto has one gate or the other —
// Survey#consent_required? goes false once a consent_gate card exists — which
// is also why the banner and the card can share the consentMain/
// consentDeclined targets and the agreeConsent action without colliding.
const CONSENT_TYPES = [ "consent_gate" ]

// Cards that drive their own navigation, so the deck's Back/Next/Finish are
// hidden while one is showing. The consent shapes above, plus the
// respondent-code gate.
// `respondent_code` is the CARD TYPE; `respondent_code_card` is the survey-level
// pre-screen's pseudo-card, which the card supersedes but which existing Vertos
// still use. Both drive their own navigation, so both belong here.
const SELF_DRIVING_TYPES = [ ...CONSENT_TYPES, "respondent_code", "respondent_code_card", "contact_gate_card" ]

// Respondent-local text-size preference (the "Aa" pill) — a person's own
// reading accessibility need, not a per-Verto setting, so it's one fixed key
// rather than scoped by survey/submit URL like verto_played_* above.
const FONT_SCALE_KEY    = "verto_font_scale"
const FONT_SCALE_STEPS  = [ "default", "large", "larger" ]

// Retired. "Lite" was a respondent-local data-saving toggle that hid the hero
// image, the option artwork, autoplaying video and looping Lottie. Because the
// preference was browser-wide rather than per-Verto, one tap stripped the
// imagery from every Verto that browser would ever play, and the pill said only
// "Lite" — so it read as the platform losing its images, and was reported as
// exactly that (20 Aug). The toggle is gone; this key is cleared on load so a
// respondent still carrying it isn't left wondering where the pictures went.
const RETIRED_LITE_MODE_KEY = "verto_lite_mode"

// The hidden Test Mode hatch (player/_test_mode_hatch). Two deliberate acts,
// both timed: hold the unlabelled hotspot this long to arm the confirm chip,
// and the chip stays live only this long before it hides itself again. HOLD is
// well past the ~500ms a browser calls a long-press and past any accidental
// resting finger; ARM is long enough to read the chip's label and decide, short
// enough that it is gone by the time anyone drifts back. SLOP disarms the
// moment the gesture looks like a scroll or a swipe instead of a hold.
const TEST_HOLD_MS      = 2000
const TEST_ARM_MS       = 5000
const TEST_HOLD_SLOP_PX = 12

export default class extends Controller {
  static targets = ["card", "backBtn", "nextBtn", "finishBtn", "thankyou", "progress",
                    "thankyouMain", "thankyouTitle", "thankyouSub", "forwardBtn", "compareBtn", "comparePanel",
                    "scoresSection", "comparisonSection",
                    "comparisonList", "comparisonMeta",
                    "regionsBtn", "regionsPanel", "regionsMain", "regionsMeta", "regionsList",
                    "regionsMapViewport", "regionsMapStage",
                    "regionDetail", "regionDetailTitle", "regionDetailList", "shareBtn", "requiredHint",
                    "consentBanner", "consentMain", "consentDeclined", "respondentCode",
                    "contactName", "contactEmail", "contactCompany", "contactIndustry",
                    "scoreChip", "quizScore", "scoresList", "scoresMeta",
                    "tokenScoreChip", "tokenScore", "leaderboard", "fontScaleBtn",
                    "joinBlock", "joinAsk", "joinAlso", "joinAlsoBox", "joinAlsoLabel",
                    "joinEmbedded", "joinEmail", "joinPassword", "joinBtn", "joinGoogleBtn",
                    "joinError", "joinDone", "joinReveal", "joinForm",
                    "testConfirm"]
  static values  = {
    progressUrl: { type: String, default: "" },
    submitUrl: String,
    consentUrl: { type: String, default: "" },
    resultsUrl: { type: String, default: "" },
    regionsUrl: { type: String, default: "" },
    locale: { type: String, default: "" },
    shareUrl: { type: String, default: "" },
    shareTitle: { type: String, default: "" },
    shareText: { type: String, default: "" },
    showComparison: { type: Boolean, default: false },
    quiz: { type: Boolean, default: false },
    gradeUrl: { type: String, default: "" },
    quizStateUrl: { type: String, default: "" },
    scoresUrl: { type: String, default: "" },
    // Ask-once recall (Survey#respondent_code_recall?). Blank unless the
    // creator turned it on AND there is a live token to reach — owner preview
    // and Test Mode must never be able to read a real respondent's answers
    // back, which is the same rule grade_url and scores_url follow.
    recallUrl: { type: String, default: "" },
    tokenisation: { type: Boolean, default: false },
    // The contact gate is on (Survey#contact_form_enabled) — mints the durable
    // player key and sends the gate's details with the ordinary saves.
    contact: { type: Boolean, default: false },
    tokenTypes: { type: Array, default: [] },
    // The creator's sentence above the final tally, blank when they wrote
    // none. Plain text, not rich: it is a setting, not card copy.
    tokensResultNote: { type: String, default: "" },
    // Show each answer's own award as the respondent leaves the card, on top of
    // the running total (see _revealTokenEarn).
    tokenReveal: { type: Boolean, default: false },
    // Let a respondent return to a tokenised card they left unanswered and
    // still earn its points — what the server has always permitted.
    tokenBackNav: { type: Boolean, default: false },
    // Leaderboard: on only when tokenisation is too (leaderboard_active?).
    // The URL is blank in owner preview and Test Mode, which is what keeps the
    // board (and the durable player key) out of those contexts.
    leaderboard: { type: Boolean, default: false },
    leaderboardUrl: { type: String, default: "" },
    // Respondent accounts: POST here to be mailed a sign-in link. Blank in
    // owner preview and Test Mode, and blank whenever the creator has the
    // block switched off — _renderJoinState reveals nothing without it.
    joinUrl: { type: String, default: "" },
    // Continue with Google, from the same card. Blank on exactly the same
    // terms as joinUrl (it is derived from it) and additionally blank when the
    // strategy has no credentials configured — the button isn't rendered then
    // either, so this is the belt to that view condition's braces.
    joinGoogleUrl: { type: String, default: "" },
    // No going back: once the respondent moves on from a card its answer is
    // final — Back is hidden, the card is locked, and every advance is saved
    // so the server (locked_merge) holds each answer it pins.
    noGoingBack: { type: Boolean, default: false },
    // No retests: "" (off), "code" (the respondent code is the identity; the
    // server refuses at the code step and on every write) or "device" (no
    // code is collected, so the durable player key plus the local played
    // marker stand in). Never both — see Survey#retest_basis.
    noRetests: { type: String, default: "" },
    // The open wave's position ("1" while wave 1 is implicit). Keys the local
    // played marker, so starting a new wave frees every device.
    wave: { type: String, default: "" },
    // Blank unless the identity is the code — and in owner preview / Test Mode.
    eligibilityUrl: { type: String, default: "" },
    // Answer-branching: when on, next()/back() follow the answer-logic graph
    // instead of stepping linearly. Off ⇒ byte-identical linear behaviour.
    logic: { type: Boolean, default: false },
    // The resolved end screens (id/title/body/forward_url/forward_label). A
    // branch can finish on a specific one; _goToEnd records which via _endId.
    endScreens: { type: Array, default: [] },
    forwardLabel: { type: String, default: "" },
    current: { type: Number, default: 0 },
    // Form mode: same flow, but drop the game-like haptic buzz so it reads as a
    // plain questionnaire (motion/swipe are stripped via CSS + tap_stack).
    forms: { type: Boolean, default: false },
    // Where the hidden Test Mode hatch goes. Blank in owner preview and in Test
    // Mode itself, and the hatch is inert while it is blank — so the one page
    // that must never carry a live endpoint doesn't gain one here either.
    testModeUrl: { type: String, default: "" }
  }

  // Haptic feedback, suppressed in form mode.
  _buzz(pattern) {
    if (!this.formsValue) haptic(pattern)
  }

  _answers = {}
  _registered = false
  _regionsData = null

  // Answer-branching state: the visited-card stack (cardTarget indices, so
  // back() retraces the taken path, not idx-1), a hop budget that guarantees
  // termination on a malformed/looping graph, a cid→index lookup, and the end
  // screen a route sent us to (used once multiple end screens exist).
  _path = [0]
  _hops = 0
  _cidIndex = new Map()
  _endId = "default"

  // Regions map pan/zoom state — plain translate/scale, no external library.
  _mapScale = 1
  _mapX = 0
  _mapY = 0
  _mapPointers = new Map()
  _mapDragMoved = false
  _mapDragStart = { x: 0, y: 0 }
  _mapPinchStartDist = 0
  _mapPinchStartScale = 1

  // Quiz state: which card indices have been answered+revealed (so they can't
  // be redone), and the running score.
  _revealed = new Set()
  _quizScore = 0
  _quizMax = 0
  _scoresData = null

  // Tokenisation state: which card indices have already contributed to the
  // running total (so they can't be redone), and the running totals
  // themselves, keyed by token type id.
  _tokenLocked = new Set()
  _tokenTotals = {}

  // Card indices the respondent has actually interacted with — see
  // _markTouched for why the Next button's glow needs this and _read doesn't.
  _touched = new Set()

  connect() {
    // The one signal sw_register.js reads before its corrective reload on
    // controllerchange: any gesture inside the player means a reload could
    // destroy respondent state (answers, the respondent code and a consent
    // decline all live only in memory/DOM until a save), so it must stand
    // down. Capture-phase so it fires whichever nested handler takes the
    // tap; `once` so it costs a single call.
    for (const type of ["pointerdown", "keydown"]) {
      this.element.addEventListener(type, () => { window.playvertoEngaged = true },
        { capture: true, once: true, passive: true })
    }
    // Embedded (see PlayerController#allow_embedding): tell the host page the
    // player actually booted. A same-origin host could look for this element
    // itself, but a Verto embedded from a downloaded HTML file is cross-origin,
    // and there a refused or broken frame is indistinguishable from a working
    // one — so the host waits for this and falls back to its own content if it
    // never arrives.
    if (window.parent !== window) {
      try { window.parent.postMessage({ verto: "ready" }, "*") } catch (_e) { /* host gone */ }
    }
    // Which intro modals this run has already shown. Read up here rather than
    // beside the first _update(), because _update() is reached from several
    // paths (the quiz state restore, the already-played branch) and every one
    // of them asks this set whether to open a modal.
    this._modalSeen = this._loadModalSeen()

    this._sessionToken = this._ensureToken()
    // The durable identity is minted for the leaderboard, the contact gate,
    // or any ask-once question — for contacts it is the only bridge between
    // the volunteered details and the pseudonymous responses, and for
    // ask-once it is the identity the "asked once" promise is made to
    // (Survey#player_identity_active? mirrors this server-side). No retests
    // on a Verto that collects no code needs it too — the device is then the
    // only identity it can check.
    this._hasAskOnce = this.cardTargets.some(c => c.dataset.cardAskOnce === "true")
    if (this.leaderboardValue || this.contactValue || this._hasAskOnce || this.noRetestsValue === "device") {
      this._playerKey = this._ensurePlayerKey()
    }
    this._nextLabel   = this.hasNextBtnTarget   ? this.nextBtnTarget.textContent   : ""
    this._finishLabel = this.hasFinishBtnTarget ? this.finishBtnTarget.textContent : ""
    // A device that already went through the contact gate (submitted or
    // skipped) starts past it: the gate is a first-visit register, not a toll
    // on every replay. Before _path so the taken path never contains it.
    this._skipContactGateIfDone()
    // Remembered ask-once answers seed this run before the first paint, and
    // the starting card walks past any leading remembered questions.
    this._seedOnceAnswers()
    while (this._isOnceSkipped(this.currentValue) &&
           this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
    }
    this._path = [this.currentValue]
    this._hops = 0
    if (this.logicValue) {
      this._cidIndex = new Map(this.cardTargets.map((c, i) => [c.dataset.cardCid, i]))
    }
    // No retests, device basis: a device that already finished this wave lands
    // on the thank-you screen (with the board, where there is one) instead of
    // starting a run the server would refuse. Best-effort by design — cleared
    // storage gets someone back in, and the server's refusal of the first
    // write is the backstop. On the code basis the device must NOT gate: the
    // next pupil on a shared classroom tablet has their own code, and a
    // returning code is told so at the code step instead (_eligibility).
    if (this.noRetestsValue === "device" && this.submitUrlValue && this._playedBefore()) {
      // The board, not the questions — there is nothing left to consent to,
      // and a banner over the standings would shadow them for no one's
      // benefit. Cleared without recording anything.
      this._clearConsentPending()
      this._showAlreadyPlayed()
      return
    }
    // Before the first render, so the very first card already paints at the
    // remembered size instead of flashing default-size and then jumping.
    this._applyFontScale(this._loadFontScale())
    this._clearRetiredLiteMode()
    // Same reason, one layer down: --play-card-h is what every tier's hero and
    // answer panel is a share of, so it has to be right before the first card
    // is laid out, not corrected after it.
    this._fitCardHeight()
    this._update()
    // The survey-level consent banner (player/_consent_banner). The state was
    // server-rendered — data-consent-pending on the overlay, inert on the deck
    // — so a reload lands exactly where the first paint did; all that is left
    // to JS is to start keyboard users in the one live surface.
    if (this.element.hasAttribute("data-consent-pending") && this.hasConsentBannerTarget) {
      this.consentBannerTarget.focus()
    }
    if (this.quizValue) this._initQuiz()
    if (this.tokenisationValue) this._initTokens()
    if (this.hasRegionsMapViewportTarget) this._setupMapPanZoom()
    this._watchFooterFit()
    this._watchCardHeight()
    this._watchTyping()

    // Live answered-state for the Next button. Delegated on the deck rather
    // than wired per widget: every answer type ultimately lands as a pointer
    // press, a click, a typed character — or an OPERATING key. keydown is on
    // the list because every widget's keyboard path (picker Enter/Space,
    // slider and rating arrows) mutates the answer on keydown with
    // preventDefault, so no click is ever synthesized and none of the other
    // four events fire: a keyboard respondent used to answer correctly and
    // watch the button stay dark until they navigated.
    //
    // CAPTURE phase, because several widgets stop the bubble — rating_controller
    // calls stopPropagation() on every pick, so a bubble-phase listener here
    // never hears a star being chosen. Capture runs on the way DOWN, before
    // anything can stop it.
    //
    // Which means the read has to be deferred, and NOT with a microtask: the
    // browser takes a microtask checkpoint between listener invocations, so a
    // microtask queued in the capture phase runs BEFORE the picker's own
    // handler has selected anything, and the button stays dark until the next
    // unrelated event nudges it. A frame is the right unit — it lands after
    // the whole dispatch, and before the paint that has to show the glow.
    //
    // OPERATE_KEYS is a filter, not a nicety. _markTouched runs on every event
    // here, and marking is what lets a first-paint value count as an answer —
    // the Range slider renders with its thumb mid-scale precisely so _touched
    // can hold the glow until the respondent actually does something. A bare
    // keydown would mark a card when a keyboard user merely Tabs ACROSS it,
    // and the untouched slider would greet the next Tab already lit. So only
    // the keys that operate a widget count; Tab, Escape and friends do not.
    // (Every widget's key set today: Enter, Space, arrows; Home/End for the
    // sliders.)
    const OPERATE_KEYS = [ "Enter", " ", "ArrowUp", "ArrowDown", "ArrowLeft",
                           "ArrowRight", "Home", "End" ]
    for (const evt of [ "pointerdown", "click", "input", "change", "keydown" ]) {
      this.element.addEventListener(evt, (e) => {
        if (e.type === "keydown" && !OPERATE_KEYS.includes(e.key)) return
        this._markTouched(e)
        this._queueAnsweredSync()
        // `input` as well as `click`: a freeform answer grows its textarea as
        // it is typed, which changes what the card can afford, and a click was
        // never going to arrive to tell us about it.
        if (e.type === "click" || e.type === "input") {
          requestAnimationFrame(() => this._fitCard())
        }
      }, { capture: true, passive: true })
    }
  }

  // One tap is a pointerdown AND a click; coalesce them into a single read.
  _queueAnsweredSync() {
    if (this._answeredFrame) return
    this._answeredFrame = requestAnimationFrame(() => {
      this._answeredFrame = null
      this._syncAnswered()
    })
  }

  disconnect() {
    this._footerObserver?.disconnect()
    this._bodyObserver?.disconnect()
    if (this._answeredFrame) cancelAnimationFrame(this._answeredFrame)
    clearTimeout(this._revealTimer)
    // The scroll cue is two chained timers and a set of listeners on window;
    // left running they fire against whatever replaced the deck.
    clearTimeout(this._nudgeDown)
    clearTimeout(this._nudgeUp)
    clearTimeout(this._nudgeRetry)
    if (this._nudgeFrame) cancelAnimationFrame(this._nudgeFrame)
    this._nudgeAbort?.()
    // kbd-open lives on <html>, outside this controller's element, so it does
    // NOT go away with the deck. Left behind it would guard _fitCard on
    // whatever renders next (the thank-you screen, a Turbo visit) and that
    // card would keep whatever hero state it happened to have.
    document.documentElement.classList.remove("kbd-open")
    this._clearTestTimers()
  }

  // ── Footer: answered glow + the cramped-bar fallback ─────────────────────

  // Light the primary button once the card holds an answer — per the answer
  // TYPE's own rule, which is the only definition that means anything: one
  // star is a rating, one tick is a multi-select, a moved thumb is a scale,
  // a non-blank string is an open question. _answerOf/_read own that table
  // (and the server agrees with it — see test/system/answer_parity_test.rb).
  //
  // Which cards the respondent has actually put a finger on. A Range slider
  // renders with its thumb at the middle of the scale and a dot already
  // marked active, so _read gives it a value from the moment it paints — and
  // the button would greet the respondent already lit, which is the one thing
  // this feature must not do. What _read returns is left alone (the server
  // grades against the same table — test/system/answer_parity_test.rb); the
  // GLOW is what gets the extra condition, because the glow is feedback for
  // something you did.
  _markTouched(event) {
    const card = event.target?.closest?.(".preview-card")
    if (card?.dataset.cardIndex) this._touched.add(card.dataset.cardIndex)
  }

  _syncAnswered() {
    const card = this.cardTargets[this.currentValue]
    const key  = card?.dataset.cardIndex
    // Touched now, or answered on an earlier pass and stepped back to.
    const owned = key != null &&
      (this._touched.has(key) || this._isAnswerGiven(this._answers[key]))
    const answered = !!card && owned && this._isAnswerGiven(this._answerOf(card))

    for (const btn of [ this.hasNextBtnTarget   && this.nextBtnTarget,
                        this.hasFinishBtnTarget && this.finishBtnTarget ]) {
      if (btn) btn.classList.toggle("is-answered", answered)
    }
  }

  // Back and Next carry a translated label ("← Back", "Weiter →", "Enviar ✓"),
  // and on a narrow phone — or a wide one once the quiz and points chips are
  // sharing the bar — those labels stop fitting. Rather than guess a breakpoint
  // that only holds for English, measure: nowrap means a label that no longer
  // fits overflows its button, and an overflowing button is the definition of
  // cramped. The CSS then drops both to arrow-only CTAs.
  // How wide the label actually wants to be. NOT scrollWidth: on an element
  // with `overflow: visible` — which a pill button is — browsers report
  // scrollWidth as the padding box and ignore text spilling out of it, so it
  // always answers "it fits". A Range over the button's contents measures the
  // laid-out text itself, which is the number this needs.
  _labelWidth(btn) {
    const range = document.createRange()
    range.selectNodeContents(btn)
    const w = range.getBoundingClientRect().width
    range.detach?.()
    return w
  }

  _fitFooter() {
    const footer = this._footerEl ||= this.element.querySelector(".preview-footer")
    if (!footer) return

    // Measure at full size. The collapsed state zeroes the label, so leaving
    // the class on would make the next measurement say "it fits" and flip the
    // buttons back and forth.
    footer.classList.remove("is-tight")
    const tight = [ this.hasBackBtnTarget   && this.backBtnTarget,
                    this.hasNextBtnTarget   && this.nextBtnTarget,
                    this.hasFinishBtnTarget && this.finishBtnTarget ]
      .filter(b => b && !b.classList.contains("hidden"))
      .some(b => {
        const cs = getComputedStyle(b)
        const room = b.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
        return room > 0 && this._labelWidth(b) > room + 1
      })
    footer.classList.toggle("is-tight", tight)
  }

  // ── What the card can afford ────────────────────────────────────────────
  //
  // This used to render everything and then strip until it stopped hurting.
  // That reads fine and behaves badly: a degradation path has no bottom, so
  // whatever is cheapest to shave keeps getting shaved — which is how the
  // option labels ended up at 11px. So it runs the other way now. Start from
  // what the card cannot do without — the question, the answer widget, the
  // footer — and BUY BACK the imagery, in priority order, only while the card
  // can pay for it.
  //
  // The price of everything is measured in one currency: how much of the
  // answer ends up off the bottom of the screen. At the floor that number is
  // whatever the options themselves cost — six options on a short phone are
  // six options, and no amount of shedding changes it — so the floor's figure
  // is the DEBT, and an enhancement is affordable when it doesn't add to it.
  //
  // Two rungs, bought in this order:
  //
  //   1. The option artwork, because a tile is part of the ANSWER — it is how
  //      one option tells itself apart from the next.
  //   2. The card's hero image, which is decoration and goes last.
  //
  // Both on the same terms: free, or not at all. There is deliberately no
  // "it's only a bit over" allowance. The old code had one — start shedding
  // once more than a third of the answer is hidden — and it was the right
  // shape for a question this no longer asks. As a TRIGGER ("is it bad enough
  // to act?") a threshold is reasonable. Re-read as a LICENCE ("may I spend
  // this?") the same number let a sideways phone buy tile artwork that pushed
  // 29% of the options off screen, when the undecorated list had shown all of
  // them. A respondent can answer a question with no photograph on it. They
  // cannot answer one whose options are below the fold.
  //
  // Measured rather than guessed, because how much room an answer needs
  // depends on the option count, the label lengths, the question's own height
  // and the phone, and no breakpoint knows any of that. Nothing paints
  // mid-flight: reading scrollHeight forces layout synchronously, so all of
  // this resolves inside one task and the browser paints once, already
  // correct. And it starts from the floor every time, so a card that gained
  // room back (a rotation, the keyboard closing) buys its pictures again
  // instead of staying stripped for the rest of the deck.
  //
  // The widget, the question and the footer are never on the list.
  _fitCard() {
    // Not while someone is typing. The guard outlived the ladder it was written
    // for — there is no longer anything here that could buy the hero back on
    // top of the keyboard — but it still earns its place: with
    // interactive-widget=resizes-content the layout viewport shrinks on
    // keyboard open, which resizes the footer, which fires _watchFooterFit's
    // observer. Unguarded, the scroll cue would be recomputed against a
    // half-open keyboard between keystrokes.
    // _watchTyping's blur branch clears kbd-open BEFORE calling back in here,
    // so the cue is still re-decided once the answer has its room again.
    if (document.documentElement.classList.contains("kbd-open")) return
    const card = this.cardTargets[this.currentValue]
    if (!card) return
    const box = card.querySelector(".split-right > .mt-2")
    if (!box) return

    // This used to be a shed ladder. It priced the undecorated answer as a
    // debt, then bought back the option artwork and then the hero, each only
    // while it stayed free — so a card that could not afford its picture gave
    // it up rather than scroll.
    //
    // That trade is off. The header is now a promise: 45% of the screen, on
    // every card that can carry one, and the answer scrolls if it must
    // ("everything else can have a header I think — even long lists, because
    // players should know to scroll"). A guarantee a long list can revoke is
    // not a guarantee, and the same Verto rendering differently on two phones
    // was the thing being complained about.
    //
    // The three exceptions are not decided here and never were: the tap
    // matrix, NPS and prioritise hide their strip in CSS (:has(.rotate-wrap),
    // :has(.nps-slider) and :has(.prioritise-list) in the mobile block),
    // because their answers cannot shrink — and prioritise's cannot scroll
    // either, its rows being drag targets rather than a scrollable list. And a focused text field still drops the hero — see
    // _watchTyping, which sets hero-off for the keyboard and is the reason
    // that class survives this change while hero-slim and art-off do not.
    //
    // What is left is the one thing a scrolling answer needs more than a
    // shedding one ever did: telling the respondent there is more below.
    // No need to measure with is-scrollable cleared first, and it was worth
    // checking rather than assuming, because the class is no longer passive —
    // the floating controls hang the answer's runway off it. It cancels: the
    // class adds a negative bottom margin to the box (clientHeight up by the
    // pill zone) and the same padding to its content (scrollHeight up by the
    // pill zone), so the difference is unchanged and the state cannot latch.
    // Tried it both ways against a grid taken from overflowing to fitting;
    // identical. What keeps that true is the reach guard in
    // floating_footer_test — remove the margin and it fails there.
    const over = box.scrollHeight - box.clientHeight

    // The fade is drawn over the last of the content, so it has to know
    // whether there IS anything below — left unconditional it greys out the
    // final row's label on an answer that fits perfectly well.
    box.classList.toggle("is-scrollable", over > 1)
  }

  // ── Saying that the answer MOVES, once ──────────────────────────────────
  //
  // The fade says the list continues. This says it scrolls. Reported four or
  // five times now, most recently from a study run on students' own phones:
  // the first option is the only one on screen, so it is the one that gets
  // picked, and the answer distribution becomes a property of the viewport
  // rather than of the question. That is a measurement problem, not a
  // cosmetic one, which is why "the RAs will remind them to scroll" was not an
  // acceptable answer to it.
  //
  // A NUDGE, not a scroll to the bottom, which was the other candidate. On a
  // list long enough to need this, travelling to the end takes the QUESTION
  // off the screen with it: for a second the respondent is reading options
  // with nothing to answer, then it snaps back. One option's worth of travel
  // says "this moves" just as clearly and keeps the question in view. It is
  // also the shape already proven here — the range slider nudges, it does not
  // run its track (.option-limit-counter.is-rejected is the same idea in CSS).
  //
  // ONCE PER PLAY, and deliberately not once per browser. A flag in
  // localStorage would fire for a first-time respondent and stay silent for a
  // returning one — a difference in treatment between people inside the same
  // study, which is a worse problem than the one being fixed. Every respondent
  // gets the same run; the cost is that somebody playing two Vertos sees it
  // twice, which is the right way round.
  static NUDGE_MIN_OVERFLOW = 32   // px below the fold worth teaching about; less
                                   // than this is a clipped edge, and moving it reads as a glitch
  static NUDGE_DELAY_MS     = 520  // let the card's entry animation land first
  static NUDGE_HOLD_MS      = 460  // dwell before coming back
  static NUDGE_DOWN_MS      = 420
  static NUDGE_UP_MS        = 380
  static NUDGE_FALLBACK     = 88   // an option-ish height, when no row can be measured
  static NUDGE_TRIES        = 6    // looks, including the one at card entry
  static NUDGE_RETRY_MS     = 120  // ~720ms of looking in all, then it fits

  // WHICH box scrolls is a layout question, and naming it was the wrong answer.
  // Usually it is .split-right > .mt-2 — the panel _fitCard measures and the
  // element the fade is masked onto — but the tiers that size a card for a
  // phone can leave that panel fitting and hand the overflow to an ancestor
  // instead. A cue that only ever looks at .mt-2 reports "nothing below the
  // fold" on precisely the layouts this exists for. So walk up from the
  // options and take whichever ancestor is actually scrolling; on every
  // viewport measured so far it resolves to .mt-2, which is the point — it
  // finds the scroller rather than assuming it.
  _answerScroller(card) {
    const list = card?.querySelector(".choice-list, .pick-list, .choice-grid, .prioritise-list")
    if (!list) return null
    for (let el = list.parentElement; el && el !== document.body; el = el.parentElement) {
      const oy = getComputedStyle(el).overflowY
      if ((oy === "auto" || oy === "scroll") && el.scrollHeight - el.clientHeight > 1) return el
    }
    return null
  }

  // `tries` counts down. _update runs before the panel has settled into the
  // height _fitCardHeight gives it and its observers then correct — so the
  // first look often finds a box that does not overflow YET, on a card that
  // will. One shot at card entry therefore misses the common case entirely
  // (measured: desktop found over=0 at entry and 110 a moment later). Look
  // again a few times, then stop: a card whose answer still fits after this
  // long fits.
  _maybeNudgeScroll(idx, tries = this.constructor.NUDGE_TRIES) {
    // Two flags, not one. _scrollNudged is spent only by a cue that actually
    // MOVED (see _runNudge); _nudgeArmed just stops a second _update() in the
    // same frame scheduling a second run. The first cut spent the one-shot
    // here, at scheduling — which, with the window listeners below, meant the
    // tap that dismissed the cookie banner killed the cue before it had moved
    // anything, and nothing ever brought it back.
    if (this._scrollNudged || this._nudgeArmed) return
    // No motion cue for anyone who asked for no motion. They are not left
    // without one: the fade is already on the box, and is the part of this the
    // owner rates most highly.
    if (this._reducedMotion) return
    // Never behind a panel. The survey-level consent banner and the creator's
    // intro modal each dim the deck and mark .preview-body inert, so a list
    // animating under one is motion on something the respondent can neither
    // read properly nor touch — the same reasoning, and the same two
    // attributes, as _syncCardModal's guard. Neither needs a retry: both
    // _dismissConsentBanner and dismissCardModal call _update(), which re-enters
    // here with a full budget the moment the deck is live, which is the first
    // moment the cue is any use. (A self-driving CARD — consent_gate, the
    // respondent-code gate — never reaches this line: _update returns above.)
    if (this.element.hasAttribute("data-consent-pending")) return
    if (this.element.hasAttribute("data-card-modal-open")) return

    const again = () => {
      if (tries <= 1) return
      this._nudgeRetry = setTimeout(() => this._maybeNudgeScroll(idx, tries - 1),
                                    this.constructor.NUDGE_RETRY_MS)
    }

    const card = this.cardTargets[idx]
    if (!card || !card.classList.contains("active")) return
    const box = this._answerScroller(card)
    if (!box) return again()
    // Already moved — by them, or by a position the browser restored. The cue
    // is for someone who has not discovered it yet.
    if (box.scrollTop > 0) return

    const over = box.scrollHeight - box.clientHeight
    if (over <= this.constructor.NUDGE_MIN_OVERFLOW) return again()

    this._nudgeArmed = true

    const row    = box.querySelector(".choice-list-item, .pick-item, .choice-card")
    const travel = Math.min(over, Math.round(row?.getBoundingClientRect().height) || this.constructor.NUDGE_FALLBACK)

    // Any sign of a real person ON THIS LIST cancels it, and leaves them
    // exactly where they put themselves. A cue that fights the hand it is
    // teaching is a bug report.
    //
    // On the box, NOT on window — window was the bug. A respondent's first
    // taps land on furniture this cue has nothing to do with: Accept all on the
    // cookie banner, Agree on the consent banner, the intro modal's button.
    // Listening globally read every one of those as "they have found the
    // scroll". keydown is the exception and stays global on purpose: Space,
    // PageDown and the arrows scroll the box without ever targeting it.
    this._nudgeCancelled = false
    const ac = new AbortController()
    this._nudgeListeners = ac
    this._nudgeAbort = () => { this._nudgeCancelled = true; this._teardownNudge() }
    const opts = { passive: true, signal: ac.signal }
    for (const ev of [ "pointerdown", "touchstart", "wheel" ]) box.addEventListener(ev, this._nudgeAbort, opts)
    window.addEventListener("keydown", this._nudgeAbort, opts)
    this._nudgeDown = setTimeout(() => this._runNudge(box, travel), this.constructor.NUDGE_DELAY_MS)
  }

  async _runNudge(box, travel) {
    if (this._nudgeCancelled) return
    // Spent HERE. The pre-roll is over, nothing interrupted it, and the next
    // frame moves the list — that is the cue being delivered, and the only
    // thing that should cost a respondent their one showing of it.
    this._scrollNudged = true
    await this._scrollOver(box, travel, this.constructor.NUDGE_DOWN_MS)
    if (this._nudgeCancelled) return
    await new Promise(done => { this._nudgeUp = setTimeout(done, this.constructor.NUDGE_HOLD_MS) })
    if (this._nudgeCancelled) return
    // The dwell is the one stretch of this with no frame callback watching the
    // box, so the return leg re-checks before it starts: a list somebody else
    // moved while it sat there must not be animated back to a position the cue
    // remembers and nobody else does.
    if (this._nudgeMovedElsewhere(box)) return this._teardownNudge()
    await this._scrollOver(box, 0, this.constructor.NUDGE_UP_MS)
    this._teardownNudge()
  }

  // A scroll the cue did not make. Pointer, touch, wheel and key each cancel
  // through their own listener; this catches everything that moves a scroller
  // without one — an option scrolled into view by a focus ring, a position the
  // browser restored, another script driving the box. All of them outrank a
  // cue, which exists to say the list moves and has no business deciding where
  // it ends up.
  _nudgeMovedElsewhere(box) {
    return this._nudgeAt != null && Math.abs(box.scrollTop - this._nudgeAt) > 2
  }

  // Drop the listeners without claiming the run was cancelled — _nudgeAbort did
  // both, so a cue that finished cleanly left _nudgeCancelled true behind it.
  // True of nothing, and a trap for the next thing to read the flag.
  _teardownNudge() {
    this._nudgeArmed = false
    this._nudgeAt = null
    this._nudgeListeners?.abort()
    this._nudgeListeners = null
  }

  // Animated by hand rather than with scroll-behavior: smooth. The native one
  // was measured stalling halfway back — a programmatic smooth scroll is at
  // the browser's discretion and the observers that fire while the card
  // settles are enough to abandon it, which leaves the list parked off its
  // origin with no way back. This is the same motion, deterministic, and
  // cancellable to the frame.
  _scrollOver(box, to, ms) {
    return new Promise(done => {
      const from = box.scrollTop
      const dist = to - from
      if (!dist) return done()
      this._nudgeAt = from
      const t0 = performance.now()
      const step = now => {
        if (this._nudgeCancelled) return done()
        if (this._nudgeMovedElsewhere(box)) { this._nudgeAbort?.(); return done() }
        const p = Math.min(1, (now - t0) / ms)
        const eased = p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2
        box.scrollTop = from + dist * eased
        // Read back rather than trusting the write: the browser clamps to the
        // scrollable range and rounds, and comparing against what we MEANT
        // would read its own rounding as interference, every frame.
        this._nudgeAt = box.scrollTop
        if (p < 1) this._nudgeFrame = requestAnimationFrame(step)
        else done()
      }
      this._nudgeFrame = requestAnimationFrame(step)
    })
  }

  // ── The card's real height ──────────────────────────────────────────────
  //
  // --play-card-h is the token every mobile tier takes its hero and answer
  // panel from, and its CSS definition — 100svh less the footer — is an
  // ESTIMATE of the deck's box rather than a measurement of it. What it
  // cannot see is anything stacked ABOVE the card inside the overlay: an org
  // masthead, and on a notched iPhone the strip the safe area holds open.
  // The Test Mode banner used to be the third and worst of them — the owner's
  // device photos were all Test Mode on an iPhone with a dynamic island, so
  // two were in play at once — and Test Mode is a ring around the viewport
  // now (.play-test-frame), out of flow, costing the card nothing. That
  // narrows what this has to catch; it does not retire it. Anything an
  // overlay stacks above the deck does the same thing, which is why the
  // measurement is the fix rather than a subtraction of known offenders.
  //
  // Reproduced at 393x768 with a 55px spacer standing in for the inset: the
  // card is 609px and the token says 699. The hero is `flex: 0 0 auto` at 45%
  // OF 699, so it takes 314 — 51% of the card it is actually in — and
  // .split-right's min-height then claims 384 of the 295 that are left. The
  // panel overflows the card by 67px and its bottom is cut. On most types
  // what falls off is padding. On a scenario it is .book-nav-row: the two
  // chevrons that are the ONLY way to turn a page, with no swipe fallback
  // ("its unclear in the scenario question type how to go to the next one").
  //
  // .preview-body IS the box the card lives in, so measure that and say so.
  // The CSS declaration stays, as the value in force before this runs. There
  // is no feedback loop to guard against: the body's height comes from flex
  // against the overlay, not from the card inside it, so writing the token
  // cannot move what was just measured — but the 1px gate keeps a
  // sub-pixel wobble from writing on every observer tick anyway.
  _fitCardHeight() {
    const body = this._bodyEl ||= this.element.querySelector(".preview-body")
    if (!body) return
    const h = body.clientHeight
    if (!h) return
    if (this._cardH != null && Math.abs(h - this._cardH) < 1) return
    this._cardH = h
    this.element.style.setProperty("--play-card-h", `${h}px`)
  }

  _watchCardHeight() {
    this._fitCardHeight()
    const body = this._bodyEl
    if (!body || typeof ResizeObserver === "undefined") return
    // Rotation, the iOS toolbar collapsing, the keyboard, and the banner
    // being dismissed all change this box without changing the viewport the
    // CSS fallback is written against.
    //
    // And when the box changes, how much of the answer sits below the fold
    // changes with it — so the scroll cue is re-decided here too, not only on
    // the footer's observer. The footer does not resize when something above
    // the card does (a banner appearing, the safe-area strip): an intake that
    // fit at load and was pushed under the fold kept a stale "fits" verdict
    // until the next card advance. No loop: the body's height comes from flex
    // against the overlay, so nothing _fitCard toggles can move what
    // _fitCardHeight just measured.
    this._bodyObserver = new ResizeObserver(() => { this._fitCardHeight(); this._fitCard() })
    this._bodyObserver.observe(body)
  }

  _watchFooterFit() {
    this._fitFooter()
    const footer = this._footerEl
    if (!footer || typeof ResizeObserver === "undefined") return
    // Catches rotation, the iOS toolbar collapsing, and a keyboard opening.
    // Label and chip changes call _fitFooter directly — they don't resize the
    // bar itself, so the observer would never hear about them.
    this._footerObserver = new ResizeObserver(() => { this._fitFooter(); this._fitCard() })
    this._footerObserver.observe(footer)
  }

  // The one DETERMINISTIC keyboard signal: a text control inside the deck has
  // focus. It reads the same on every platform, unlike anything measured off
  // the viewport — so everything that has to be right hangs off this, and only
  // the overlay's own height hangs off the measurement in lib/viewport_height.
  _watchTyping() {
    const TEXTY = /^(?:text|search|email|tel|url|number|password)$/
    const isText = (el) => !!el && (el.tagName === "TEXTAREA" || el.isContentEditable ||
                                    (el.tagName === "INPUT" && TEXTY.test(el.type || "text")))
    const sync = () => {
      const el = document.activeElement
      const on = isText(el) && this.element.contains(el)
      document.documentElement.classList.toggle("kbd-open", on)
      const card = this.cardTargets[this.currentValue]
      if (on) {
        // Reuse hero-off rather than a second hide list: it already covers
        // every inset:0 medium (see the .hero-off rules and
        // player_hero_css_test's fourth test), and a parallel list is a
        // parallel thing to forget a card type from. On a 45/55 card this one
        // line hands the field ~45% of the screen back, which on its own is
        // usually the whole fix.
        card?.classList.add("hero-off")
        this._revealField(el)
      } else {
        // Take it off HERE, explicitly. This used to hand the restore to
        // _fitCard, which was correct while _fitCard owned hero-off and
        // recomputed it from scratch on every run — it does not any more (the
        // shed ladder is gone), so leaving the restore to it would have left
        // the hero off for the rest of the deck the moment anyone typed. The
        // class now has exactly one owner, which is this branch's pair.
        card?.classList.remove("hero-off")
        // Still re-run it: the answer's height changed while the keyboard was
        // up, so whether the "more below" fade belongs has to be re-decided.
        // Unguarded again too, because kbd-open has just come off.
        this._fitCard()
      }
    }
    this.element.addEventListener("focusin", sync)
    this.element.addEventListener("focusout", () => requestAnimationFrame(sync))
  }

  // The browser's own "scroll the focused field into view" walks up the tree
  // looking for a box that can take the scroll, and on this card every box is
  // overflow: hidden except the answer scroller — so when a field is not
  // inside one, the browser scrolls the VISUAL VIEWPORT and drags the overlay
  // off screen with it. Do it ourselves, in the box that owns the card's
  // scroll, measured against the VISIBLE height rather than the layout one.
  _revealField(el) {
    const box = el.closest(".split-right > .mt-2, .split-right > .other-block, " +
                           ".split-right > .play-consent-main")
    if (!box) return
    clearTimeout(this._revealTimer)
    // The keyboard animates in (~250ms on iOS). Measuring before it lands
    // reads the pre-keyboard visible height and under-scrolls.
    this._revealTimer = setTimeout(() => {
      // The floor is the lower edge of what the respondent can SEE, which is
      // not the same number as visualViewport.height — see lib/visible_band for
      // why, and for what comparing against the bare height costs on iOS. This
      // used to read `Math.min(box…bottom, visualViewport.height)`, which is
      // correct only where offsetTop is 0.
      const floor = Math.min(box.getBoundingClientRect().bottom, visibleBandEnd()) - 8
      const over    = el.getBoundingClientRect().bottom - floor
      if (over <= 0) return
      // Smooth, because by the time this fires the overlay has already ridden
      // the keyboard up (see viewport_height.js) and stopped. An instant
      // scrollTop here lands as a SECOND, separate movement a third of a
      // second after the first — the two together are what reads as "flashed
      // into place" rather than either one alone.
      if (box.scrollTo) box.scrollTo({ top: box.scrollTop + over, behavior: "smooth" })
      else box.scrollTop += over
    }, 300)
  }

  // ── Text size ("Aa" pill) ──────────────────────────────────────────────
  // A respondent accessibility preference, not a creator setting: three
  // steps, remembered across every Verto this browser plays. data-font-scale
  // on the overlay drives CSS tiers on the reading surfaces only (the
  // question title, option labels, book pages, consent copy and free-text
  // inputs) — footer buttons and chrome are deliberately untouched.
  _loadFontScale() {
    try {
      const v = localStorage.getItem(FONT_SCALE_KEY)
      return FONT_SCALE_STEPS.includes(v) ? v : "default"
    } catch (_e) {
      return "default"
    }
  }

  // Bound via data-action="click->player#setFontScale" with a
  // data-player-font-scale-param on each of the three pill buttons.
  setFontScale(event) {
    const scale = event.params?.fontScale
    if (!FONT_SCALE_STEPS.includes(scale)) return
    this._applyFontScale(scale)
    try { localStorage.setItem(FONT_SCALE_KEY, scale) } catch (_e) { /* private mode */ }
  }

  _applyFontScale(scale) {
    this.element.dataset.fontScale = scale
    this.fontScaleBtnTargets.forEach(btn => {
      const active = btn.dataset.scale === scale
      btn.classList.toggle("is-active", active)
      btn.setAttribute("aria-pressed", active ? "true" : "false")
    })
    // Bigger reading text costs the card its artwork before it costs the
    // respondent an option that's clipped below the fold — same rule
    // _fitCard already enforces for any other reason a card runs short of
    // room. The footer can shift too (a long label at a new zoom level),
    // hence both, mirroring every other call that changes what a card holds.
    this._fitCard()
    this._fitFooter()
  }

  // ── Retired "Lite" preference ────────────────────────────────────────────
  // Nothing reads this key any more, but a respondent who tapped the old pill
  // is still carrying it. Dropping it costs one localStorage write on the
  // first visit after this ships and means the flag can never be revived by
  // accident — the alternative, leaving it, keeps a value in the field whose
  // meaning has changed underneath it. Silent by design: a respondent who
  // never noticed the toggle should not now be told about it.
  _clearRetiredLiteMode() {
    try { localStorage.removeItem(RETIRED_LITE_MODE_KEY) } catch (_e) { /* private mode */ }
  }

  // ── Test Mode hatch ──────────────────────────────────────────────────────
  //
  // Lets whoever is holding a live play link say "this run isn't real" and land
  // in Test Mode, where every recording endpoint is blank. Built for the person
  // demoing a Verto on the real link — at an event, on a partner's phone —
  // whose run would otherwise sit in the creator's results forever.
  //
  // The whole design constraint is that a RESPONDENT must not be able to fall
  // into it, because for them it would silently throw away real answers. Hence
  // no label, no visible target, and two separate deliberate acts: hold, then
  // confirm. See player/_test_mode_hatch.html.erb for the markup and why the
  // hotspot is aria-hidden.

  testHoldStart(event) {
    // Blank URL ⇒ owner preview or Test Mode itself; there is nowhere to go and
    // the partial isn't even rendered. Belt and braces.
    if (!this.testModeUrlValue) return
    // A fresh hold always starts from disarmed, so pressing again while a chip
    // is still showing re-runs the whole gesture rather than leaving that chip
    // up with nothing left to time it out.
    this._disarmTestMode()
    this._testHoldFrom = { x: event.clientX, y: event.clientY }
    this._testHoldTimer = setTimeout(() => this._armTestMode(), TEST_HOLD_MS)
  }

  // A hold that travels is a scroll or a swipe that happened to start here, not
  // a press — drop it rather than arming behind the gesture the person meant.
  testHoldMove(event) {
    if (!this._testHoldTimer || !this._testHoldFrom) return
    const dx = event.clientX - this._testHoldFrom.x
    const dy = event.clientY - this._testHoldFrom.y
    if (Math.hypot(dx, dy) > TEST_HOLD_SLOP_PX) this.testHoldCancel()
  }

  // Lifting, sliding off, or a cancelled pointer all end the hold. Only the
  // arm timer is left alone: once the chip is showing it runs on its own clock,
  // so letting go is exactly what you do before tapping it.
  testHoldCancel() {
    clearTimeout(this._testHoldTimer)
    this._testHoldTimer = null
    this._testHoldFrom = null
  }

  _armTestMode() {
    this.testHoldCancel()
    if (!this.hasTestConfirmTarget) return
    this.testConfirmTarget.hidden = false
    // The only feedback that the hold worked, and the only reason a stray press
    // is noticeable at all. Suppressed in forms mode like every other buzz.
    this._buzz([ 12, 40, 12 ])
    this._testArmTimer = setTimeout(() => this._disarmTestMode(), TEST_ARM_MS)
  }

  _disarmTestMode() {
    this._clearTestTimers()
    if (this.hasTestConfirmTarget) this.testConfirmTarget.hidden = true
  }

  _clearTestTimers() {
    clearTimeout(this._testHoldTimer)
    clearTimeout(this._testArmTimer)
    this._testHoldTimer = null
    this._testArmTimer = null
    this._testHoldFrom = null
  }

  enterTestMode() {
    if (!this.testModeUrlValue) return
    // Orphan this run's session token on the way out, for the same reason
    // playAgain() does: whatever was started here is finished with, and a later
    // real run on this device must open a new response row rather than merge
    // into it. (Anything already saved stays saved — it was a real answer when
    // it was given, and abandoning a deck mid-way is not new behaviour.)
    try {
      sessionStorage.removeItem(`verto_session_${this.submitUrlValue}`)
    } catch (_e) { /* storage blocked */ }
    // A full navigation, not in-place surgery: Test Mode's guarantee is that the
    // page carries no live endpoint at all, and only a server render can make
    // that true. Same reasoning as playAgain()'s reload — connect() is the one
    // place the deck's state machine starts clean.
    window.location.assign(this.testModeUrlValue)
  }

  // Consent card (the first card): agreeing advances into the deck; declining
  // swaps in a polite end-state and leaves the respondent on the gate. Both
  // record the event server-side for the audit trail — fire-and-forget, same
  // best-effort philosophy as _saveProgress(), so a network blip never blocks
  // the respondent's tap.
  agreeConsent() {
    this._buzz()
    this._recordConsent(true)
    // Two gates share this action and never coexist. The survey-level BANNER
    // has no card to advance past — dismissing it hands back the deck that
    // was under it all along. The multi-page consent_gate CARD is a deck
    // position, so agreement there still means "move on".
    if (this.element.hasAttribute("data-consent-pending")) {
      this._dismissConsentBanner()
      return
    }
    this.next()
  }

  _dismissConsentBanner() {
    this._clearConsentPending()
    // The deck is live now, so a first card carrying an intro modal can finally
    // have one — _syncCardModal refuses to open one while the banner is up
    // (see there). Before the focus move below, so an opened modal wins the
    // focus rather than the Next button behind it.
    this._update()
    // The banner never occupied layout, but the nav buttons just appeared and
    // the deck just became live — re-measure on the next frame and put focus
    // where the respondent's next act is.
    requestAnimationFrame(() => { this._fitCardHeight(); this._fitCard() })
    if (this.element.hasAttribute("data-card-modal-open")) return
    const btn = this.nextBtnTarget.classList.contains("hidden") ? this.finishBtnTarget : this.nextBtnTarget
    btn?.focus()
  }

  // Remove the pending state without recording anything — the shared teardown
  // for agreement (which records first) and for paths where consent is moot
  // (the already-played board). Declining deliberately does NOT come here:
  // the attribute stays, the deck stays inert, and the banner shows its
  // declined message in place.
  _clearConsentPending() {
    this.element.removeAttribute("data-consent-pending")
    this.element.querySelector(".preview-body")?.removeAttribute("inert")
  }

  declineConsent() {
    // Drop anything already answered before telling the server, so no later
    // save can put it back. The server purges the stored copy; this stops the
    // client re-uploading its own — an unload flush or a queued submit would
    // otherwise restore exactly what the respondent just refused to give.
    this._answers = {}
    this._declined = true
    this._recordConsent(false)
    if (this.hasConsentMainTarget) this.consentMainTarget.classList.add("hidden")
    if (this.hasConsentDeclinedTarget) this.consentDeclinedTarget.classList.remove("hidden")
  }

  // The contact gate. Details are held in memory and ride the ordinary saves
  // (see _payload) — they are never part of answers. What IS written locally is
  // a done-marker, so the gate is a first-visit register: a replay or return
  // visit starts past it (_skipContactGateIfDone), which is also why skipping
  // marks done — declining to register is an answer to the gate, not a snooze.
  submitContactDetails() {
    const contact = {}
    for (const [field, has, target] of [
      ["name",     this.hasContactNameTarget,     () => this.contactNameTarget],
      ["email",    this.hasContactEmailTarget,    () => this.contactEmailTarget],
      ["company",  this.hasContactCompanyTarget,  () => this.contactCompanyTarget],
      ["industry", this.hasContactIndustryTarget, () => this.contactIndustryTarget]
    ]) {
      const value = has ? target().value.trim() : ""
      if (value) contact[field] = value
    }
    if (Object.keys(contact).length) {
      this._contact = contact
      this._buzz()
    }
    this._markContactDone()
    this.next()
  }

  skipContactDetails() {
    this._markContactDone()
    this.next()
  }

  // ── Ask-once questions ────────────────────────────────────────────────────
  // A question the creator marked "ask once per person": the first run that
  // answers it writes the answer here (see _capture), and every later run
  // seeds it back into _answers and navigates past the card. The store shares
  // localStorage with the durable player key, so the remembered answer and
  // the identity it belongs to are one fate — and the seeded answer rides
  // each run's ordinary payload, keeping every response row complete under
  // that identity's digest.

  _onceStoreKey() {
    return `verto_once_${this.submitUrlValue}`
  }

  _readOnceStore() {
    try {
      return JSON.parse(localStorage.getItem(this._onceStoreKey()) || "{}") || {}
    } catch (_) {
      return {}
    }
  }

  _writeOnceStore(cardIndex, answer) {
    try {
      const store = this._readOnceStore()
      store[cardIndex] = answer
      localStorage.setItem(this._onceStoreKey(), JSON.stringify(store))
    } catch (_) { /* storage blocked — the question simply asks again next run */ }
  }

  // Seed remembered answers into this run. Only for cards still marked
  // ask-once (the creator may have untoggled since) with a genuinely given
  // answer — and record which card indexes are skippable this run.
  _seedOnceAnswers() {
    this._onceSkip = new Set()
    const store = this._readOnceStore()
    this.cardTargets.forEach((card, i) => {
      if (card.dataset.cardAskOnce !== "true") return
      const key = card.dataset.cardIndex
      if (key === undefined || key === "") return
      const remembered = store[key]
      if (remembered === undefined || !this._isAnswerGiven(remembered)) return
      this._answers[key] = remembered
      this._onceSkip.add(i)
    })
  }

  _isOnceSkipped(i) {
    return !!this._onceSkip && this._onceSkip.has(i)
  }

  // The last card a respondent will actually SEE — trailing remembered cards
  // don't count, so the button before them says Finish, not Next.
  _lastInteractiveIndex() {
    for (let i = this.cardTargets.length - 1; i >= 0; i--) {
      if (!this._isOnceSkipped(i)) return i
    }
    return this.cardTargets.length - 1
  }

  _markContactDone() {
    try { localStorage.setItem(`verto_contact_${this.submitUrlValue}`, "1") } catch (_) { /* storage blocked */ }
  }

  _contactDone() {
    try {
      return !!localStorage.getItem(`verto_contact_${this.submitUrlValue}`)
    } catch (_) {
      return false
    }
  }

  // Advance the starting card past an already-done contact gate, before the
  // first _update paints. Bounded walk rather than a single step, so it stays
  // correct if another leading gate ever lands beside it.
  _skipContactGateIfDone() {
    if (!this._contactDone()) return
    while (this.cardTargets[this.currentValue]?.dataset.cardType === "contact_gate_card" &&
           this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
    }
  }

  // The respondent-code gate. The code is held in memory only until the next
  // save carries it; nothing writes it to storage on this side either, so a
  // reload genuinely forgets it (the digest already recorded on the response is
  // what keeps the identity).
  async submitRespondentCode() {
    const entered = (this.hasRespondentCodeTarget ? this.respondentCodeTarget.value : "").trim()
    // There is no skip and no blank pass-through: the code step is
    // hard-required wherever it appears — creators hang study IDs on it, and
    // an empty Continue would be a skip under another name. Refusing here
    // still performs no save: a code alone must not create a response row.
    if (!entered) {
      this._showRequiredHint(this.cardTargets[this.currentValue])
      return
    }
    this._respondentCode = entered
    this._buzz()
    // Recall, when the creator turned it on: ask the server whether this
    // identity has already answered any of this deck's ask-once questions
    // somewhere else. Until now "asked once" was a promise made to a BROWSER
    // (localStorage plus a device-minted uuid), so a new phone asked
    // everything again — which is the opposite of what the setting says.
    //
    // The deck cannot advance until the answer is in — a card seeded AFTER
    // the respondent has walked past it is a card they answered twice. So
    // the wait is real, and a wait a respondent cannot see is a button they
    // think is broken. Hence the busy state, and hence _recall's short
    // timeout: the fallback (ask the question again) is cheap.
    this._setCodeBusy(true)
    let blocked = false
    try {
      // No retests, code basis: a code that already finished this wave is
      // told so here, before a single answer is given. The server would
      // refuse the first save regardless — this is the honest version.
      blocked = await this._eligibility(entered)
      if (!blocked) this._applyRecall(await this._recall(entered))
    } finally {
      this._setCodeBusy(false)
    }
    if (blocked) {
      this._respondentCode = null
      this._clearConsentPending()
      this._showAlreadyPlayed()
      return
    }
    // Deliberately does NOT save here. _saveProgress refuses to create a row
    // before there's a real answer, so that someone who opens a Verto and leaves
    // isn't counted as a respondent — a code on its own shouldn't change that.
    // It rides along with the first genuine save instead (see _payload).
    this.next()
  }

  // ── Recall ─────────────────────────────────────────────────────────────────

  // The code card's own buttons, while the lookup is in flight. aria-busy for
  // a screen reader, `disabled` so a second tap can't queue a second advance.
  _setCodeBusy(busy) {
    const card = this.cardTargets[this.currentValue]
    if (!card) return
    card.setAttribute("aria-busy", busy ? "true" : "false")
    card.querySelectorAll(".play-consent-agree, .play-consent-decline")
        .forEach(btn => { btn.disabled = busy })
  }

  // No retests, code basis: has this code already finished the current wave?
  // False on every failure — the server refuses the first write regardless,
  // so a Verto that can't reach the network simply gets there one card later.
  async _eligibility(code) {
    if (!this.eligibilityUrlValue) return false
    try {
      const res = await fetch(this.eligibilityUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_token: this._sessionToken, respondent_code: code }),
        signal: AbortSignal.timeout(2000)
      })
      if (!res.ok) return false
      const data = await res.json()
      return !!(data && data.blocked)
    } catch (_e) {
      return false
    }
  }

  // Ask-once answers this person gave under the same code, from the server.
  // Empty on every failure — a Verto that can't reach the network simply asks
  // the questions again, which is the pre-feature behaviour and no worse.
  async _recall(code) {
    if (!this.hasRecallUrlValue || !this.recallUrlValue) return {}
    try {
      const res = await fetch(this.recallUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_token: this._sessionToken, respondent_code: code }),
        signal: AbortSignal.timeout(2000)
      })
      if (!res.ok) return {}
      const data = await res.json()
      return (data && data.answers) || {}
    } catch (_e) {
      return {}
    }
  }

  // Precedence, and it only reads one way: THIS RUN beats the local store beats
  // the server. The local store is this browser's record of an answer this
  // identity actually gave here; recall is a claim about an identity asserted
  // by a typed string, so it fills gaps and never overwrites.
  _applyRecall(map) {
    if (!map || !Object.keys(map).length) return

    this._onceSkip = this._onceSkip || new Set()
    this.cardTargets.forEach((card, i) => {
      if (card.dataset.cardAskOnce !== "true") return
      const key = card.dataset.cardIndex
      if (key === undefined || key === "") return

      const remembered = map[card.dataset.cardCid] ?? map[key]
      if (remembered === undefined || !this._isAnswerGiven(remembered)) return
      if (this._isAnswerGiven(this._answers[key])) return

      this._answers[key] = remembered
      // Teach this device, so a second run here needs no network and an
      // offline replay still skips.
      this._writeOnceStore(key, remembered)
      // Forward only. `>`, not `>=`: the respondent is standing ON the code
      // card, and marking a card BEHIND them as skipped would make Back step
      // over one they did see. A deck that reorders itself under someone
      // mid-run is worse than a question asked twice — so a card already
      // passed has its answer completed silently and nothing rewinds.
      if (i > this.currentValue) this._onceSkip.add(i)
    })
    // The last interactive card may have moved, so Next/Finish repaints.
    this._update()
  }

  _recordConsent(agreed) {
    if (!this.consentUrlValue) return
    fetch(this.consentUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session_token: this._sessionToken, agreed })
    }).catch(() => { /* best-effort — nothing to retry from here */ })
  }

  // The tap stack's last statement was just answered ("tap-stack:complete",
  // routed via the overlay's data-action). There is nothing left to do on the
  // card, so the deck moves on for the respondent — after a beat long enough
  // to read as "done", not as being yanked: the throw animation (350ms) plus
  // a breath on the all-answered face.
  //
  // Three deliberate refusals. A stale event (the stack isn't the current
  // card — Back mid-throw) is ignored. A GRADED tap card keeps its reveal
  // respondent-driven — auto-running next() would flash right/wrong at
  // someone who wasn't looking yet. And the deck's last step never
  // auto-advances: Finish (which submits) stays an explicit act, whether
  // that's the linear last card, the last interactive card before an
  // ask-once tail, or a logic route whose resolved answer leads to an end.
  AUTO_ADVANCE_DELAY = 900

  tapStackCompleted(event) {
    const card = event.target.closest("[data-player-target='card']")
    if (!card || this.cardTargets[this.currentValue] !== card) return
    if (card.dataset.cardGraded === "true") return
    if (this.hasFinishBtnTarget && !this.finishBtnTarget.classList.contains("hidden")) return
    if (this.logicValue) {
      this._capture(this.currentValue)
      if (this._resolveNext(this.currentValue).end != null) return
    }
    this._cancelAutoAdvance()
    this._autoAdvanceTimer = setTimeout(() => {
      this._autoAdvanceTimer = null
      // Belt behind the cancel event: if the stack is no longer complete when
      // the beat lands (Reset raced the timer), stay put.
      const stack = this.cardTargets[this.currentValue]?.querySelector("[data-controller~='tap-stack']")
      if (stack && !stack.classList.contains("is-complete")) return
      this.next()
    }, this.AUTO_ADVANCE_DELAY)
  }

  // Public twin for the Reset hook ("tap-stack:reset"); _update clears the
  // timer too, so a manual Next or Back during the beat never double-fires.
  cancelAutoAdvance() {
    this._cancelAutoAdvance()
  }

  _cancelAutoAdvance() {
    if (!this._autoAdvanceTimer) return
    clearTimeout(this._autoAdvanceTimer)
    this._autoAdvanceTimer = null
  }

  next() {
    // Scenario: the deck's Next means "turn the page" until the book's own
    // answer page is showing — otherwise one tap could skip the whole story
    // (and the choice) without the respondent ever seeing it.
    if (this._scenarioTurn(this.currentValue, 1)) return
    // Quiz: a graded card reveals right/wrong on the first Next, and only
    // advances on the second — so the player always sees how they did.
    if (this._needsReveal(this.currentValue)) {
      this._capture(this.currentValue)
      if (!this._requireGuard(this.currentValue)) return
      this._gradeCurrent()
      return
    }
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    this._applyTokenEarn(this.currentValue)
    // No going back: the card being left is final — lock it as the token
    // reveal does, so it reads as settled if it is ever seen again.
    if (this.noGoingBackValue) this._lockInputs(this.cardTargets[this.currentValue])
    this._saveProgress()
    this._advance()
  }

  // Advance one step. Linear by default; follows the answer-logic graph when the
  // Verto has logic enabled (routing off ⇒ this is byte-identical to before).
  _advance() {
    this._navBack = false
    if (this.logicValue) { this._advanceLogic(); return }
    if (this.currentValue < this.cardTargets.length - 1) {
      this._buzz()
      this.currentValue++
      // Ask-once: remembered questions are not re-asked — walk past them to
      // the next card this respondent still owes an answer. Bounded by the
      // deck end; _lastInteractiveIndex keeps Finish on the last REAL card,
      // so this never strands anyone on a skipped tail.
      while (this._isOnceSkipped(this.currentValue) &&
             this.currentValue < this.cardTargets.length - 1) {
        this.currentValue++
      }
      this._update()
    }
  }

  back() {
    // Scenario: retrace pages before leaving the card, symmetric with next().
    if (this._scenarioTurn(this.currentValue, -1)) return
    // No going back: the footer Back is hidden (_update), so this is belt and
    // braces for anything else that might call it. After the scenario turn on
    // purpose — re-reading a story page changes no answer.
    if (this.noGoingBackValue) return
    // Which way the next _update() should animate. Set here rather than derived
    // from the index, because under logic the index can move either way on a
    // forward step — it's the respondent's intent that decides the direction,
    // not the arithmetic.
    this._navBack = true
    this._capture(this.currentValue)
    this._saveProgress()
    if (this.logicValue) {
      // Retrace the taken path — a plain currentValue-- could land on a card
      // this respondent skipped by branching. Remembered ask-once cards sit
      // in the path (their seeded answers rode the routing), so pop through
      // them too: Back means "the previous card I SAW".
      if (this._path.length > 1) {
        do {
          this._path.pop()
          this.currentValue = this._path[this._path.length - 1]
          this._hops = Math.max(0, this._hops - 1)
        } while (this._path.length > 1 && this._isOnceSkipped(this.currentValue))
        this._update()
      }
      return
    }
    if (this.currentValue > 0) {
      // Mirror of _advance's walk: Back lands on the previous card the
      // respondent actually saw. If everything earlier is remembered, stay.
      let dest = this.currentValue - 1
      while (dest > 0 && this._isOnceSkipped(dest)) dest--
      if (this._isOnceSkipped(dest)) return
      this.currentValue = dest
      this._update()
    }
  }

  _payload() {
    let answers = this._answers
    // Under logic, only submit answers for cards actually on the taken path —
    // backing up and re-routing can leave a stale answer for a now-skipped
    // card, which the server's index-based quiz/token totals would else count.
    if (this.logicValue) {
      const keep = new Set(
        this._path.map(i => this.cardTargets[i]?.dataset.cardIndex).filter(k => k != null && k !== "")
      )
      answers = {}
      for (const [k, v] of Object.entries(this._answers)) if (keep.has(k)) answers[k] = v
    }
    const payload = { session_token: this._sessionToken, answers, locale: this.localeValue }
    // Rides along with the ordinary save rather than needing an endpoint of its
    // own. The server hashes it and drops the plaintext; it's only sent until a
    // digest is recorded, and the server ignores a second one anyway.
    if (this._respondentCode) payload.respondent_code = this._respondentCode
    // The leaderboard identity rides the same way, under the same discipline:
    // hashed server-side, set once per response, ignored while the board is off.
    if (this._playerKey) payload.player_key = this._playerKey
    // Contact details too — which is what puts them through the service
    // worker's offline submit queue without an endpoint of their own. The
    // server files them in their own table (never in answers) keyed by the
    // player key's digest; the write is idempotent, so riding every save
    // costs nothing.
    if (this._contact && this._playerKey) payload.contact = this._contact
    return payload
  }

  async finish() {
    // Scenario: same interception as next() — a scenario can be the last card.
    if (this._scenarioTurn(this.currentValue, 1)) return
    // Quiz: if the last card is graded and unrevealed, reveal it first; the
    // player presses Finish again to actually submit.
    if (this._needsReveal(this.currentValue)) {
      this._capture(this.currentValue)
      if (!this._requireGuard(this.currentValue)) return
      await this._gradeCurrent()
      return
    }
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    this._applyTokenEarn(this.currentValue)
    if (this.noGoingBackValue) this._lockInputs(this.cardTargets[this.currentValue])
    // Logic Vertos resolve the answer graph even on Finish — the terminal
    // card's chosen answer may still route onward, or to a specific end screen.
    if (this.logicValue) { await this._advanceLogic(); return }
    this._buzz([10, 30, 10]) // a little "done" buzz on completion
    await this._finalize()
  }

  // Submit the recorded answers and reveal the thank-you screen. Shared by the
  // linear Finish button and logic's _goToEnd, so both paths record identically.
  async _finalize() {
    // Owner preview runs without a submit endpoint — nothing is recorded,
    // just show the thank-you screen.
    if (this._declined) return // the declined panel is already the end state
    if (!this.submitUrlValue) return this._showThankyou(false)
    let queued = false
    // Distinct from `queued`: the request reached the server and the server said
    // no. Before the service worker stopped swallowing 4xx, this state could not
    // arise here at all — a 410 came back as a synthetic 202 and the respondent
    // was told their answers were saved and would sync.
    let rejected = false
    // No label swap (unlike _setGradingBusy) since that would need a new
    // translated string across all locales — the dimmed/not-allowed state
    // from [data-disabled="true"] already gives visible feedback and blocks
    // a second tap from firing a duplicate submit while this one is in flight.
    if (this.hasFinishBtnTarget) this.finishBtnTarget.dataset.disabled = "true"
    try {
      const res = await fetch(this.submitUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this._payload())
      })
      const data = await res.clone().json().catch(() => null)
      if (!res.ok) {
        // No retests: another run under this identity finished this wave
        // first (another device, or a code typed here after a reload). The
        // refused screen, not the "closed" pill — the Verto is open.
        if (data && data.code === "already_played") { this._refuseRetake(); return }
        // The Verto was unpublished, closed or deleted while this respondent
        // had the page open — the player HTML is served stale-while-revalidate,
        // so that is an ordinary thing to happen mid-session. Nothing was
        // stored, and saying so beats a thank-you screen that isn't true.
        rejected = true
        this._showThankyou(false, true)
        return
      }
      queued = !!(data && data.queued)
      // Trust the server's final score over the running client tally.
      if (this.quizValue && data && typeof data.score === "number") {
        this._quizScore = data.score
        if (typeof data.max === "number") this._quizMax = data.max
      }
      // Trust the server's final token totals over the running client tally.
      if (this.tokenisationValue && data && data.token_totals && typeof data.token_totals === "object") {
        this._tokenTotals = { ...this._tokenTotals, ...data.token_totals }
      }
    } catch (_) {
      // The request never got an answer. Offline with no service worker means
      // the answers are gone; online means something else failed. Either way
      // nothing was confirmed stored, so say which of the two it was rather
      // than showing an unqualified thank-you.
      queued   = !navigator.onLine
      rejected = navigator.onLine
    } finally {
      if (this.hasFinishBtnTarget) this.finishBtnTarget.dataset.disabled = "false"
    }
    // No retests' device marker. Set even when queued — the service worker
    // will deliver that run, so this device HAS played. Not on rejected:
    // nothing was stored, so the door stays open.
    if (!rejected) this._markPlayed()
    this._showThankyou(queued, rejected)
  }

  // ── Answer-branching: graph traversal ──────────────────────────────────────

  // Follow the answer-logic graph from the current card: hop to the resolved
  // next card, or finalise on a reached end screen. A hop budget guarantees
  // termination even on a malformed (looping) graph.
  async _advanceLogic() {
    const dest = this._resolveNext(this.currentValue)
    if (dest.index != null && dest.index >= 0 && dest.index < this.cardTargets.length) {
      if (this._hops >= this.cardTargets.length) { await this._goToEnd("default"); return }
      this._hops++
      this._buzz()
      this._path.push(dest.index)
      this.currentValue = dest.index
      // Ask-once under logic: a remembered card is landed on (its seeded
      // answer must drive its own routing) and immediately left — the
      // recursion resolves the NEXT step from this card exactly as if the
      // respondent had just answered it. The hop budget above still bounds
      // the walk.
      if (this._isOnceSkipped(dest.index)) { await this._advanceLogic(); return }
      this._update()
      return
    }
    await this._goToEnd(dest.end != null ? dest.end : "default")
  }

  // Reach an end screen: remember which one (used once multiple end screens
  // exist) and run the shared submit + thank-you finalise.
  async _goToEnd(id) {
    this._endId = id || "default"
    this._buzz([10, 30, 10])
    await this._finalize()
  }

  // Resolve the next step for the current card from its logic + captured answer.
  // Returns { index } to move to a card, or { end } to finish on an end screen.
  // Mirrors the server-side LogicGraph (app/lib/logic_graph.rb).
  _resolveNext(idx) {
    const card   = this.cardTargets[idx]
    const logic  = this._logicOf(card)
    const linear = { index: idx + 1 }
    const next   = this._nextOf(card) // unconditional flow pointer (any card type)
    if (!logic) {
      // Plain card: honour its `next` before falling to the linear next.
      return next ? (this._mapTarget(next) || linear) : linear
    }
    const value  = this._answers[card?.dataset.cardIndex]?.value
    const routes = Array.isArray(logic.routes) ? logic.routes : []
    let to = null
    for (const r of routes) {
      if (r && r.to && this._logicMatch(r.match, value)) { to = r.to; break }
    }
    if (!to && this._validTarget(logic.default)) to = logic.default
    if (!to && next) to = next // `next` is the otherwise when no route/default applies
    if (!to) return linear
    // A dangling cid target fails safe to the linear next card.
    return this._mapTarget(to) || linear
  }

  // A best-effort, answer-independent guess of whether the current card is the
  // last step (default/linear leads off the end), used only to toggle the
  // Next/Finish button label. A specific route to an end still finalises via
  // _advanceLogic regardless of the label.
  _staticNext(idx) {
    const card  = this.cardTargets[idx]
    const logic = this._logicOf(card)
    if (logic && this._validTarget(logic.default)) {
      const mapped = this._mapTarget(logic.default)
      if (mapped) return mapped
    }
    const next = this._nextOf(card)
    if (next) {
      const mapped = this._mapTarget(next)
      if (mapped) return mapped
    }
    const nxt = idx + 1
    return nxt < this.cardTargets.length ? { index: nxt } : { end: "default" }
  }

  _mapTarget(to) {
    if (!to || typeof to !== "object") return null
    if (to.end != null && to.end !== "") return { end: to.end }
    if (to.card != null && to.card !== "") {
      const ci = this._cidIndex.get(to.card)
      if (ci != null) return { index: ci }
    }
    return null
  }

  _validTarget(t) {
    return !!(t && typeof t === "object" &&
      ((t.card != null && t.card !== "") || (t.end != null && t.end !== "")))
  }

  // Mirrors LogicGraph.match?: "equals" for single-pick/scale answers,
  // "contains" for multi-pick arrays (fires when the answer includes the
  // value), "first" for prioritise (fires on the top-ranked value).
  _logicMatch(match, value) {
    if (!match || typeof match !== "object") return false
    switch (match.op) {
      case "equals": return this._norm(value) === this._norm(match.value)
      case "contains": {
        const list = Array.isArray(value) ? value : (value == null ? [] : [ value ])
        return list.some(v => this._norm(v) === this._norm(match.value))
      }
      case "first": return Array.isArray(value) && this._norm(value[0]) === this._norm(match.value)
      default: return false // unknown op fails safe to no-match (linear next)
    }
  }

  _norm(v) { return (v == null ? "" : String(v)).trim() }

  _logicOf(card) {
    const raw = card?.dataset.cardLogic
    if (!raw || raw === "null") return null
    try {
      const l = JSON.parse(raw)
      return (l && typeof l === "object") ? l : null
    } catch (_) { return null }
  }

  // The card's unconditional `next` flow pointer ({card}|{end}), or null.
  // Mirrors LogicGraph.card_next — honoured after answer routes/default.
  _nextOf(card) {
    const raw = card?.dataset.cardNext
    if (!raw || raw === "null") return null
    try {
      const n = JSON.parse(raw)
      return this._validTarget(n) ? n : null
    } catch (_) { return null }
  }

  // Share the public play link so respondents can pass the Verto on. Uses the
  // native share sheet where available (mobile), falling back to copying the
  // link to the clipboard with a brief ✓ on the button (desktop).
  //
  // The creator's own share copy is carried through. This used to pass
  // `document.title` and the URL and nothing else, which meant BOTH the share
  // headline and the "Message respondents send" field were invisible: the
  // editor asked for a line "written as the respondent, in their voice" and
  // promised "the link is added automatically", and the sheet then opened with
  // neither. share_message has no fallback by design — an empty `text` is
  // simply omitted rather than inventing words for somebody.
  async share() {
    const url = this.shareUrlValue || window.location.href
    if (navigator.share) {
      const payload = { title: this.shareTitleValue || document.title, url }
      if (this.shareTextValue) payload.text = this.shareTextValue
      try {
        await navigator.share(payload)
      } catch (_) {
        // Sheet dismissed or failed — nothing more to do.
      }
      return
    }
    try {
      await navigator.clipboard.writeText(url)
      if (this.hasShareBtnTarget) {
        const btn = this.shareBtnTarget
        const original = btn.textContent
        btn.textContent = "✓"
        setTimeout(() => { btn.textContent = original }, 1800)
      }
    } catch (_) {
      window.prompt("", url)
    }
  }

  // A stable per-session token: persisted so a refresh reuses the same
  // response row rather than creating a duplicate.
  _ensureToken() {
    const newToken = () =>
      (typeof crypto !== "undefined" && crypto.randomUUID)
        ? crypto.randomUUID()
        : Math.random().toString(36).slice(2)
    const key = `verto_session_${this.submitUrlValue}`
    try {
      let t = sessionStorage.getItem(key)
      if (!t) { t = newToken(); sessionStorage.setItem(key, t) }
      return t
    } catch (_) {
      return newToken()
    }
  }

  // The durable per-Verto identity behind the leaderboard's stable anonymous
  // names: localStorage, so unlike the session token above it survives the tab
  // and a retake groups with the earlier runs. Minted only while the board is
  // on (connect gates the call) — no leaderboard, no durable identifier on the
  // device. Storage-blocked browsers degrade to a per-visit identity (a fresh
  // name each time) rather than failing.
  _ensurePlayerKey() {
    const newKey = () =>
      (typeof crypto !== "undefined" && crypto.randomUUID)
        ? crypto.randomUUID()
        : Math.random().toString(36).slice(2)
    const key = `verto_player_${this.submitUrlValue}`
    try {
      let k = localStorage.getItem(key)
      if (!k) { k = newKey(); localStorage.setItem(key, k) }
      return k
    } catch (_) {
      return newKey()
    }
  }

  // The device's "finished this wave" marker (No retests, device basis).
  // Byte-identical to the pre-wave key while wave 1 is implicit, so devices
  // gated before waves existed stay gated; a later wave gets its own key,
  // which is what re-admits every device when the owner starts one.
  _playedKey() {
    const w = this.waveValue
    return (w && w !== "1") ? `verto_played_${this.submitUrlValue}_w${w}` : `verto_played_${this.submitUrlValue}`
  }

  _playedBefore() {
    try {
      return !!localStorage.getItem(this._playedKey())
    } catch (_) {
      return false
    }
  }

  // Only on the device basis, and only for a live run: owner preview and Test
  // Mode carry a blank submit URL and must never write a shared key.
  _markPlayed() {
    if (this.noRetestsValue !== "device" || !this.submitUrlValue) return
    try { localStorage.setItem(this._playedKey(), "1") } catch (_) { /* storage blocked */ }
  }

  // The server refused a run as a retake: mark this device (device basis only)
  // and land on the refused screen. Nothing was stored.
  _refuseRetake() {
    this._markPlayed()
    this._showAlreadyPlayed()
  }

  // Whether a non-OK response is No retests' refusal (one constant body), as
  // opposed to a closed Verto or a fault.
  async _alreadyPlayed(res) {
    const body = await res.clone().json().catch(() => null)
    return !!(body && body.code === "already_played")
  }

  // Play again (hidden under No retests, and under the first-run-counts policy
  // where a replay could not move the board) and "Next person" (a Verto whose
  // No retests identity is the code) share these mechanics: a fresh session
  // token means a fresh response row, so the next pupil on a shared device
  // never writes onto the last one's. The durable player key survives, so a
  // replayer's runs group under the same identity and name.
  // A reload rather than in-place state surgery: connect() is the only place
  // the deck's state machine starts clean.
  playAgain() {
    try { sessionStorage.removeItem(`verto_session_${this.submitUrlValue}`) } catch (_) { /* storage blocked */ }
    window.location.reload()
  }

  // Register this session as a responder once it has ≥1 real answer, so people
  // who answer something then leave are still counted. Fires once on success —
  // except under No going back, where every advance is saved: the server can
  // only pin an answer it holds (locked_merge), so "the card you left is
  // final" needs each answer on the server before the next card is shown.
  async _saveProgress() {
    // After a decline nothing more may leave this device — the server refuses
    // it now (403), but not sending is the behaviour the respondent was
    // promised, not merely being refused.
    if (this._declined) return
    if ((this._registered && !this.noGoingBackValue) || !this.progressUrlValue) return
    const hasAnswer = Object.values(this._answers).some(a => this._isAnswerGiven(a))
    if (!hasAnswer) return
    try {
      const res = await fetch(this.progressUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this._payload())
      })
      if (res.ok) { this._registered = true; return }
      // No retests: a completed run under this identity already exists in the
      // current wave (a code delivered mid-deck, or a device the marker
      // missed). Nothing was stored; land on the refused screen.
      if (await this._alreadyPlayed(res)) this._refuseRetake()
    } catch (_) { /* retry on the next navigation */ }
  }

  // Whether the card at `idx` has a usable answer (a value, or free-text Other).
  _isCardAnswered(idx) {
    const key = this.cardTargets[idx]?.dataset.cardIndex
    if (key === undefined || key === "") return true // non-answer cards never block
    return this._isAnswerGiven(this._answers[key])
  }

  // Required gate: a card marked data-card-required must be answered before the
  // player advances past it. Returns true when it's safe to proceed.
  _requireGuard(idx) {
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardRequired !== "true" || this._isCardAnswered(idx)) {
      this._clearRequiredHint()
      return true
    }
    this._showRequiredHint(card)
    return false
  }

  // The scenario_controller instance for card `idx`, if it's a scenario card.
  _scenarioController(idx) {
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardType !== "scenario") return null
    const el = card.querySelector('[data-controller~="scenario"]')
    if (!el) return null
    return this.application.getControllerForElementAndIdentifier(el, "scenario")
  }

  // Ask card `idx`'s book to turn a page instead of the deck advancing.
  // Returns true if a page actually turned (book wasn't already at that
  // edge) — next()/back()/finish() fall through to normal navigation
  // otherwise, so a scenario at its answer page behaves like any other card.
  _scenarioTurn(idx, delta) {
    const ctrl = this._scenarioController(idx)
    if (!ctrl) return false
    return delta > 0 ? ctrl.next() : ctrl.back()
  }

  _showRequiredHint(card) {
    if (this.hasRequiredHintTarget) this.requiredHintTarget.classList.remove("hidden")
    if (card) {
      card.classList.remove("card-shake")
      void card.offsetWidth // reflow so the shake restarts on a repeated tap
      card.classList.add("card-shake")
    }
  }

  _clearRequiredHint() {
    if (this.hasRequiredHintTarget) this.requiredHintTarget.classList.add("hidden")
  }

  // Answers are keyed by the card's position in @survey.cards (data-card-index),
  // NOT its position among the card targets — the consent card carries no index
  // and is skipped, so prepending it never shifts the answer keys.
  _capture(idx) {
    const card = this.cardTargets[idx]
    if (!card) return
    const key = card.dataset.cardIndex
    if (key === undefined || key === "") return
    this._answers[key] = this._answerOf(card)
    // Ask-once questions remember their answer on the device the moment it is
    // given, alongside the identity that gave it — the durable player key in
    // this same storage — so the next run seeds and skips (see
    // _seedOnceAnswers). Storage and identity live or die together: clearing
    // one clears both, which is what keeps "asked once PER PERSON" honest.
    if (card.dataset.cardAskOnce === "true" && this._isAnswerGiven(this._answers[key])) {
      this._writeOnceStore(key, this._answers[key])
    }
  }

  // What this card holds right now, in the shape _isAnswerGiven reads.
  // _capture stores it on the way past; the Next button's answered state asks
  // the same question live, on every tap. Both go through here so the button
  // can never light up for something the deck wouldn't actually record.
  _answerOf(card) {
    const type  = card.dataset.cardType
    const value = this._read(card, type)
    // "Other" is a standalone answer: if the respondent typed free text it
    // replaces any normal selection for this card.
    const other = card.querySelector("[data-other-input]")?.value.trim()
    return other ? { type, value: null, other } : { type, value }
  }

  // The canonical (primary-language) label an option element answers as.
  _canonicalOf(el) {
    if (!el) return null
    const c = el.dataset.canonical
    if (c !== undefined && c !== "") return c
    return el.querySelector(".pick-text, .choice-label")?.textContent.trim() ?? null
  }

  _read(card, type) {
    switch (type) {
      // Choice answers store the CANONICAL (primary-language) option label, so
      // results aggregate across languages regardless of the displayed text.
      case "multiple_choice":
      case "yes_no":
      case "select_one_grid":
      case "scenario":
        return this._canonicalOf(
          card.querySelector('[data-picker-target="item"][data-selected="true"]')
        )

      case "select_many":
      case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-picker-target="item"][data-selected="true"]'))
                    .map(el => this._canonicalOf(el))
                    .filter(v => v !== null)

      case "prioritise": {
        // The ordered canonical labels, top (highest priority) → bottom. Only
        // counts once the respondent has arranged the list.
        const list = card.querySelector(".prioritise-list")
        if (!list || list.dataset.prioritiseTouched !== "true") return null
        return Array.from(list.querySelectorAll(".prioritise-item"))
                    .map(el => this._canonicalOf(el))
                    .filter(v => v !== null)
      }

      case "range": {
        const dots   = Array.from(card.querySelectorAll(".s-dot"))
        const active = dots.findIndex(d => d.classList.contains("active"))
        return active >= 0 ? active : null
      }

      case "nps": {
        const el = card.querySelector(".nps-slider")
        if (el) {
          const v = el.dataset.npsValue
          return (v !== undefined && v !== "") ? Number(v) : null
        }
        // Feature flag off: the card is rendered as a plain range slider.
        const dots   = Array.from(card.querySelectorAll(".s-dot"))
        const active = dots.findIndex(d => d.classList.contains("active"))
        return active >= 0 ? active : null
      }

      case "rating": {
        const count = Array.from(card.querySelectorAll(".rating-star.active")).length
        return count > 0 ? count : null
      }

      case "tap_card": {
        const wrap = card.querySelector(".rotate-wrap")
        try { return JSON.parse(wrap?.dataset.swipeResults || "null") } catch { return null }
      }

      case "open_ended": {
        // Location demographic: a hidden input carries the resolved
        // "CC|Label" the location-search widget picked (see
        // location_search_controller.js) — this is the app's one universal
        // source of region data (see PlayerController#sync_region_from_answers!).
        const loc = card.querySelector(".location-search-value")
        if (loc) return loc.value || null

        // Month+year demographic: two plain numeric fields, not a native
        // <input type="month"> (see _card_component.html.erb) — combine them
        // into the same "YYYY-MM" shape a native month input would have given.
        const month = card.querySelector(".freeform-month")
        if (month) {
          const year = card.querySelector(".freeform-year")
          const m = month.value.trim(), y = year?.value.trim()
          return (m && y && y.length === 4) ? `${y}-${m.padStart(2, "0")}` : null
        }
        const el = card.querySelector("textarea, input[type='date']")
        return el?.value?.trim() || null
      }

      default:
        return null
    }
  }

  _showThankyou(queued = false, rejected = false) {
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this._applyEndScreen(this._endId)
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    this.progressTarget.textContent = ""
    const note = rejected ? t("player.submit_rejected") : (queued ? t("player.queued") : null)
    if (note && this.hasThankyouMainTarget && !this.thankyouMainTarget.querySelector(".preview-queued-pill")) {
      const pill = document.createElement("div")
      pill.className = rejected ? "preview-queued-pill is-rejected" : "preview-queued-pill"
      pill.textContent = note
      this.thankyouMainTarget.appendChild(pill)
    }
    if (this.quizValue) this._renderQuizScore()
    if (this.tokenisationValue) this._renderTokenScore()
    if (this.leaderboardValue) this._renderLeaderboard(queued, rejected)
    this._renderJoinState(rejected)
  }

  // Swap the thank-you screen's title / message / forward CTA to the end screen
  // a branch routed to (default when unrouted or the id is unknown — fail-safe).
  _applyEndScreen(id) {
    const screens = this.endScreensValue || []
    if (!screens.length) return
    const s = screens.find(x => x.id === id) ||
              screens.find(x => x.id === "default") || screens[0]
    if (!s) return
    const vars = this._endScreenVars()
    if (this.hasThankyouTitleTarget && s.title) this.thankyouTitleTarget.textContent = this._interpolateEndScreen(s.title, vars)
    if (this.hasThankyouSubTarget && s.body != null) {
      this.thankyouSubTarget.replaceChildren()
      this._interpolateEndScreen(String(s.body), vars).split("\n").forEach((line, i) => {
        if (i) this.thankyouSubTarget.appendChild(document.createElement("br"))
        this.thankyouSubTarget.appendChild(document.createTextNode(line))
      })
    }
    if (this.hasForwardBtnTarget) {
      if (s.forward_url) {
        this.forwardBtnTarget.href = s.forward_url
        this.forwardBtnTarget.textContent = `${s.forward_label || this.forwardLabelValue || t("player.visit_website")} →`
        this.forwardBtnTarget.classList.remove("hidden")
      } else {
        this.forwardBtnTarget.classList.add("hidden")
      }
    }
  }

  // Template variables an end-screen title/body may reference: %{score}/%{max}
  // (quiz totals, only when this Verto actually grades), %{points} (summed
  // across every token type) and %{points:<token_id>} (one type only).
  // Deliberately never covers forward_url — that stays a creator-authored
  // literal link, not text.
  //
  // %{name} used to sit here too, read off an answered contact card. Nothing
  // asks a respondent their name since that card type was retired, so the
  // variable is gone rather than left resolving to nothing forever; an
  // end-screen written before the retirement still renders, because an
  // unknown var takes its %{name|fallback} text (or is stripped) below.
  _endScreenVars() {
    const hasTokens = Object.keys(this._tokenTotals).length > 0
    return {
      score: this._quizMax > 0 ? this._quizScore : null,
      max: this._quizMax > 0 ? this._quizMax : null,
      points: hasTokens ? Object.values(this._tokenTotals).reduce((sum, v) => sum + (v || 0), 0) : null
    }
  }

  // %{var}, %{points:<token_id>} for one token type, and an inline fallback
  // %{var|text} for when the value never resolved (not a quiz, tokenisation
  // off, or a variable that no longer exists) — stripped to "" without a fallback,
  // same as the rest of this method already did for a missing var before
  // personalisation existed, so an unanswered path never prints a raw %{...}.
  _interpolateEndScreen(str, vars) {
    return str.replace(/%\{(\w+)(?::([\w-]+))?(?:\|([^}]*))?\}/g, (_match, key, sub, fallback) => {
      const value = (key === "points" && sub) ? this._tokenTotals[sub] : vars[key]
      if (value == null || value === "") return fallback != null ? fallback : ""
      return String(value)
    })
  }

  // One button, one panel: the quiz score section and the general answer-
  // comparison section each load independently (whichever the creator has
  // turned on) so one being slow/unavailable never blocks the other.
  async showCompare() {
    const wantScores  = this.hasScoresSectionTarget
    const wantCompare = this.showComparisonValue && this.resultsUrlValue && this.hasComparisonSectionTarget
    if (!wantScores && !wantCompare || !this.hasComparePanelTarget) return

    this.thankyouMainTarget.classList.add("hidden")
    this.comparePanelTarget.classList.remove("hidden")
    if (this.hasCompareBtnTarget) this.compareBtnTarget.disabled = true

    const tasks = []
    if (wantScores) tasks.push(this._loadScores())
    if (wantCompare) tasks.push(this._loadComparison())
    await Promise.all(tasks)

    if (this.hasCompareBtnTarget) this.compareBtnTarget.disabled = false
  }

  hideCompare() {
    if (this.hasComparePanelTarget) this.comparePanelTarget.classList.add("hidden")
    if (this.hasThankyouMainTarget) this.thankyouMainTarget.classList.remove("hidden")
  }

  async _loadComparison() {
    if (this.hasComparisonMetaTarget) this.comparisonMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.resultsUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed to load results")
      this._renderComparison(data)
    } catch (e) {
      if (this.hasComparisonMetaTarget) this.comparisonMetaTarget.textContent = t("player.compare_error")
    }
  }

  // ── Regions map: where answers came from, per-region comparison ──

  async showRegions() {
    if (!this.regionsUrlValue || !this.hasRegionsPanelTarget) return
    this.thankyouMainTarget.classList.add("hidden")
    if (this.hasComparePanelTarget) this.comparePanelTarget.classList.add("hidden")
    this.regionsPanelTarget.classList.remove("hidden")
    this._resetMapView()
    if (this._regionsData) return
    this.regionsMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.regionsUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed to load regions")
      this._regionsData = data
      this._renderRegions(data)
    } catch (_) {
      this.regionsMetaTarget.textContent = t("player.compare_error")
    }
  }

  // Back button: detail view returns to the map, the map closes the panel.
  hideRegions() {
    if (this.hasRegionDetailTarget && !this.regionDetailTarget.classList.contains("hidden")) {
      this.regionDetailTarget.classList.add("hidden")
      this.regionsMainTarget.classList.remove("hidden")
      return
    }
    this.regionsPanelTarget.classList.add("hidden")
    this.thankyouMainTarget.classList.remove("hidden")
  }

  _renderRegions(data) {
    const regions = data.regions || []
    this.regionsMetaTarget.textContent = t("player.region_meta", { count: data.total_tagged || 0 })

    // Choropleth: tint each country by its share of region-tagged responses.
    // Some countries are <g> groups — inline fill must land on the paths to
    // beat the stylesheet's base fill.
    const byCountry = {}
    regions.forEach(r => { byCountry[r.country] = (byCountry[r.country] || 0) + r.responders })
    const max = Math.max(1, ...Object.values(byCountry))
    const svg = this.regionsPanelTarget.querySelector(".world-map")
    if (svg) Object.entries(byCountry).forEach(([cc, n]) => {
      const el = svg.querySelector(`#${cc.toLowerCase()}`)
      if (!el) return
      const alpha = 0.18 + 0.72 * (n / max)
      const paths = el.tagName.toLowerCase() === "g" ? el.querySelectorAll("path") : [el]
      paths.forEach(p => { p.style.fill = `rgba(1,234,203,${alpha.toFixed(2)})` })
      const tip = document.createElementNS("http://www.w3.org/2000/svg", "title")
      tip.textContent = `${regions.find(r => r.country === cc)?.country_name || cc}: ${n}`
      el.appendChild(tip)
      el.style.cursor = "pointer"
      el.addEventListener("click", () => this._highlightCountry(cc))
    })

    const list = this.regionsListTarget
    list.innerHTML = ""
    if (regions.length === 0) {
      const empty = document.createElement("div")
      empty.className = "play-panel-empty"
      empty.textContent = t("player.region_empty")
      list.appendChild(empty)
      return
    }
    regions.forEach(region => {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "region-row"
      row.dataset.country = region.country
      const name = document.createElement("span")
      name.className = "play-region-name"
      name.textContent = region.label ? `${region.country_name} · ${region.label}` : region.country_name
      const count = document.createElement("span")
      count.className = "play-region-count"
      count.textContent = t("player.region_answered", { count: region.responders })
      const arrow = document.createElement("span")
      arrow.className = "play-region-arrow"
      arrow.textContent = t("player.region_compare")
      row.append(name, count, arrow)
      row.addEventListener("click", () => this._showRegionDetail(region))
      list.appendChild(row)
    })
  }

  _highlightCountry(cc) {
    this.regionsListTarget.querySelectorAll(".region-row").forEach(row => {
      row.classList.toggle("active-country", row.dataset.country === cc)
    })
    const first = this.regionsListTarget.querySelector(`.region-row[data-country="${cc}"]`)
    if (first) first.scrollIntoView({ behavior: "smooth", block: "nearest" })
  }

  // Region vs you: reuses the comparison row renderer, so each question shows
  // the region's distribution with this respondent's own answer highlighted.
  _showRegionDetail(region) {
    this.regionsMainTarget.classList.add("hidden")
    this.regionDetailTarget.classList.remove("hidden")
    const name = region.label ? `${region.country_name} · ${region.label}` : region.country_name
    this.regionDetailTitleTarget.textContent =
      `${name} — ${t("player.region_answered", { count: region.responders })}`
    const list = this.regionDetailListTarget
    list.innerHTML = ""
    ;(region.results || []).forEach(row => {
      if (NON_QUESTION_TYPES.includes(row.type)) return
      const mine = this._answers[String(row.index)]?.value
      list.appendChild(this._buildRow(row, mine))
    })
  }

  // ── Regions map pan/zoom: plain translate+scale on the stage div, driven
  // by Pointer Events (mouse drag, touch drag, two-finger pinch) and wheel.
  // A "click" that lands right after a drag/pinch is swallowed at the
  // capture phase so panning never mis-fires a country selection.

  _setupMapPanZoom() {
    const vp = this.regionsMapViewportTarget
    vp.addEventListener("wheel", this._onMapWheel.bind(this), { passive: false })
    vp.addEventListener("pointerdown", this._onMapPointerDown.bind(this))
    vp.addEventListener("pointermove", this._onMapPointerMove.bind(this))
    vp.addEventListener("pointerup", this._onMapPointerUp.bind(this))
    vp.addEventListener("pointercancel", this._onMapPointerUp.bind(this))
    vp.addEventListener("click", this._onMapClickCapture.bind(this), true)
  }

  _resetMapView() {
    this._mapScale = 1
    this._mapX = 0
    this._mapY = 0
    this._applyMapTransform()
  }

  resetMapView() {
    if (!this.hasRegionsMapStageTarget) return
    this.regionsMapStageTarget.classList.add("is-animating")
    this._resetMapView()
    setTimeout(() => this.regionsMapStageTarget.classList.remove("is-animating"), 260)
  }

  zoomInMap()  { this._zoomAroundViewportCenter(1.5) }
  zoomOutMap() { this._zoomAroundViewportCenter(1 / 1.5) }

  _zoomAroundViewportCenter(factor) {
    if (!this.hasRegionsMapViewportTarget) return
    const rect = this.regionsMapViewportTarget.getBoundingClientRect()
    this.regionsMapStageTarget.classList.add("is-animating")
    this._zoomAt(rect.width / 2, rect.height / 2, factor)
    setTimeout(() => this.regionsMapStageTarget.classList.remove("is-animating"), 260)
  }

  // Keeps the point under (cx, cy) — in viewport-local pixels — visually
  // fixed while the scale changes, the standard "zoom to point" transform.
  _zoomAt(cx, cy, factor) {
    const newScale = Math.min(MAP_MAX_SCALE, Math.max(MAP_MIN_SCALE, this._mapScale * factor))
    if (newScale === this._mapScale) return
    this._mapX = cx - (newScale / this._mapScale) * (cx - this._mapX)
    this._mapY = cy - (newScale / this._mapScale) * (cy - this._mapY)
    this._mapScale = newScale
    this._applyMapTransform()
  }

  _applyMapTransform() {
    if (!this.hasRegionsMapStageTarget) return
    this.regionsMapStageTarget.style.transform =
      `translate(${this._mapX}px, ${this._mapY}px) scale(${this._mapScale})`
  }

  _onMapWheel(e) {
    e.preventDefault()
    const rect = this.regionsMapViewportTarget.getBoundingClientRect()
    const factor = Math.pow(1.0015, -e.deltaY)
    this._zoomAt(e.clientX - rect.left, e.clientY - rect.top, factor)
  }

  _onMapPointerDown(e) {
    // Reset before the zoom-btn early-return below, so a stale "true" left
    // over from a pan that ended over the map can never survive into the
    // next tap and get misread by _onMapClickCapture as another drag.
    this._mapDragMoved = false
    // Let zoom-control buttons handle their own clicks — capturing the
    // pointer here would retarget their mouseup/click to the viewport instead.
    if (e.target.closest(".regions-zoom-btn")) return
    this.regionsMapViewportTarget.setPointerCapture(e.pointerId)
    this._mapPointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
    this._mapDragStart = { x: e.clientX, y: e.clientY }
    if (this._mapPointers.size === 2) {
      const [a, b] = [...this._mapPointers.values()]
      this._mapPinchStartDist = Math.hypot(a.x - b.x, a.y - b.y) || 1
      this._mapPinchStartScale = this._mapScale
    }
    this.regionsMapViewportTarget.classList.add("is-dragging")
  }

  _onMapPointerMove(e) {
    if (!this._mapPointers.has(e.pointerId)) return
    const prev = this._mapPointers.get(e.pointerId)
    this._mapPointers.set(e.pointerId, { x: e.clientX, y: e.clientY })

    if (this._mapPointers.size === 2) {
      const [a, b] = [...this._mapPointers.values()]
      const rect = this.regionsMapViewportTarget.getBoundingClientRect()
      const dist = Math.hypot(a.x - b.x, a.y - b.y) || 1
      const midX = (a.x + b.x) / 2 - rect.left
      const midY = (a.y + b.y) / 2 - rect.top
      const target = Math.min(MAP_MAX_SCALE, Math.max(MAP_MIN_SCALE,
        this._mapPinchStartScale * (dist / this._mapPinchStartDist)))
      this._mapX = midX - (target / this._mapScale) * (midX - this._mapX)
      this._mapY = midY - (target / this._mapScale) * (midY - this._mapY)
      this._mapScale = target
      this._applyMapTransform()
      this._mapDragMoved = true
      return
    }

    this._mapX += e.clientX - prev.x
    this._mapY += e.clientY - prev.y
    if (Math.abs(e.clientX - this._mapDragStart.x) > 4 || Math.abs(e.clientY - this._mapDragStart.y) > 4) {
      this._mapDragMoved = true
    }
    this._applyMapTransform()
  }

  _onMapPointerUp(e) {
    this._mapPointers.delete(e.pointerId)
    if (this._mapPointers.size === 0) {
      this.regionsMapViewportTarget.classList.remove("is-dragging")
    } else {
      // Dropped from a pinch back to a single finger — resync the pan
      // baseline so the remaining pointer doesn't jump on its next move.
      const [remaining] = this._mapPointers.values()
      this._mapDragStart = { x: remaining.x, y: remaining.y }
    }
  }

  // Suppresses the ghost "click" a browser fires on pointerup after a
  // drag/pinch, so panning the map never mis-selects the country underneath.
  _onMapClickCapture(e) {
    if (this._mapDragMoved) {
      e.stopPropagation()
      e.preventDefault()
      this._mapDragMoved = false
    }
  }

  _renderComparison(data) {
    const total = data.total_responses || 0
    // Small-cell suppression (P1-14): with only a handful of responders the
    // "comparison" would be one other person's answers. The server withholds
    // the rows; say why rather than showing an empty panel.
    if (data.suppressed) {
      if (this.hasComparisonMetaTarget) this.comparisonMetaTarget.textContent = t("player.compare_too_few")
      this.comparisonListTarget.innerHTML = ""
      return
    }
    if (this.hasComparisonMetaTarget) {
      this.comparisonMetaTarget.textContent =
        `Based on ${total} response${total === 1 ? "" : "s"} (including yours)`
    }
    const list = this.comparisonListTarget
    list.innerHTML = ""
    ;(data.results || []).forEach(row => {
      if (NON_QUESTION_TYPES.includes(row.type)) return
      // Tokenisation: synthetic rows appended by PlayerController#results
      // (folding "compare your tokens" into this same panel) aren't keyed to
      // a card index — "mine" is this session's own final total instead.
      const mine = row.type === "token_total"
        ? (this._tokenTotals[row.token_id] || 0)
        : this._answers[String(row.index)]?.value
      list.appendChild(this._buildRow(row, mine))
    })
  }

  _buildRow(row, mine) {
    const wrap = document.createElement("div")
    wrap.style.cssText = "background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);border-radius:14px;padding:14px 16px;"

    const prompt = document.createElement("div")
    prompt.className = "play-compare-prompt"
    prompt.textContent = row.prompt || `Question ${row.index + 1}`
    wrap.appendChild(prompt)

    const yourPill = document.createElement("div")
    yourPill.className = "play-compare-mine"
    yourPill.textContent = `Your answer: ${this._formatMine(mine, row)}`
    wrap.appendChild(yourPill)

    const body = this._buildDistribution(row, mine)
    if (body) wrap.appendChild(body)

    return wrap
  }

  _formatMine(mine, row) {
    if (mine === null || mine === undefined || mine === "") return "—"
    if (row.type === "prioritise" && Array.isArray(mine)) return mine.length ? mine.join(" › ") : "—"
    if (Array.isArray(mine)) return mine.length ? mine.join(", ") : "—"
    if ((row.type === "range" || row.type === "nps") && Array.isArray(row.options)) {
      return row.options[mine] || `Step ${Number(mine) + 1}`
    }
    if (row.type === "rating") return `${mine} ★`
    if (typeof mine === "object") {
      return Object.entries(mine).map(([k, v]) => `${k}: ${v}`).join(", ")
    }
    return String(mine)
  }

  _buildDistribution(row, mine) {
    const container = document.createElement("div")
    container.style.cssText = "display:flex;flex-direction:column;gap:14px;"

    const counts = row.counts || {}
    let entries = []

    if ((row.type === "range" || row.type === "nps") && Array.isArray(row.options)) {
      entries = row.options.map((label, i) => [label, counts[i] || counts[String(i)] || 0, i])
    } else if (row.type === "rating") {
      const max = Math.max(5, ...Object.keys(counts).map(k => parseInt(k) || 0))
      for (let i = 1; i <= max; i++) entries.push([`${i} ★`, counts[i] || counts[String(i)] || 0, i])
    } else if (row.type === "open_ended") {
      const note = document.createElement("div")
      note.className = "play-compare-note"
      note.textContent = `${row.total || 0} open-ended response${row.total === 1 ? "" : "s"} total`
      container.appendChild(note)
      return container
    } else if (row.type === "token_total") {
      // Tokenisation compare row: counts is a histogram keyed by exact total
      // amount (mirrors the quiz score distribution) — sort ascending and
      // highlight this session's own bucket.
      const amounts = Object.keys(counts).map(Number).sort((a, b) => a - b)
      const grand = amounts.reduce((s, a) => s + (counts[a] || counts[String(a)] || 0), 0) || 1
      amounts.forEach(amt => {
        const count = counts[amt] || counts[String(amt)] || 0
        const pct = Math.round((count / grand) * 100)
        container.appendChild(this._buildBar(String(amt), count, pct, Number(mine) === amt))
      })
      return container
    } else if (row.type === "prioritise") {
      // counts[label] = sum of ranks across responders; lower mean = higher
      // priority. Show the aggregate order with each option's average position.
      const total = row.total || 1
      const ranked = Object.entries(counts)
        .map(([label, sumRank]) => ({ label, mean: sumRank / total }))
        .sort((a, b) => a.mean - b.mean)
      const n = ranked.length || 1
      ranked.forEach(({ label, mean }, i) => {
        const pct = Math.round(Math.max(0, Math.min(1, (n - mean + 1) / n)) * 100)
        container.appendChild(this._buildBar(`${i + 1}. ${label}`, `avg ${mean.toFixed(1)}`, pct, false))
      })
      return container
    } else if (row.type === "tap_card") {
      // One bar per response on the card's own scale, in scale order — the
      // server sends it alongside the counts (aggregate_rows) because the keys
      // alone don't say what a creator called them or which order they run in.
      const scale = Array.isArray(row.responses) && row.responses.length
        ? row.responses
        : presetFor(DEFAULT_TAP_COUNT)
      Object.entries(counts).forEach(([label, tallies]) => {
        const t = tallies || {}
        const sum = scale.reduce((n, r) => n + (Number(t[r.key]) || 0), 0) || 1
        scale.forEach(r => {
          entries.push([ `${label} — ${r.label}`, Number(t[r.key]) || 0, `${label}:${r.key}`, sum ])
        })
      })
    } else {
      // Unordered options (multiple choice, yes/no, …) read best as a ranked
      // chart — most popular first.
      entries = Object.entries(counts)
        .map(([label, n]) => [label, n, label])
        .sort((a, b) => b[1] - a[1])
    }

    if (entries.length === 0) return null

    const grand = entries.reduce((s, e) => s + (e[3] || e[1]), 0) || 1
    entries.forEach(([label, count, key, denom]) => {
      const pct = Math.round((count / (denom || grand)) * 100)
      const isMine = this._isMineMatch(mine, key, row)
      container.appendChild(this._buildBar(label, count, pct, isMine))
    })
    return container
  }

  _isMineMatch(mine, key, row) {
    if (mine === null || mine === undefined) return false
    if (Array.isArray(mine)) return mine.map(String).includes(String(key))
    if (row.type === "range" || row.type === "nps") return Number(mine) === Number(key)
    if (row.type === "rating") return Number(mine) === Number(key)
    if (row.type === "tap_card" && typeof mine === "object" && typeof key === "string") {
      // "<statement>:<response key>". Split on the LAST colon, not the first: a
      // response key never contains one but a statement very well might ("Cost:
      // too high"), and splitting from the front would hand back half a
      // statement and lose the answer.
      const cut = key.lastIndexOf(":")
      if (cut < 0) return false
      return mine[key.slice(0, cut)] === key.slice(cut + 1)
    }
    return String(mine) === String(key)
  }

  _buildBar(label, count, pct, isMine) {
    const row = document.createElement("div")
    row.style.cssText = "display:flex;flex-direction:column;gap:5px;"

    // Header: full label (the respondent's choice is dotted + brand-coloured),
    // a prominent percentage, and the raw count.
    const head = document.createElement("div")
    head.style.cssText = "display:flex;align-items:baseline;gap:8px;"

    const lbl = document.createElement("span")
    lbl.className = `play-bar-label${isMine ? " is-mine" : ""}`
    lbl.textContent = (isMine ? "● " : "") + label
    head.appendChild(lbl)

    const pctEl = document.createElement("span")
    pctEl.className = "play-bar-pct"
    pctEl.textContent = `${pct}%`
    head.appendChild(pctEl)

    const countEl = document.createElement("span")
    countEl.className = "play-bar-count"
    countEl.textContent = count
    head.appendChild(countEl)
    row.appendChild(head)

    // Thicker track with a fill that animates up from zero on render.
    const track = document.createElement("div")
    track.style.cssText = "height:10px;border-radius:5px;background:rgba(255,255,255,0.07);overflow:hidden;"
    const fill = document.createElement("div")
    fill.style.cssText = `height:100%;border-radius:5px;width:0;transition:width 0.7s cubic-bezier(0.16,1,0.3,1);background:${isMine ? "var(--brand-primary,#01EACB)" : "rgba(255,255,255,0.3)"};`
    track.appendChild(fill)
    row.appendChild(track)
    requestAnimationFrame(() => { fill.style.width = `${pct}%` })

    return row
  }

  _update() {
    this._clearRequiredHint()
    // Any navigation invalidates a pending tap-stack auto-advance — the
    // respondent got there first (or the timer itself did; next() lands here).
    this._cancelAutoAdvance()
    const cards = this.cardTargets
    const idx   = this.currentValue
    cards.forEach((c, i) => c.classList.toggle("active", i === idx))
    this._animateCardEntry(cards[idx], idx)
    // The creator's intro modal, if this card carries one and this run has not
    // already met it. Before the nav work below, because an open modal hides
    // the nav (the attribute it sets is read by CSS, exactly as the consent
    // banner's is) and the branch that leaves early must leave with it set.
    this._syncCardModal(cards[idx])

    // Self-driving shapes: "consent_gate" is a real multi-page card the
    // creator placed in the deck, and the respondent-code gate is a leading
    // pseudo-card. Both drive themselves, so both suppress the deck nav; only
    // a gate sitting FIRST is held out of the progress count, the same way a
    // mid-deck welcome card or checkpoint is counted where it stands. (The
    // survey-level consent gate is not in the deck at all any more — it is
    // the bottom banner, and its nav suppression is CSS keyed off
    // data-consent-pending, not this branch.)
    // Leading pseudo-cards (today only the respondent-code gate) carry no
    // data-card-index, because they're not positions in @survey.cards and
    // must never shift the answer keys. Counting them is also how they stay
    // out of the progress the respondent sees — derived from the absence of
    // an index rather than a hardcoded 1, which is why the consent card's
    // removal changed nothing here: offset simply reads 0 (or 1 with the
    // code gate) and every formula below still holds.
    let offset = 0
    while (offset < cards.length && cards[offset].dataset.cardIndex == null) offset++
    const onConsent = SELF_DRIVING_TYPES.includes(cards[idx]?.dataset.cardType)

    if (onConsent) {
      // The consent gate drives itself (Agree / decline) — hide the deck nav.
      // A multi-page gate turns its pages with the book's own chevrons, so
      // nothing here needs to reach them.
      this.progressTarget.textContent = ""
      this.element.style.setProperty("--player-progress", "0%")
      this.backBtnTarget.classList.add("invisible")
      this.nextBtnTarget.classList.add("hidden")
      this.finishBtnTarget.classList.add("hidden")
      return
    }

    // `offset` (computed above) holds the leading pseudo-cards out of the
    // progress the respondent sees.
    const total  = cards.length - offset
    // With logic the path is variable and its length unknown up front, so show
    // honest, monotonic path progress against the deck size as a loose upper
    // bound. Linear mode keeps its exact "n of N". The path stack already
    // includes the consent card when present, so it shares the same offset.
    const n = this.logicValue
      ? Math.min(Math.max(this._path.length - offset, 1), total)
      : idx + 1 - offset
    this.progressTarget.textContent = t("player.progress", { n, total })
    this.element.style.setProperty("--player-progress", `${Math.min(100, Math.round((n / total) * 100))}%`)
    // No going back removes the button outright (`hidden`); the `invisible`
    // ghost below means "nowhere to go", not "not allowed".
    this.backBtnTarget.classList.toggle("hidden", this.noGoingBackValue)
    // Don't allow stepping back onto a leading gate once past it (the
    // respondent-code card), or off the start of the visited path under logic.
    this.backBtnTarget.classList.toggle("invisible", this.logicValue ? this._path.length <= 1 : idx === offset)
    // Under logic, "last" depends on the graph, not the array position.
    const isLast = this.logicValue ? (this._staticNext(idx).end != null) : (idx >= this._lastInteractiveIndex())
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
    if (this.quizValue) this._labelQuizNav()
    if (this.tokenisationValue) this._maybeRenderCheckpoint(idx)
    // Which button is showing, and what it says, both just changed — and on a
    // card the respondent has already answered (stepping back) the glow has to
    // be on the moment the card appears, not on their next tap.
    this._syncAnswered()
    this._fitFooter()
    this._fitCard()
    // After _fitCard, which is what decides whether the answer overflows at
    // all — and on a frame of its own, because the panel is still settling
    // into the height _fitCardHeight just gave it and a box measured mid-flight
    // reports the overflow of a layout nobody will ever see.
    requestAnimationFrame(() => this._maybeNudgeScroll(idx))
  }

  // ── The creator's intro modal ─────────────────────────────────────────────
  // A pop-up the creator wrote to explain the card it sits on, shown the FIRST
  // time the respondent lands there. Its mechanics are the consent banner's,
  // deliberately: an attribute on the overlay dims the deck and takes the nav
  // away, so there is exactly one way forward while it is open and no second
  // definition of "a panel over the question" to keep in step with the first.
  //
  // Once per card per run. Going back and forward again finds it shut — being
  // told the same thing twice reads as a bug, and the re-open pill on the card
  // is how somebody who tapped past it too fast gets the words back.

  _syncCardModal(card) {
    // Never while the survey-level consent banner is up. That state makes the
    // whole deck `inert` and dims it, so a modal opened underneath it would be
    // a pop-up the respondent can see, cannot dismiss, and did not ask for —
    // two panels over one question, one of them dead. _dismissConsentBanner
    // re-runs _update(), so a first card that has one still gets it, a moment
    // later, with the deck live.
    if (this.element.hasAttribute("data-consent-pending")) return
    const open = !!card && card.dataset.cardModal === "true" && !this._modalSeen.has(this._modalKey(card))
    open ? this._openCardModal(card) : this._closeCardModal({ seen: false })
  }

  _openCardModal(card) {
    const layer = card.querySelector("[data-role='card-modal']")
    if (!layer) return
    layer.hidden = false
    card.querySelector(".split-card")?.classList.add("card-modal-open")
    card.querySelector("[data-role='card-modal-reopen']")?.setAttribute("hidden", "")
    this.element.setAttribute("data-card-modal-open", "")
    // The dismiss button, not the panel: it is the only control in there, so
    // it is where a keyboard or screen-reader respondent should land, and Enter
    // from that position does the one thing the modal is for.
    layer.querySelector(".card-modal-cta")?.focus({ preventScroll: true })
  }

  // `seen` records the dismissal. Navigation calls this with seen:false — it is
  // only tidying up a modal the respondent has left behind, and must not mark
  // as read a card they never opened one on.
  _closeCardModal({ seen }) {
    this.element.removeAttribute("data-card-modal-open")
    this.cardTargets.forEach(card => {
      if (card.dataset.cardModal !== "true") return
      const layer = card.querySelector("[data-role='card-modal']")
      if (!layer || layer.hidden) return
      layer.hidden = true
      card.querySelector(".split-card")?.classList.remove("card-modal-open")
      // The pill appears only once the words have actually been dismissed —
      // "read again" over a modal nobody has read yet is an offer to do
      // something they are already doing.
      if (seen) {
        this._modalSeen.add(this._modalKey(card))
        this._persistModalSeen()
        card.querySelector("[data-role='card-modal-reopen']")?.removeAttribute("hidden")
      }
    })
  }

  dismissCardModal() {
    this._closeCardModal({ seen: true })
    // The nav was hidden by the attribute, not by a class _update() owns, so
    // re-running it is what puts Back/Next back with the right labels for this
    // card — and it re-reads the answered state, which a modal shown over an
    // already-answered card (stepping back) would otherwise leave stale.
    this._update()
  }

  reopenCardModal(event) {
    const card = event.currentTarget.closest("[data-player-target='card']")
    if (card) this._openCardModal(card)
  }

  // Keyed by cid, not by index: a cid names one card for the life of the deck,
  // and under answer-branching the same card can be reached by more than one
  // path. Falls back to the answer index for a card with no cid (a pre-cid
  // deck), which is still stable within a run.
  _modalKey(card) {
    return card.dataset.cardCid || `i${card.dataset.cardIndex}`
  }

  // Across a reload, not across a visit. A refresh mid-run keeps the same
  // response row (see _ensureToken, the same storage and the same key shape),
  // so re-interrupting on every card already read would punish a dropped
  // connection; a fresh visit is a fresh run and meets them again.
  _loadModalSeen() {
    try {
      return new Set(JSON.parse(sessionStorage.getItem(this._modalSeenKey()) || "[]"))
    } catch (_) {
      return new Set()
    }
  }

  _persistModalSeen() {
    try {
      sessionStorage.setItem(this._modalSeenKey(), JSON.stringify([ ...this._modalSeen ]))
    } catch (_) { /* private mode — the run still works, it just re-shows on reload */ }
  }

  _modalSeenKey() { return `verto_modals_${this.submitUrlValue}` }

  // ── Quiz: per-card grading, reveal, lock, running score ──────────────────

  async _initQuiz() {
    this._quizMax = this.cardTargets.filter(c => c.dataset.cardGraded === "true").length
    this._renderScoreChip()

    // Refresh-proof no-redo: re-lock and re-reveal cards this session already
    // committed, server-side (owner preview has no endpoint and starts fresh).
    if (!this.quizStateUrlValue) return
    try {
      const url = `${this.quizStateUrlValue}?session_token=${encodeURIComponent(this._sessionToken)}`
      const res  = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data || !data.ok || !data.quiz) return
      if (typeof data.max === "number") this._quizMax = data.max
      Object.entries(data.answered || {}).forEach(([key, info]) => {
        const card = this.cardTargets.find(c => c.dataset.cardIndex === key)
        if (!card) return
        this._answers[key] = { type: card.dataset.cardType, value: info.value }
        this._applyValue(card, card.dataset.cardType, info.value)
        this._revealCard(card, { correct: info.correct, correctAnswer: info.correct_answer,
                                 explanation: info.explanation, mine: info.value })
        this._revealed.add(this.cardTargets.indexOf(card))
      })
      if (typeof data.score === "number") this._quizScore = data.score
      this._renderScoreChip()
      this._update()
    } catch (_) { /* a fresh start is fine if state can't load */ }
  }

  // A card that still needs its quiz reveal before the player can move on.
  _needsReveal(idx) {
    const card = this.cardTargets[idx]
    return this.quizValue && card?.dataset.cardGraded === "true" && !this._revealed.has(idx)
  }

  async _gradeCurrent() {
    const idx  = this.currentValue
    const card = this.cardTargets[idx]
    const key  = card.dataset.cardIndex
    this._revealed.add(idx) // lock now so a double-tap can't re-submit
    // Clear any note from a previous failed attempt, so a retry that works
    // doesn't leave the old error sitting under the answer.
    card.querySelector(".quiz-grade-error")?.remove()
    card.classList.add("quiz-locking")
    this._setGradingBusy(true)

    const result = this.gradeUrlValue
      ? await this._gradeRemote(key)         // live: server is authoritative
      : this._gradeLocal(card)               // owner preview: embedded answers
    card.classList.remove("quiz-locking")
    this._setGradingBusy(false)
    if (result?.failed) {
      // Say so and let them try again, rather than leaving a button that
      // silently does nothing.
      this._revealed.delete(idx)
      this._showGradeError(card, result)
      return
    }
    if (!result) { this._revealed.delete(idx); return } // nothing to grade here

    if (typeof result.score === "number") this._quizScore = result.score
    else if (result.correct) this._quizScore++
    if (typeof result.max === "number") this._quizMax = result.max

    this._revealCard(card, result)
    this._renderScoreChip()
    this._update()
    this._buzz(result.correct ? [12, 24, 12] : 30)
  }

  // Disables Next/Submit and swaps its label while the server checks the
  // answer — a free-text quiz answer can take a couple of seconds now that a
  // close-but-not-exact wording gets an AI judgment call (see
  // QuizAnswerGrader), not just an instant exact-match. Guards against a
  // confused double-tap mid-request.
  _setGradingBusy(busy) {
    const label = busy ? t("player.quiz_grading") : t("player.quiz_check")
    ;[ this.hasNextBtnTarget && this.nextBtnTarget, this.hasFinishBtnTarget && this.finishBtnTarget ]
      .filter(Boolean)
      .forEach(btn => { btn.textContent = label; btn.dataset.disabled = busy ? "true" : "false" })
  }

  // A short, dismissible line on the card itself. Removed on the next attempt so
  // it can't pile up.
  _showGradeError(card, result) {
    const host = card.querySelector(".split-right") || card
    host.querySelector(".quiz-grade-error")?.remove()

    const key = result.gone ? "player.quiz_gone"
              : result.offline ? "player.quiz_offline"
              : "player.quiz_grade_failed"
    const note = document.createElement("div")
    note.className = "quiz-grade-error"
    note.setAttribute("role", "alert")
    note.textContent = t(key)
    host.appendChild(note)
  }

  async _gradeRemote(key) {
    try {
      const res = await fetch(this.gradeUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...this._payload(), card_index: Number(key) })
      })
      // A refusal is not the same as "this card isn't graded". Distinguishing
      // them is the whole point: on a bare null the caller silently returned,
      // so tapping "Check answer" did nothing at all — no error, no hint, no
      // retry prompt — and the respondent was stuck on the card with a dead
      // button and no answers saved.
      if (!res.ok) {
        // No retests: this identity already finished the wave. Land on the
        // refused screen and report a failure so the card never advances.
        if (await this._alreadyPlayed(res)) { this._refuseRetake(); return { failed: true } }
        return { failed: true, gone: res.status === 410 }
      }
      const data = await res.json()
      if (!data.ok) return { failed: true }
      if (!data.graded) return null // genuinely nothing to grade — carry on
      return { correct: data.correct, correctAnswer: data.correct_answer,
               explanation: data.explanation, score: data.score, max: data.max,
               mine: this._answers[key]?.value }
    } catch (_) {
      return { failed: true, offline: !navigator.onLine }
    }
  }

  _gradeLocal(card) {
    let correct
    try { correct = JSON.parse(card.dataset.cardCorrect || "null") } catch (_) { correct = null }
    if (correct === null || correct === undefined || correct === "" ||
        (Array.isArray(correct) && correct.length === 0)) return null
    const value = this._answers[card.dataset.cardIndex]?.value
    return { correct: this._matchCorrect(card.dataset.cardType, value, correct, card),
             correctAnswer: correct, explanation: card.dataset.cardExplanation || "", mine: value }
  }

  // Client mirror of QuizGrading#correct? — used ONLY for owner preview, where
  // the correct answers are embedded on the page. Live grading is server-side.
  _matchCorrect(type, value, correct, card = null) {
    const norm  = v => String(v ?? "").trim()
    const normT = v => norm(v).toLowerCase().replace(/\s+/g, " ")
    switch (type) {
      case "multiple_choice": case "yes_no": case "select_one_grid": case "scenario":
        return norm(value) === norm(correct)
      case "select_many": case "select_many_grid": {
        const a = new Set((Array.isArray(value) ? value : []).map(norm).filter(Boolean))
        const b = new Set((Array.isArray(correct) ? correct : []).map(norm).filter(Boolean))
        return a.size === b.size && [ ...a ].every(x => b.has(x))
      }
      case "tap_card": {
        if (typeof value !== "object" || !value || typeof correct !== "object" || !correct) return false
        // Any key on this card's scale is a markable answer — mirrors
        // QuizGrading#tap_correct?, which used to hardcode yes/no here too and
        // so graded a five-point card as if it defined no correct answer.
        const scale = new Set(this._responseKeys(card))
        const keys = Object.keys(correct).filter(k => scale.has(correct[k]))
        return keys.length > 0 && keys.every(k => value[k] === correct[k])
      }
      case "range": case "nps": case "rating":
        if (value === null || value === undefined || value === "") return false
        return Number(value) === Number(correct)
      case "open_ended": {
        if (!norm(value)) return false
        return (Array.isArray(correct) ? correct : [ correct ]).map(normT).filter(Boolean).includes(normT(value))
      }
      default: return false
    }
  }

  _revealCard(card, { correct, correctAnswer, explanation, mine }) {
    card.classList.add("quiz-locked", correct ? "quiz-correct" : "quiz-wrong")
    this._lockInputs(card)
    this._tintOptions(card, correctAnswer, mine)

    const host = card.querySelector(".split-right") || card
    let banner = host.querySelector(".quiz-reveal")
    if (!banner) {
      banner = document.createElement("div")
      banner.className = "quiz-reveal"
      host.appendChild(banner)
    }
    banner.classList.toggle("is-correct", !!correct)
    banner.classList.toggle("is-wrong", !correct)
    const parts = [
      `<div class="quiz-reveal-head">${correct ? "✓" : "✗"} ${this._esc(correct ? t("player.quiz_correct") : t("player.quiz_wrong"))}</div>`
    ]
    if (!correct) {
      parts.push(`<div class="quiz-reveal-answer">${this._esc(t("player.quiz_answer"))} ${this._esc(this._formatCorrect(card.dataset.cardType, correctAnswer))}</div>`)
    }
    if (explanation) parts.push(`<div class="quiz-reveal-expl">${this._esc(explanation)}</div>`)
    banner.innerHTML = parts.join("")
  }

  // Tint the correct option(s) green and the player's wrong pick(s) red — for
  // the list/grid/yes-no types whose options carry a canonical label.
  _tintOptions(card, correctAnswer, mine) {
    const items = Array.from(card.querySelectorAll('[data-picker-target="item"]'))
    if (!items.length) return
    const toSet = v => new Set((Array.isArray(v) ? v : [ v ]).map(x => String(x ?? "").trim()).filter(Boolean))
    const right = toSet(correctAnswer), picked = toSet(mine)
    items.forEach(el => {
      const canon = (el.dataset.canonical || "").trim()
      if (right.has(canon)) el.classList.add("opt-correct")
      else if (picked.has(canon)) el.classList.add("opt-wrong")
    })
  }

  // Restore the player's recorded selection when rehydrating a locked card on
  // reload (choice/grid/open/rating); other widgets rely on the reveal banner.
  _applyValue(card, type, value) {
    if (value === null || value === undefined) return
    if ([ "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid", "scenario" ].includes(type)) {
      const set = new Set((Array.isArray(value) ? value : [ value ]).map(v => String(v ?? "").trim()))
      card.querySelectorAll('[data-picker-target="item"]').forEach(el => {
        if (!set.has((el.dataset.canonical || "").trim())) return
        el.dataset.selected = "true"
        // picker#setSelected is bypassed here (we're writing the dataset
        // directly), so its aria half has to be done by hand or a restored
        // card reads as entirely unchecked to a screen reader.
        if (el.hasAttribute("role")) el.setAttribute("aria-checked", "true")
      })
      // A capped multi-select restored at its ceiling must come back DIMMED —
      // the picker computes that from the selections, and nothing has told it
      // they changed.
      card.querySelectorAll('[data-controller~="picker"]').forEach(ul => {
        this.application.getControllerForElementAndIdentifier(ul, "picker")?.syncCap()
      })
    } else if (type === "open_ended") {
      const loc = card.querySelector(".location-search-value")
      if (loc) {
        loc.value = value
        const sep = String(value).indexOf("|")
        const label = sep >= 0 ? String(value).slice(sep + 1) : ""
        if (label) {
          const selected = card.querySelector(".location-search-selected")
          const selectedText = card.querySelector('[data-location-search-target="selectedText"]')
          const input = card.querySelector('[data-location-search-target="input"]')
          if (selected) selected.hidden = false
          if (selectedText) selectedText.textContent = label
          if (input) input.hidden = true
        }
        return
      }
      const month = card.querySelector(".freeform-month")
      if (month) {
        const m = /^(\d{4})-(\d{2})$/.exec(String(value))
        if (m) {
          month.value = m[2]
          const year = card.querySelector(".freeform-year"); if (year) year.value = m[1]
        }
        return
      }
      const el = card.querySelector("textarea, input[type='date']"); if (el) el.value = value
    } else if (type === "rating") {
      card.querySelectorAll(".rating-star").forEach((s, i) => {
        const on = i < Number(value); s.classList.toggle("active", on); s.textContent = on ? "★" : "☆"
      })
    }
  }

  _lockInputs(card) {
    card.querySelectorAll(".choice-list, .choice-grid, .rotate-wrap, .slider-wrap, .nps-slider, .prioritise-list, .rating-wrap, .freeform-wrap, .other-block")
        .forEach(el => { el.style.pointerEvents = "none" })
    card.querySelectorAll("textarea, input, button[data-other-target='btn']").forEach(el => { el.disabled = true })
  }

  _formatCorrect(type, c) {
    if (Array.isArray(c)) return c.join(", ")
    if (c && typeof c === "object") return Object.entries(c).map(([ k, v ]) => `${k}: ${v}`).join(", ")
    if (type === "rating") return `${c} ★`
    return String(c ?? "")
  }

  _renderScoreChip() {
    if (!this.hasScoreChipTarget || !this.quizValue || this._quizMax <= 0) return
    this.scoreChipTarget.classList.remove("hidden")
    this.scoreChipTarget.textContent = t("player.quiz_score", { score: this._quizScore, max: this._quizMax })
    this._fitFooter() // a chip in the bar is exactly what leaves the labels no room
  }

  _labelQuizNav() {
    const pending = this._needsReveal(this.currentValue)
    if (this.hasNextBtnTarget)   this.nextBtnTarget.textContent   = pending ? t("player.quiz_check") : this._nextLabel
    if (this.hasFinishBtnTarget) this.finishBtnTarget.textContent = pending ? t("player.quiz_check") : this._finishLabel
    this._fitFooter() // "Check answer" is a good deal longer than "Next →"
  }

  _renderQuizScore() {
    if (!this.hasQuizScoreTarget || this._quizMax <= 0) return
    const pct = Math.round((this._quizScore / this._quizMax) * 100)
    this.quizScoreTarget.classList.remove("hidden")
    this.quizScoreTarget.innerHTML =
      `<div class="quiz-result-label">${this._esc(t("player.quiz_result_label"))}</div>` +
      `<div class="quiz-result-score">${this._quizScore}<span class="quiz-result-max">/${this._quizMax}</span></div>` +
      `<div class="quiz-result-pct">${pct}%</div>`
  }

  // ── Quiz: how you compare (anonymous score distribution) ─────────────────

  async _loadScores() {
    if (!this.scoresUrlValue) return
    if (this._scoresData) return this._renderScores(this._scoresData)
    this.scoresMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.scoresUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed")
      this._scoresData = data
      this._renderScores(data)
    } catch (_) {
      this.scoresMetaTarget.textContent = t("player.compare_error")
    }
  }

  _renderScores(data) {
    // Same suppression as the answer comparison: a per-question correct-rate
    // over one or two people is their answer sheet.
    if (data.suppressed) {
      this.scoresMetaTarget.textContent = t("player.compare_too_few")
      this.scoresListTarget.innerHTML = ""
      return
    }
    const total = data.total || 0
    const mine  = this._quizScore
    const below = (data.distribution || []).filter(d => d.score < mine).reduce((s, d) => s + d.count, 0)
    const beat  = total > 0 ? Math.round((below / total) * 100) : 0
    this.scoresMetaTarget.textContent = total > 0
      ? t("player.quiz_compare_meta", { score: mine, max: data.max, beat, avg: data.average })
      : t("player.quiz_compare_empty")

    const list = this.scoresListTarget
    list.innerHTML = ""
    ;(data.distribution || []).forEach(d => {
      const pct = total > 0 ? Math.round((d.count / total) * 100) : 0
      list.appendChild(this._buildBar(t("player.quiz_score_bucket", { score: d.score, max: data.max }),
                                      d.count, pct, d.score === mine))
    })
    if ((data.per_question || []).length) {
      const head = document.createElement("div")
      head.className = "play-compare-head"
      head.textContent = t("player.quiz_per_question")
      list.appendChild(head)
      data.per_question.forEach(q => list.appendChild(this._buildBar(q.prompt || `#${q.index + 1}`, q.correct, q.pct, false)))
    }
  }

  // ── Tokenisation: running total, checkpoint card, final tally ────────────
  // A card's token config is public (it's rendered straight into the page,
  // unlike a quiz's hidden `correct` answer), so the running total is
  // computed entirely client-side — no grade-style round trip needed. The
  // server independently recomputes the authoritative total at
  // progress/submit time (PlayerController#apply_token_totals), and finish()
  // trusts that over this running tally, same as it does for quiz score.

  _initTokens() {
    this.tokenTypesValue.forEach(tt => { this._tokenTotals[tt.id] = 0 })
    this._renderTokenChip()
  }

  // Apply the token award for card `idx` to the running total, once. Called
  // right as the player advances past a card (Next/Finish) — going back to a
  // card already applied here can't re-earn, since _lockInputs makes its
  // widgets unresponsive and this method itself is idempotent per index.
  //
  // An UNANSWERED card is deliberately left alone when backNav is on. The
  // server has always taken this view — locked_merge keys off whether an answer
  // was actually stored, so it accepts a late answer to a card that was skipped
  // — but this method used to lock on the way past regardless, making the
  // client stricter than the server and quietly costing a respondent the points
  // for a question they meant to come back to.
  _applyTokenEarn(idx) {
    if (!this.tokenisationValue) return
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardAwardsTokens !== "true" || this._tokenLocked.has(idx)) return

    const key = card.dataset.cardIndex
    // The whole answer decides whether it counts; the value alone decides what
    // it earns (an "Other" write-in scores nothing — it matches no option).
    if (this.tokenBackNavValue && !this._isAnswerGiven(this._answers[key])) return

    this._tokenLocked.add(idx)
    const earned = this._computeEarned(card, card.dataset.cardType, this._answers[key]?.value)
    Object.entries(earned).forEach(([id, amount]) => {
      this._tokenTotals[id] = (this._tokenTotals[id] || 0) + amount
    })

    this._lockInputs(card)
    this._renderTokenChip()
    if (this.tokenRevealValue) this._revealTokenEarn(card, earned)
  }

  // Play the arriving card's entry animation. Only on an actual card CHANGE —
  // _update() runs for plenty of reasons that aren't navigation (a token
  // checkpoint repainting, quiz nav relabelling), and replaying the animation on
  // those would make the deck twitch while standing still.
  //
  // The class is transient: added here, removed when the animation ends. Left
  // on, it would re-fire whenever card-shake was removed from the same card,
  // replaying the entry on a failed required-field tap.
  // Card-entry effects. Named for the animation, but it also owns moving focus
  // (P2-4) because this is where the "did the card actually change" test lives
  // and duplicating that in _update would be worse. Note the ordering: focus
  // moves before the motion guards below, since a respondent on reduced motion
  // or in forms mode still needs the focus to follow the deck.
  _animateCardEntry(card, idx) {
    const first    = this._enteredIdx === undefined
    const changed  = this._enteredIdx !== idx
    const prevIdx  = this._enteredIdx
    this._enteredIdx = idx
    if (changed && !first) this._focusCard(card)
    if (!card || !changed) return
    if (this.formsValue) return           // form mode strips game-like motion
    if (this._reducedMotion) return

    card.classList.remove("is-entering", "is-entering-back", "is-entering--from-book")
    void card.offsetWidth                 // reflow, so a re-entry restarts it
    // Leaving a scenario's answer page turns its book at 0.52s; the deck's
    // ordinary 0.26s entry for the NEXT card then read as an abrupt cut right
    // after that more leisurely turn. Only the forward step off a scenario
    // gets the slower pacing — an ordinary Next stays snappy.
    const fromBook = !this._navBack && !first &&
      this.cardTargets[prevIdx]?.dataset.cardType === "scenario"
    const cls = this._navBack ? "is-entering-back" : fromBook ? "is-entering--from-book" : "is-entering"
    card.classList.add(cls)
    card.addEventListener("animationend", () => card.classList.remove(cls), { once: true })
  }

  // Move focus onto the card that just appeared (P2-4). Without this the deck
  // is only half usable by keyboard: every control on a card can now be
  // operated, but advancing leaves focus on an element that just went hidden,
  // so the browser drops it to <body> and the respondent has to Tab from the
  // top of the document on every single question.
  //
  // Focusing the card container also makes a screen reader announce the new
  // question, which is the other half of what a sighted respondent gets for
  // free from the card simply changing.
  //
  // Deliberately skipped on the FIRST render: stealing focus on page load is
  // disorienting, moves it away from anything the browser restored, and
  // nothing has happened yet that a respondent needs told about.
  _focusCard(card) {
    if (!card) return
    // tabindex -1: programmatically focusable, but never inserted into the tab
    // order, so Tab still walks the card's own controls rather than the wrapper.
    if (!card.hasAttribute("tabindex")) card.setAttribute("tabindex", "-1")
    // preventScroll: the deck positions cards itself, and letting the browser
    // scroll to the focus target fights that.
    try { card.focus({ preventScroll: true }) } catch (_) { card.focus() }
  }

  get _reducedMotion() {
    return window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches === true
  }

  // Mirrors TokenGrading.blank_value? — what the server treats as "not
  // answered", and so what back-navigation is allowed to return to.
  // The mirror of PlayerController#answered? (app/controllers/player_controller.rb).
  // Takes the whole stored answer, not just its `value`: an "Other"-only answer
  // has a null value and a real `other`, and reading only the value made the
  // client leave such a card unlocked and unscored while the server locked it —
  // so the respondent's correction was silently discarded and their points went
  // with it.
  //
  // test/system/answer_parity_test.rb drives the same table of cases through
  // both implementations and asserts they agree.
  _isAnswerGiven(ans) {
    if (!ans || typeof ans !== "object") return false
    if (String(ans.other ?? "").trim() !== "") return true
    const v = ans.value
    if (Array.isArray(v)) return v.length > 0
    if (v !== null && typeof v === "object") return Object.keys(v).length > 0
    if (typeof v === "string") return v.trim() !== ""
    return v !== null && v !== undefined
  }

  // Show what THIS answer earned, not just the running total. The amount was
  // already being computed and thrown away into the total; this surfaces it,
  // reusing the quiz reveal's markup and animation so the two feel like one
  // idea rather than two.
  _revealTokenEarn(card, earned) {
    const host = card.querySelector(".split-right") || card
    host.querySelectorAll(".token-reveal").forEach(el => el.remove())

    // Losses show too: a negative award (tokens as lives, a wrong turn costing
    // a heart) used to be dropped here while still lowering the total, so the
    // respondent saw the number fall with no explanation. Zero stays silent.
    const types = this.tokenTypesValue
    const rows  = Object.entries(earned)
      .filter(([ , amount ]) => Number(amount) !== 0)
      .map(([ id, amount ]) => {
        const meta = types.find(t => String(t.id) === String(id))
        const sign = Number(amount) > 0 ? "+" : ""
        return `${meta?.icon || "★"} ${meta?.name || ""} ${sign}${this._fmtTokens(amount)}`.trim()
      })
    const net = Object.values(earned).reduce((sum, v) => sum + (Number(v) || 0), 0)

    const box = document.createElement("div")
    box.className = `token-reveal ${rows.length ? (net < 0 ? "is-lost" : "is-earned") : "is-none"}`
    const head = document.createElement("div")
    head.className = "token-reveal-head"
    head.textContent = rows.length ? t("player.tokens_earned") : t("player.tokens_earned_none")
    box.appendChild(head)
    if (rows.length) {
      const detail = document.createElement("div")
      detail.className = "token-reveal-rows"
      detail.textContent = rows.join(" · ")
      box.appendChild(detail)
    }
    host.appendChild(box)
  }

  // Client mirror of TokenGrading.earned — the token amounts a stored answer
  // value earns, as {token_id => amount}. `card.dataset.cardTokens` /
  // `cardTokenAward` carry this card's public config (see player/show.html.erb).
  _computeEarned(card, type, value) {
    const CHOICE_ONE  = [ "multiple_choice", "yes_no", "select_one_grid", "scenario" ]
    const CHOICE_MANY = [ "select_many", "select_many_grid" ]
    const FLAT        = [ "range", "nps", "rating", "open_ended", "prioritise" ]
    const sumHashes = (hashes) => {
      const out = {}
      hashes.forEach(h => { if (h) Object.entries(h).forEach(([k, v]) => { out[k] = (out[k] || 0) + Number(v || 0) }) })
      return out
    }
    const blank = (v) => v === null || v === undefined || v === "" || (Array.isArray(v) && v.length === 0)

    // Choice-shaped cards can opt into a flat award for completing the
    // question at all (mirrors TokenGrading.completion_award?), rather than
    // per chosen option — behaves exactly like the FLAT branch below.
    const completionAward = (CHOICE_ONE.includes(type) || CHOICE_MANY.includes(type)) &&
      card.dataset.cardTokenAwardMode === "completion"
    if (FLAT.includes(type) || completionAward) {
      if (blank(value)) return {}
      return this._parseJSON(card.dataset.cardTokenAward, {})
    }

    if (CHOICE_ONE.includes(type)) {
      const tokens = this._parseJSON(card.dataset.cardTokens, {})
      return tokens[String(value ?? "").trim()] || {}
    }
    if (CHOICE_MANY.includes(type)) {
      const tokens = this._parseJSON(card.dataset.cardTokens, {})
      return sumHashes((Array.isArray(value) ? value : []).map(v => tokens[String(v).trim()]))
    }
    if (type === "tap_card") {
      const tokens = this._parseJSON(card.dataset.cardTokens, {})
      if (typeof value !== "object" || !value) return {}
      return sumHashes(Object.entries(value).map(([statement, dir]) => tokens[statement]?.[dir]))
    }
    return {}
  }

  // A tap card's answer keys, read off the response strip the respondent just
  // used. The DOM is where the player learns a card's scale — the server renders
  // the strip and the keys ride on it, so there is nothing extra to ship.
  _responseKeys(card) {
    const keys = Array.from(card?.querySelectorAll("[data-tap-response]") || [])
      .map(el => el.dataset.responseKey).filter(Boolean)
    return keys.length ? keys : presetFor(DEFAULT_TAP_COUNT).map(r => r.key)
  }

  _parseJSON(str, fallback) {
    try {
      const parsed = JSON.parse(str || "null")
      return parsed === null || parsed === undefined ? fallback : parsed
    } catch (_) {
      return fallback
    }
  }

  // Every token number the player shows goes through here: thousands
  // separators in the respondent's own language ("500,000", "500.000"), a
  // plain hyphen-minus for a negative total (what toLocaleString emits, and
  // what the server-rendered option badges use — number_with_delimiter).
  _fmtTokens(n) {
    const v = Number(n) || 0
    try {
      return v.toLocaleString(this.localeValue || undefined)
    } catch (_) {
      return v.toLocaleString()
    }
  }

  _renderTokenChip() {
    if (!this.hasTokenScoreChipTarget || !this.tokenTypesValue.length) return
    this.tokenScoreChipTarget.classList.remove("hidden")
    this.tokenScoreChipTarget.innerHTML = this.tokenTypesValue.map(tt =>
      `<span class="token-score-pill">${this._esc(tt.icon)} ${this._fmtTokens(this._tokenTotals[tt.id] || 0)}</span>`
    ).join("")
    this._fitFooter() // points chips share the bar with the labels
  }

  // Points Checkpoint: when the active card is a checkpoint, fill in its
  // (otherwise-empty) body with the running totals — this is the only card
  // type whose content is entirely client-rendered.
  _maybeRenderCheckpoint(idx) {
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardType !== "token_checkpoint") return
    const body = card.querySelector(".token-checkpoint-body")
    if (!body || !this.tokenTypesValue.length) return

    const totals = this.tokenTypesValue.map(tt => this._tokenTotals[tt.id] || 0)
    // Scaled against whoever is ahead, because there is no ceiling to scale
    // against: awards are unbounded running sums and can go negative (tokens
    // as lives). Magnitude sets the length, the sign sets the colour — the
    // question a checkpoint answers is which of these is winning, and a bar
    // drawn against an invented maximum would answer a different one.
    const peak = Math.max(...totals.map(Math.abs))

    // _update() lands here on EVERY navigation, backwards included. Rebuilding
    // unconditionally re-ran the fill transition each time, so stepping back
    // over a checkpoint made the bars twitch rather than arrive.
    const sig = totals.join("|")
    if (body.dataset.totals === sig) return
    body.dataset.totals = sig

    body.innerHTML = this.tokenTypesValue.map((tt, i) => {
      const n = totals[i]
      // A 2% floor so that one point against five hundred still reads as a
      // token someone collected rather than an empty track.
      const pct = peak === 0 ? 0 : Math.max(n === 0 ? 0 : 2, Math.round(Math.abs(n) / peak * 100))
      return `
      <div class="token-checkpoint-row">
        <div class="token-checkpoint-head">
          <span class="token-checkpoint-icon">${this._esc(tt.icon)}</span>
          <span class="token-checkpoint-amount">${this._fmtTokens(n)}</span>
          <span class="token-checkpoint-name">${this._esc(tt.name)}</span>
        </div>
        <div class="token-checkpoint-track" aria-hidden="true">
          <div class="token-checkpoint-fill${n < 0 ? " is-loss" : ""}" data-pct="${pct}"></div>
        </div>
      </div>`
    }).join("")

    // Width last, so the transition has a zero to start from. The bar is
    // decorative — the number it echoes is already read out beside it — so
    // nothing here needs announcing.
    requestAnimationFrame(() => {
      body.querySelectorAll(".token-checkpoint-fill").forEach(f => { f.style.width = `${f.dataset.pct}%` })
    })
  }

  _renderTokenScore() {
    if (!this.hasTokenScoreTarget || !this.tokenTypesValue.length) return
    this.tokenScoreTarget.classList.remove("hidden")
    // The creator's own sentence, above the label, where the mid-deck
    // checkpoint puts its card copy. Four totals and no words is what got
    // reported; a house default would be worse than nothing, because only the
    // creator knows what their tokens are counting — so an unset note renders
    // no pill at all rather than a sentence about points in general.
    const note = this.tokensResultNoteValue.trim()
    this.tokenScoreTarget.innerHTML =
      (note ? `<div class="token-result-note">${this._esc(note)}</div>` : "") +
      `<div class="token-result-label">${this._esc(t("player.tokens_result_label"))}</div>` +
      this.tokenTypesValue.map(tt => `
        <div class="token-result-row">
          <span class="token-result-icon">${this._esc(tt.icon)}</span>
          <span class="token-result-amount">${this._fmtTokens(this._tokenTotals[tt.id] || 0)}</span>
          <span class="token-result-name">${this._esc(tt.name)}</span>
        </div>`).join("")
  }

  // The end-of-play leaderboard. Three degraded states before the happy path:
  // no live URL (preview/test) renders nothing; a rejected submit renders
  // nothing (nothing was stored — a board would imply otherwise); a queued
  // submit renders the title and a promise instead of fetching, because the
  // row may land hours from now when the service worker drains the queue.
  async _renderLeaderboard(queued = false, rejected = false) {
    if (!this.hasLeaderboardTarget || !this.leaderboardUrlValue || rejected) return
    const el = this.leaderboardTarget
    const title = `<div class="leaderboard-title">🏆 ${this._esc(t("player.leaderboard_title"))}</div>`
    el.classList.remove("hidden")
    if (queued) {
      el.innerHTML = title + `<div class="leaderboard-note">${this._esc(t("player.leaderboard_queued"))}</div>`
      return
    }
    try {
      // POST, not GET: the durable device key is the thing being sent, and a
      // key in a URL is written to the service worker's page cache along with
      // everything else the catch-all networkFirst handles. Same reasoning as
      // recall and eligibility — see config/routes.rb.
      const res = await fetch(this.leaderboardUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          session_token: this._sessionToken || null,
          player_key: this._playerKey || null
        })
      })
      if (!res.ok) throw new Error(`status ${res.status}`)
      const data = await res.json()
      const entries = data.entries || []
      const youListed = entries.some(e => e.you)
      const rankBy = data.rank_by
      let rows = entries.map(e => this._leaderboardRow(e.rank, e.name, e.total, e.you, e.totals, rankBy)).join("")
      // Your row is always ON the board, "You" badge beside the anonymous
      // name. From below the visible top it rides in after a gap marker, so a
      // mid-table player sees their placement as a row, not just a sentence
      // about it.
      if (data.you && !youListed) {
        rows += `<div class="leaderboard-gap" aria-hidden="true">⋯</div>` +
                this._leaderboardRow(data.you.rank, data.you.name, data.you.total, true, data.you.totals, rankBy)
      }
      let self = ""
      if (data.you) {
        self += `<div class="leaderboard-self">${this._esc(t("player.leaderboard_played_as", { name: data.you.name }))}</div>`
        if (!youListed) {
          self += `<div class="leaderboard-self">${this._esc(t("player.leaderboard_rank", { rank: data.you.rank, of: data.you.of }))}</div>`
        }
      }
      const empty = rows ? "" : `<div class="leaderboard-note">${this._esc(t("player.leaderboard_empty"))}</div>`
      el.innerHTML = title + rows + empty + self
    } catch (_) {
      el.innerHTML = title + `<div class="leaderboard-note">${this._esc(t("player.compare_error"))}</div>`
    }
  }

  // One board row. The "You" badge sits directly beside the anonymous name so
  // a player can find themselves without reading the footnote lines. `total`
  // is what the board ranks by — the sum of everything, or one token type
  // (rankBy), whose icon then prefixes the figure so the column reads as
  // "⚫ 3" rather than an unexplained 3. With two or more types, `totals`
  // becomes a small breakdown line under the name: every type's figure, so a
  // coal board still shows the gold. Its own span, never inside
  // .leaderboard-name, which the You-row test reads as the bare name.
  _leaderboardRow(rank, name, total, you, totals = null, rankBy = "all") {
    const badge = you ? `<span class="leaderboard-you-badge">${this._esc(t("player.leaderboard_you"))}</span>` : ""
    const types = this.tokenTypesValue || []
    const basis = rankBy && rankBy !== "all" ? types.find(tt => String(tt.id) === String(rankBy)) : null
    const figure = `${basis ? this._esc(basis.icon) + " " : ""}${this._fmtTokens(total)}`
    const breakdown = (types.length > 1 && totals)
      ? `<span class="leaderboard-breakdown">${types.map(tt => `${this._esc(tt.icon)} ${this._fmtTokens(totals[tt.id] || 0)}`).join(" · ")}</span>`
      : ""
    return `
      <div class="leaderboard-row${you ? " is-you" : ""}">
        <span class="leaderboard-rank">${Number(rank) || 0}</span>
        <span class="leaderboard-who">
          <span class="leaderboard-name">${this._esc(name)}${badge}</span>${breakdown}
        </span>
        <span class="leaderboard-total">${figure}</span>
      </div>`
  }

  // The No retests landing for an identity that already finished this wave:
  // the thank-you screen — with the live board where there is one — and an
  // explanatory pill, no replay. This session holds no tallies, so the
  // quiz/token result cards stay hidden and nothing is submitted. The pill
  // never names the wave or the identity.
  _showAlreadyPlayed() {
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    this.progressTarget.textContent = ""
    if (this.hasThankyouMainTarget && !this.thankyouMainTarget.querySelector(".preview-queued-pill")) {
      const pill = document.createElement("div")
      pill.className = "preview-queued-pill"
      pill.textContent = t(this.leaderboardUrlValue ? "player.already_played" : "player.already_played_plain")
      this.thankyouMainTarget.appendChild(pill)
    }
    this._renderLeaderboard()
  }

  // ── The end-screen account ask ────────────────────────────────────────────

  // How many other Vertos this browser's keys will be offered for. A bound,
  // not a policy: the server caps the payload at the same number, and a
  // browser holding hundreds of these is a browser something has gone wrong on.
  static JOIN_MAX_DEVICE_KEYS = 20

  // Reveal the card, and work out what this device can offer alongside the run
  // just finished. Two states it deliberately does NOT reveal in: no live URL
  // (preview, Test Mode, or the creator has the block off), and a REJECTED
  // submit — nothing was stored, so there is nothing to keep and an account
  // offer would say otherwise.
  _renderJoinState(rejected = false) {
    if (!this.hasJoinBlockTarget || !this.joinUrlValue || rejected) return
    this.joinBlockTarget.classList.remove("hidden")

    const others = this._joinDeviceKeys().filter(d => d.token !== this._playToken())
    if (this._embedded()) {
      if (this.hasJoinEmbeddedTarget) this.joinEmbeddedTarget.classList.remove("hidden")
    } else if (others.length && this.hasJoinAlsoTarget) {
      this.joinAlsoLabelTarget.textContent =
        t(others.length === 1 ? "player.join_also_one" : "player.join_also_other", { count: others.length })
      this.joinAlsoTarget.classList.remove("hidden")
    }
  }

  // The card opens collapsed: its pitch and one button. This is that button.
  //
  // The form it reveals is 560px of the end screen on a phone, and until it
  // was folded away the whole screen needed 1127px of an 844px viewport. Now
  // the form is a cost paid only by somebody who has just said they want the
  // account. Focus goes to the first thing they can act on — Google when it
  // is offered, else the address — and deliberately NOT to a text field on
  // its own when Google is there: focusing an input raises the keyboard,
  // which on a phone hides half of the form that just appeared.
  joinExpand(event) {
    event?.preventDefault()
    if (!this.hasJoinFormTarget) return
    this.joinFormTarget.hidden = false
    if (this.hasJoinRevealTarget) this.joinRevealTarget.hidden = true
    event?.currentTarget?.setAttribute("aria-expanded", "true")
    const first = this.hasJoinGoogleBtnTarget ? this.joinGoogleBtnTarget
                : this.hasJoinEmailTarget     ? this.joinEmailTarget : null
    first?.focus()
  }

  // Clear a stale error the moment they start fixing it — an error that
  // outlives the thing it described reads as a second failure.
  joinTyped() {
    if (this.hasJoinErrorTarget) this.joinErrorTarget.classList.add("hidden")
  }

  async joinSubmit(event) {
    event?.preventDefault()
    if (!this.joinUrlValue || this._joinSending) return

    const email = (this.hasJoinEmailTarget ? this.joinEmailTarget.value : "").trim()
    // A deliberately loose client-side check: the server is the authority, and
    // a strict regex here rejects addresses that are perfectly deliverable.
    // Its only job is to catch the obvious typo before the round trip.
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      this._joinError(t("player.join_invalid"))
      return
    }

    const password = this.hasJoinPasswordTarget ? this.joinPasswordTarget.value : ""
    if (password.length < JOIN_MIN_PASSWORD) {
      this._joinError(t("player.join_password_short", { count: JOIN_MIN_PASSWORD }))
      return
    }

    const wanted = this.hasJoinAlsoBoxTarget && this.joinAlsoBoxTarget.checked
    this._joinSending = true
    if (this.hasJoinBtnTarget) this.joinBtnTarget.disabled = true

    try {
      const res = await fetch(this.joinUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email,
          password,
          session_token: this._sessionToken || null,
          lang: this.localeValue || null,
          device_keys: wanted ? this._joinDeviceKeys() : []
        })
      })
      const data = await res.json().catch(() => null)

      // The endpoint hands back a single-use sign-in link rather than setting a
      // cookie: this POST runs under null_session (the player page is cached by
      // the service worker, so its CSRF token can be arbitrarily stale) and a
      // cookie written under a failed check is silently dropped. Following the
      // link finishes the sign-in on a page that is not cached.
      if (res.ok && data?.ok && data?.next) {
        this._joinDone(data.next)
        return
      }
      this._joinError(t(JOIN_ERRORS[data?.error] || "player.join_failed",
                        { count: JOIN_MIN_PASSWORD }))
    } catch (_e) {
      this._joinError(t("player.join_failed"))
    } finally {
      this._joinSending = false
      if (this.hasJoinBtnTarget) this.joinBtnTarget.disabled = false
    }
  }

  // Continue with Google.
  //
  // This does NOT go to Google. It cannot from here: OmniAuth's request phase
  // is a CSRF-protected POST and this page is service-worker cached, so its
  // authenticity token can be any age — the same reason joinSubmit's endpoint
  // runs under null_session. What it does is hand the run's claims to a
  // cookie-free endpoint, which parks them and answers with a /you/ URL that
  // is outside the worker's scope and therefore always fresh. That page starts
  // the round trip properly.
  //
  // Deliberately the same shape as joinSubmit, down to sharing _joinDone: from
  // here on the two paths are one path, and a second way of navigating would
  // be a second thing to keep in step.
  async joinGoogle(event) {
    event?.preventDefault()
    if (!this.joinGoogleUrlValue || this._joinSending) return

    const wanted = this.hasJoinAlsoBoxTarget && this.joinAlsoBoxTarget.checked
    this._joinSending = true
    if (this.hasJoinGoogleBtnTarget) this.joinGoogleBtnTarget.disabled = true

    try {
      const res = await fetch(this.joinGoogleUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          session_token: this._sessionToken || null,
          lang: this.localeValue || null,
          device_keys: wanted ? this._joinDeviceKeys() : []
        })
      })
      const data = await res.json().catch(() => null)

      if (res.ok && data?.ok && data?.next) {
        // Says Google, because that is where the next tap goes — the account
        // page is two screens away and naming it here would be a promise this
        // navigation does not keep.
        this._joinDone(data.next, "player.join_google_done_title")
        return
      }
      this._joinError(t(JOIN_ERRORS[data?.error] || "player.join_failed",
                        { count: JOIN_MIN_PASSWORD }))
    } catch (_e) {
      this._joinError(t("player.join_failed"))
    } finally {
      this._joinSending = false
      if (this.hasJoinGoogleBtnTarget) this.joinGoogleBtnTarget.disabled = false
    }
  }

  // The account exists and a single-use link to finish signing in is in hand.
  //
  // Navigating rather than rendering a "done" card: the link has to be spent on
  // the sign-in page to establish the session (see joinSubmit), and parking the
  // respondent on a success message they then have to act on is how you lose
  // them. The card is still swapped first so a slow navigation does not leave
  // the form sitting there looking unpressed.
  _joinDone(next, titleKey = "player.join_done_title") {
    if (this.hasJoinAskTarget) this.joinAskTarget.classList.add("hidden")
    if (this.hasJoinDoneTarget) {
      this.joinDoneTarget.classList.remove("hidden")
      this.joinDoneTarget.innerHTML =
        `<div class="join-sent-title">${this._esc(t(titleKey))}</div>`
    }
    window.location.assign(next)
  }

  _joinError(message) {
    if (!this.hasJoinErrorTarget) return
    this.joinErrorTarget.textContent = message
    this.joinErrorTarget.classList.remove("hidden")
  }

  // Every Verto this browser still holds a durable leaderboard key for, as
  // {token, player_key} pairs. The keys are stored per submit URL
  // (_ensurePlayerKey), so the play token comes back out of the key's own name
  // — there is no separate index to drift out of step with them.
  //
  // Nothing here is trusted by the server: a key only ever resolves against
  // the HMAC of the survey it belongs to, so a pair that has been tampered
  // with matches nothing rather than matching someone else.
  _joinDeviceKeys() {
    const out = []
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const name = localStorage.key(i)
        if (!name || !name.startsWith("verto_player_")) continue
        const token = name.slice("verto_player_".length).match(/\/play\/([^/]+)\/submit\/?$/)?.[1]
        const key = token && localStorage.getItem(name)
        if (key) out.push({ token, player_key: key })
      }
    } catch (_e) { /* storage blocked — the run just finished is still claimable */ }
    return out.slice(0, this.constructor.JOIN_MAX_DEVICE_KEYS)
  }

  // This Verto's play token, read off the submit URL for the same reason.
  _playToken() {
    return this.submitUrlValue.match(/\/play\/([^/]+)\/submit\/?$/)?.[1] || ""
  }

  // Framed by a third party. localStorage is partitioned or refused outright
  // there, so device keys from other Vertos simply are not visible — the block
  // says so rather than quietly offering less.
  _embedded() {
    try {
      return window.self !== window.top
    } catch (_e) {
      return true
    }
  }

  _esc(s) {
    return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }
}
