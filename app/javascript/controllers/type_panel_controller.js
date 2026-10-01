import { Controller } from "@hotwired/stimulus"
import { ROUTABLE_TYPES } from "lib/routable_types"
import { PAGED_TYPES, isPaged } from "lib/paged_types"
import { NON_QUESTION_TYPES } from "lib/question_types"
import { DEFAULT_OPTIONS, defaultOptionsFor } from "lib/default_options"
import { choiceListItemHtml, prioritiseItemHtml, choiceGridItemHtml, yesNoItemHtml, addOptionBtnHtml } from "lib/choice_templates"
import { tapResponseStripHtml, tapGlyphSvg } from "lib/tap_response_templates"
import { resolveResponses, fans } from "lib/tap_scales"
import { injectIcons } from "lib/option_icons"
import { optionMediaStyle } from "lib/option_media"
import { t } from "lib/i18n"
import { cardEyebrow, MULTI_SELECT_TYPES } from "lib/card_eyebrow"
import { NPS_VESSELS, npsStageStyle, npsVesselSvg, npsVesselFor,
         npsCustomScale, NPS_MIN_STEPS } from "lib/nps_vessels"



// Single-pick types whose answers can each route to a different card/end —
// (Routable types come from lib/routable_types — the LogicGraph::ROUTABLE mirror.)

// Read the canonical card-type metadata that the editor view emits as a
// JSON blob (sourced from config/card_types.yml). Called from connect()
// so each Turbo navigation re-reads the blob — otherwise the cache from
// the first page visited (e.g. dashboard, which has no blob) sticks.
function loadTypeMeta() {
  let raw = {}
  try {
    raw = JSON.parse(document.getElementById("card-types")?.textContent || "{}")
  } catch (_) {
    raw = {}
  }
  return Object.fromEntries(
    Object.entries(raw).map(([key, t]) => [key, {
      badge:   t.badge,
      css:     t.badge_css,
      label:   t.panel_label,
      eyebrow: t.eyebrow,
    }])
  )
}

// Per-locale "how to answer" captions — see application_helper.rb
// #card_eyebrows_i18n. Only used to caption a card just switched to a new
// type (_applyToCard); translation tabs lock the type picker (CSS
// .editing-translation .type-list), so this only ever needs the primary
// locale's caption, not whichever tab happens to be active.
function loadEyebrows() {
  try {
    return JSON.parse(document.getElementById("card-eyebrows-i18n")?.textContent || "{}")
  } catch (_) {
    return {}
  }
}

// Read the Awareness/Intention/Agency + enabling-condition metadata the editor
// view emits as a JSON blob (sourced from config/competencies.yml via
// Framework.to_json). Used to label the "Why" tab badges. Same re-read-on-
// connect rationale as loadTypeMeta.
function loadFramework() {
  try {
    return JSON.parse(document.getElementById("framework")?.textContent || "{}")
  } catch (_) {
    return {}
  }
}

// Each entry's `note` is shown as the natural-language reason this type
// works (or doesn't) for the selected card. The `score` only drives the
// fit-tier badge ("Best fit" / "Strong alternative" / etc.).
//
// The notes below are the ENGLISH FALLBACK — the displayed copy comes from
// `js.editor.compat.<from>.<to>` in the locale files (all 19 mirror this
// table), looked up via compatNote(). A note edited here must be edited
// there too, or every locale silently keeps the old wording.
const COMPATIBILITY = {
  multiple_choice: [
    { type: "select_one_grid",  score: 100, note: "The Playverto default for a single-pick — visual grid feels playful, drives engagement, and lets you anchor each option with imagery or colour." },
    { type: "multiple_choice",  score: 75,  note: "Image list, single pick — small tile left of each option. Fall back to this when labels are long or there are too many options to grid neatly." },
    { type: "select_many_grid", score: 70,  note: "Same visual grid, but lets people pick more than one — switch to this when the answer isn't a single choice." },
    { type: "select_many",      score: 60,  note: "Image list, multi-pick — same tile-left layout, broader answer set; use when the grid can't fit." },
    { type: "yes_no",           score: 55,  note: "Collapses nuance to two answers — only do this if you genuinely want a hard yes/no signal." },
    { type: "prioritise",       score: 65,  note: "Same options, but respondents drag them into an order of priority — richer data (the ORDER of preference), not just which they picked." },
    { type: "range",            score: 40,  note: "Loses the categorical clarity of a list — only swap if the answer is really on a scale." },
  ],
  select_many: [
    { type: "select_many_grid", score: 100, note: "The Playverto default for multi-pick — visual grid with imagery or colour swatches gets richer answers than a flat list." },
    { type: "select_many",      score: 75,  note: "Image list, multi-pick — small tile left of each option. Fall back to this when labels are long or there are too many options to grid neatly." },
    { type: "select_one_grid",  score: 70,  note: "Same visual grid but constrained to a single pick — switch when one decisive answer matters more than breadth." },
    { type: "multiple_choice",  score: 60,  note: "Image list, single pick — same tile-left layout, sharpest read but most reductive option here." },
    { type: "prioritise",       score: 65,  note: "Same options, but respondents drag them into an order of priority — richer data (the ORDER of preference), not just which they picked." },
  ],
  prioritise: [
    { type: "prioritise",       score: 100, note: "Drag-to-rank list — respondents order the options highest to lowest, so you learn the order of preference. Best with about five options." },
    { type: "select_many",      score: 65,  note: "Same list without the ordering — switch if you only need which options they'd pick, not the order." },
    { type: "select_one_grid",  score: 45,  note: "Collapses the ranking to a single visual pick — only if one decisive answer matters more than the order." },
  ],
  select_one_grid: [
    { type: "select_one_grid",  score: 100, note: "Visual single-pick — best when imagery or colour does the talking and you want a fast, gut response." },
    { type: "select_many_grid", score: 80,  note: "Same imagery, multi-pick — better when more than one option might resonate." },
    { type: "multiple_choice",  score: 55,  note: "Image list, single pick — small tile left of each option. Switch when options are long or there are too many to fit a grid." },
    { type: "prioritise",       score: 65,  note: "Same options, but respondents drag them into an order of priority — richer data (the ORDER of preference), not just which they picked." },
    { type: "select_many",      score: 40,  note: "Image list, multi-pick — same tile-left layout, loses the single-pick clarity." },
  ],
  select_many_grid: [
    { type: "select_many_grid", score: 100, note: "Visual multi-pick — best when respondents may identify with several image-led options at once." },
    { type: "select_one_grid",  score: 80,  note: "Same visual feel but constrained to one — pick this if you need a single decisive choice." },
    { type: "select_many",      score: 55,  note: "Image list, multi-pick — small tile left of each option. Fall back when labels are long or there are too many to grid." },
    { type: "prioritise",       score: 65,  note: "Same options, but respondents drag them into an order of priority — richer data (the ORDER of preference), not just which they picked." },
    { type: "multiple_choice",  score: 40,  note: "Image list, single pick — same tile-left layout, sharpest read but most reductive option here." },
  ],
  tap_card: [
    { type: "tap_card",         score: 100, note: "Quick, gamified gut reactions — perfect for testing several short statements without survey fatigue." },
    { type: "range",            score: 60,  note: "Replaces speed with nuance — use if you'd rather see how strongly people agree than how fast." },
    { type: "rating",           score: 55,  note: "Stars give a familiar scale, but you lose the rapid-fire feel of tapping." },
    { type: "select_one_grid",  score: 40,  note: "Removes the playful tap mechanic — only swap if the question really is a single static choice." },
  ],
  scenario: [
    { type: "scenario",         score: 100, note: "A short story respondents turn through page by page, then a 2–3 option choice on the last page — best for longer, situational prompts that would overwhelm a single card." },
    { type: "multiple_choice",  score: 45,  note: "Drops the narrative build-up for a plain single-pick list — switch if the story context isn't adding anything." },
    { type: "yes_no",           score: 35,  note: "Strips it to a bare binary — only if the story genuinely reduces to a yes/no." },
  ],
  range: [
    { type: "range",            score: 100, note: "Best at capturing strength of feeling, and the reactive animated character makes answering feel rewarding — a clean distribution plus an engaging visual." },
    { type: "nps",              score: 90,  note: "Classic 0–10 scale on a compact vertical slider — switch for a quieter, traditional feel without the animation." },
    { type: "rating",           score: 85,  note: "Similar shape, but stars are more familiar and a touch less expressive." },
    { type: "tap_card",         score: 50,  note: "Trades the scale for a yes/no per statement — more engaging, less granular." },
    { type: "yes_no",           score: 30,  note: "Strips the scale to two answers — most data goes with it. Only use if the binary is the insight." },
  ],
  rating: [
    { type: "rating",           score: 100, note: "Star scale is instantly understood and gives a comparable score across questions." },
    { type: "nps",              score: 80,  note: "Classic 0–10 feel on a compact vertical slider — picks up where stars feel generic." },
    { type: "range",            score: 88,  note: "More expressive scale with custom endpoints and a reactive animated character — better when the spectrum isn't generic 'good/bad'." },
    { type: "tap_card",         score: 50,  note: "Loses the scale, but more engaging if you want a quick gut take across several items." },
    { type: "select_one_grid",  score: 35,  note: "Flattens the scale into discrete labelled tiles — loses the smoothness people respond to in stars." },
  ],
  nps: [
    { type: "nps",              score: 100, note: "Compact 0–10 vertical scale — clean and familiar for opinion / satisfaction questions." },
    { type: "range",            score: 88,  note: "Same 5-point opinion scale with a reactive animated character — switch when an engaging visual lifts response quality." },
    { type: "rating",           score: 80,  note: "Star scale is the familiar baseline — switch if a horizontal star rating fits the audience better." },
    { type: "tap_card",         score: 45,  note: "Replace the scale with a quick gut yes/no across several statements — only if you have multiple to test." },
    { type: "yes_no",           score: 30,  note: "Collapses the scale to two answers — most signal goes with it. Only use if the binary is the insight." },
  ],
  yes_no: [
    { type: "yes_no",           score: 100, note: "Crisp signal when you genuinely need a binary — easy to read and easy to answer." },
    { type: "select_one_grid",  score: 75,  note: "Adds nuance with a few defined visual options — better when 'yes/no' is hiding the real answer." },
    { type: "range",            score: 55,  note: "Adds a 5-point scale with a reactive animated character — better when degree matters and you want an engaging visual." },
    { type: "nps",              score: 45,  note: "Adds a compact 0–10 vertical scale — better when degree matters more than the binary." },
    { type: "tap_card",         score: 35,  note: "Run a quick yes/no across several statements at once — only swap if you have multiple to test." },
  ],
  open_ended: [
    { type: "open_ended",       score: 100, note: "Lets people answer in their own words — richest qualitative signal, but harder to aggregate." },
    { type: "select_one_grid",  score: 45,  note: "Trades raw quotes for fast, comparable visual categories — pick this if you already know the likely answers." },
    { type: "range",            score: 30,  note: "Only works if the answer collapses to a single scale — usually loses the point of going open-ended." },
  ],
  welcome_card: [
    { type: "welcome_card",     score: 100, note: "Sets the tone before any questions — ideal first card for cold audiences who need context." },
  ],
}


// Default narrative pages for a card freshly switched to Scenario — one
// blank page (the .book-page-text placeholder invites the creator to write).
const DEFAULT_PAGES = {
  scenario: [ { id: "", text: "" } ],
  consent_gate: [ { id: "", text: "" } ],
}

// Default NPS label count (0–10). Server-side too (NpsHelper::NPS_STEPS).
// The actual step count follows the label count, so a 4/5-point or agree
// scale works too. Keep in sync.
const NPS_STEPS = 11

function esc(s) {
  return String(s ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;")
                       .replace(/>/g,"&gt;").replace(/"/g,"&quot;")
}

// The localised compatibility note for switching `fromType` → `entry.type`.
// t() returns the key itself when a translation is missing, so an untranslated
// pair falls back to the English note baked into COMPATIBILITY.
function compatNote(fromType, entry) {
  const key = `editor.compat.${fromType}.${entry.type}`
  const v = t(key)
  return v === key ? entry.note : v
}

// Bucket a 0–100 compatibility score into a short, plain-English fit tier.
function fitTier(score) {
  if (score >= 100) return t("editor.fit_best")
  if (score >= 80)  return t("editor.fit_strong")
  if (score >= 60)  return t("editor.fit_solid")
  if (score >= 40)  return t("editor.fit_workable")
  return t("editor.fit_sparingly")
}

// HTML builders for the right-side interactive component on each card
const COMPONENTS = {
  multiple_choice: (opts, ctx = {}) => choiceListHtml(opts, "single", ctx.optionStyles),
  select_many:     (opts, ctx = {}) => choiceListHtml(opts, "multi", ctx.optionStyles, ctx.maxChoices),
  prioritise:      (opts, ctx = {}) => prioritiseHtml(opts, ctx.optionStyles),

  yes_no: (opts, ctx = {}) => {
    const labels = (opts || []).length >= 2 ? opts : defaultOptionsFor("yes_no")
    const styles = ctx.optionStyles || []
    return `
    <ul class="choice-list choice-list--yesno" data-controller="picker" data-picker-mode-value="single">
      ${[[labels[0], 1, "Yes"], [labels[1], 4, "No"]].map(([label, bg, canonical], i) => yesNoItemHtml(label, bg, styles[i], { canonical, quiz: ctx.quiz })).join("")}
    </ul>`
  },

  select_one_grid:  (opts, ctx = {}) => gridHtml(opts, "single", ctx.optionStyles),
  select_many_grid: (opts, ctx = {}) => gridHtml(opts, "multi", ctx.optionStyles, ctx.maxChoices),

  // Mirrors the "when tap_card" branch in _card_component.html.erb. It had
  // drifted badly — a bare <span> where the partial has a media layer and a
  // statement band, no controls wrapper, no remaining-cards dots, and a
  // two-button ✕/✓ strip that predated the third response — so a card rebuilt
  // by a type switch looked nothing like the same card after a reload. The
  // response strip now comes from lib/tap_response_templates, which is the one
  // place its markup is written on this side of the wire.
  //
  // Always built editable (a type switch only happens in the editor), so it
  // carries the creator's statement pager rather than the respondent's reset
  // row — without it a card switched to Tap would show only its first
  // statement, with no way to reach the rest.
  tap_card: (opts, ctx = {}) => {
    const optionImages = ctx.optionImages || []
    const optionFocals = ctx.optionFocals || []
    const responses = resolveResponses(ctx.responses)
    return `
    <div class="rotate-wrap" data-controller="tap-stack card-editor"
         data-action="tap-stack:reset->tap-stack#reset tap-stack:goto->tap-stack#goto">
      <div class="rotate-card-stack">
        ${opts.map((o,i) => {
          const img = optionImages[i]
          // Mirrors ApplicationHelper#option_media_style — the picture as
          // longhands plus this statement's stored reposition.
          const bg = optionMediaStyle(img, optionFocals[i], i)
          return `<div class="rotate-card" data-tap-stack-target="card" data-canonical="${esc(o)}">
                    <div class="rotate-card-media" style="${bg}"></div>
                    <div class="rotate-card-statement"><span contenteditable="true">${esc(o)}</span></div>
                    <button type="button" class="tap-card-image-btn" data-action="click->media-picker#openTapOption" data-media-picker-option-index="${i}" title="${esc(t("editor.change_statement_image_title"))}">
                      <span aria-hidden="true"><svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><path d="M21 15l-5-5L5 21"></path></svg></span>
                    </button>
                    <button type="button" class="tap-card-adjust-btn" data-action="click->media-picker#openAdjust" data-media-picker-option-index="${i}" title="${esc(t("editor.reposition_statement_title"))}" aria-label="${esc(t("editor.reposition_statement_title"))}"${img ? "" : " hidden"}>
                      <span aria-hidden="true"><svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v18M3 12h18"></path><path d="M9 6l3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3"></path></svg></span>
                    </button>
                    <button type="button" class="tap-card-delete" data-action="click->card-editor#deleteOption" title="${esc(t("card.remove_option"))}" aria-label="${esc(t("card.remove_option"))}">×</button>
                  </div>`
        }).join("")}
        <div class="rotate-complete">
          <span class="rotate-complete-check">${tapGlyphSvg("yes")}</span>
          <span class="rotate-complete-text">${esc(t("card.tap_done"))}</span>
        </div>
        <div class="rotate-card-controls${fans(responses.length) ? " rotate-card-controls--fan" : ""}" data-tap-stack-target="controls">
          ${tapResponseStripHtml(responses)}
          <div class="rotate-dots" data-tap-stack-target="dots"></div>
        </div>
      </div>
      <div class="tap-nav-row">
        <button type="button" class="tap-nav-btn" data-tap-stack-target="prevBtn" data-action="click->tap-stack#back"
                title="${esc(t("editor.tap.prev_statement"))}" aria-label="${esc(t("editor.tap.prev_statement"))}">‹</button>
        <span class="tap-nav-count" data-tap-stack-target="counter" aria-live="polite"></span>
        <button type="button" class="tap-nav-btn" data-tap-stack-target="nextBtn" data-action="click->tap-stack#forward"
                title="${esc(t("editor.tap.next_statement"))}" aria-label="${esc(t("editor.tap.next_statement"))}">›</button>
      </div>
      <button type="button" class="tap-add-btn" data-action="click->card-editor#addTapOption">＋ ${esc(t("card.add_statement"))}</button>
    </div>`
  },

  // Mirrors the "when scenario" branch in _card_component.html.erb — a book
  // stack of narrative pages (ctx.pages) plus the reused single-select
  // .choice-list as the final page. Always built editable (client-side type
  // switching only happens in the editor); scenario_controller.js drives the
  // page-turn nav once this HTML lands in the DOM.
  scenario: (opts, ctx = {}) => {
    const pages = (ctx.pages && ctx.pages.length) ? ctx.pages : [ { id: "", text: "" } ]
    const pagesHtml = pages.map((p, i) => `
      <div class="book-page" data-scenario-target="page" data-page-id="${esc(p.id || "")}">
        <div class="book-page-scroll">
          <div class="book-page-kicker" data-scenario-target="kicker">${esc(t("editor.scenario.page_of", { n: i + 1, total: pages.length }))}</div>
          <div class="book-page-text" contenteditable="true" data-rich-text data-scenario-target="pageText"
               data-placeholder="${esc(t("editor.scenario.page_placeholder"))}">${esc(p.text || "")}</div>
        </div>
        <div class="book-page-corner">${i + 1}</div>
        <div class="book-page-fade"></div>
      </div>`).join("")
    const answerHtml = `
      <div class="book-page is-answer" data-scenario-target="page">
        <div class="book-page-scroll">
          <div class="book-page-kicker">${esc(t("editor.scenario.answer_kicker"))}</div>
          <ul class="choice-list choice-list--single" data-controller="picker card-editor" data-picker-mode-value="single">
            ${opts.map((o, i) => choiceListItemHtml(o, i, "single", (ctx.optionStyles || [])[i])).join("")}${addOptionBtnHtml()}
          </ul>
        </div>
        <div class="book-page-fade"></div>
      </div>`
    return `
      <div class="book-wrap book-wrap--scenario" data-controller="scenario card-editor" data-scenario-editable-value="true">
        <div class="book-stack" data-scenario-target="stack">${pagesHtml}${answerHtml}</div>
        <div class="book-edit-tools" data-scenario-target="editTools">
          <button type="button" class="book-tool-btn danger" data-scenario-target="delPageBtn" data-action="click->scenario#deletePage">${esc(t("editor.scenario.delete_page"))}</button>
          <button type="button" class="book-tool-btn" data-scenario-target="addPageBtn" data-action="click->scenario#addPage">${esc(t("editor.scenario.add_page"))}</button>
        </div>
        <div class="book-dots" data-scenario-target="dots"></div>
        <div class="book-nav-row">
          <button type="button" class="book-chevron" data-scenario-target="prevBtn" data-action="click->scenario#back" aria-label="${esc(t("editor.scenario.prev_page"))}">‹</button>
          <button type="button" class="next-btn" data-scenario-target="nextBtn" data-action="click->scenario#next">${esc(t("editor.scenario.next_page_btn"))}</button>
        </div>
        <div class="book-live" data-scenario-target="live" aria-live="polite"></div>
      </div>`
  },

  // Mirrors the "when consent_gate" branch in _card_component.html.erb — the
  // same book as a scenario, WITHOUT the --scenario modifier the branch above
  // carries: that class is what centres a page's text, and a story reads
  // better centred while an information sheet reads worse. The last page is
  // Agree / Decline instead of a choice list, and in the editor it is an inert replica (aria-hidden, no
  // actions, not tabbable) so a creator can see where the sheet lands without
  // consenting on a respondent's behalf.
  //
  // Its absence was not a design choice: COMPONENTS[type] falls back to
  // `() => ""`, so picking "Consent screens" in the Answer Type panel blanked
  // the card. welcome_card is listed explicitly as `() => ""` precisely so an
  // intentional blank is distinguishable from a missing entry.
  consent_gate: (_opts, ctx = {}) => {
    const pages = (ctx.pages && ctx.pages.length) ? ctx.pages : [ { id: "", text: "" } ]
    const pagesHtml = pages.map((p, i) => `
      <div class="book-page" data-scenario-target="page" data-page-id="${esc(p.id || "")}">
        <div class="book-page-scroll">
          <div class="book-page-kicker" data-scenario-target="kicker">${esc(t("editor.scenario.page_of", { n: i + 1, total: pages.length }))}</div>
          <div class="book-page-text" contenteditable="true" data-scenario-target="pageText"
               data-placeholder="${esc(t("editor.consent_page_placeholder"))}">${esc(p.text || "")}</div>
        </div>
        <div class="book-page-corner">${i + 1}</div>
        <div class="book-page-fade"></div>
      </div>`).join("")
    return `
      <div class="book-wrap" data-controller="scenario" data-scenario-editable-value="true">
        <div class="book-stack" data-scenario-target="stack">${pagesHtml}
          <div class="book-page is-answer" data-scenario-target="page">
            <div class="book-page-scroll">
              <div class="book-page-kicker">${esc(t("editor.consent_agreement_kicker"))}</div>
              <div class="play-consent-main">
                <div class="play-consent-actions" aria-hidden="true" style="pointer-events:none;">
                  <button type="button" class="play-consent-agree" tabindex="-1">${esc(t("player.consent_agree"))}</button>
                  <button type="button" class="play-consent-decline" tabindex="-1">${esc(t("player.consent_decline"))}</button>
                </div>
              </div>
            </div>
            <div class="book-page-fade"></div>
          </div>
        </div>
        <div class="book-edit-tools" data-scenario-target="editTools">
          <button type="button" class="book-tool-btn danger" data-scenario-target="delPageBtn" data-action="click->scenario#deletePage">${esc(t("editor.scenario.delete_page"))}</button>
          <button type="button" class="book-tool-btn" data-scenario-target="addPageBtn" data-action="click->scenario#addPage">${esc(t("editor.scenario.add_page"))}</button>
        </div>
        <div class="book-dots" data-scenario-target="dots"></div>
        <div class="book-nav-row">
          <button type="button" class="book-chevron" data-scenario-target="prevBtn" data-action="click->scenario#back" aria-label="${esc(t("editor.scenario.prev_page"))}">‹</button>
          <button type="button" class="next-btn" data-scenario-target="nextBtn" data-action="click->scenario#next">${esc(t("editor.scenario.next_page_btn"))}</button>
        </div>
        <div class="book-live" data-scenario-target="live" aria-live="polite"></div>
      </div>`
  },

  // Mirrors the "when respondent_code" branch in _card_component.html.erb.
  // Inert, for the same reason consent_gate's replica is: a creator switching a
  // card to this type should be able to see where the prompt lands without
  // typing a respondent's code on their behalf.
  //
  // Listed explicitly even though it is short, because COMPONENTS[type] falls
  // back to `() => ""` — picking a type with no entry silently BLANKS the card,
  // which is exactly what happened to consent_gate (BUG-015).
  respondent_code: () => `
      <div aria-hidden="true" style="pointer-events:none;">
        <input type="text" class="respondent-code-input" tabindex="-1" readonly
               placeholder="${esc(t("player.respondent_code_placeholder"))}" />
        <div class="respondent-code-note">${esc(t("player.respondent_code_note"))}</div>
        <div class="play-consent-actions">
          <button type="button" class="play-consent-agree" tabindex="-1">${esc(t("player.respondent_code_continue"))}</button>
        </div>
      </div>`,

  range: (opts, ctx = {}) => sliderHtml(opts, ctx),

  nps: (opts, ctx = {}) => npsHtml(opts, ctx),

  rating: (opts, ctx = {}) => {
    // The card's own emoji beats the themed icon, as it does in the server
    // render (ApplicationHelper#rating_icon) — a switch away and back must not
    // lose the creator's pick.
    const icon = ctx.ratingEmoji
      ? { on: ctx.ratingEmoji, off: ctx.ratingEmoji, kind: "emoji" }
      : (ctx.ratingIcon || { on: "★", off: "☆", kind: "star" })
    const fallback = defaultOptionsFor("rating")
    const labels = opts.length >= 2 ? opts : fallback
    // One star and one caption per label — mirrors the `when "rating"` branch of
    // _card_component.html.erb. Emitting only the two ends here would hand the
    // serializer a two-option card and quietly drop the middle captions, which
    // is the bug this pair of renderers had.
    // Always five — see Survey::RATING_STARS. Only a full ladder has a caption
    // per star; a two-label card is min/max on a five-star scale.
    const stars = 5
    const mids  = labels.length >= stars
      ? labels.map((lbl, i) => ({ lbl, i })).filter(({ i }) => i > 0 && i < stars - 1)
      : []
    // The 🎨 slot mirrors the `editable` branch of _card_component.html.erb:
    // the shared picker writes into the hidden input beside the button and the
    // editor's setRatingEmoji repaints off that input's `input` event.
    return `
      <div class="rating-wrap rating-kind-${icon.kind}" data-controller="rating">
        <span class="rating-style-slot">
          <button type="button" class="option-style-btn rating-style-btn"
                  data-emoji-picker-trigger
                  data-action="click->emoji-picker#open"
                  title="${esc(t("card.rating_icon"))}"
                  aria-label="${esc(t("card.rating_icon"))}">🎨</button>
          <input type="text" class="rating-emoji-input" tabindex="-1" aria-hidden="true"
                 value="${esc(ctx.ratingEmoji || "")}"
                 data-action="input->survey-editor#setRatingEmoji" />
        </span>
        <div class="rating-stars">
          ${[...Array(stars)].map((_, i) => `
            <span class="rating-star"
                  data-rating-target="star"
                  data-rating-index="${i}"
                  data-rating-on="${esc(icon.on)}"
                  data-rating-off="${esc(icon.off)}"
                  data-action="click->rating#pick mouseover->rating#hover mouseout->rating#unhover">${esc(icon.off)}</span>
          `).join("")}
        </div>
        <div class="rating-labels">
          <span class="rating-label" data-rating-target="endLabel" contenteditable="true">${esc(labels[0] || fallback[0])}</span>
          <span class="rating-mid-labels" data-rating-target="midLabels">
            ${mids.map(({ lbl, i }) => `
              <span class="rating-label rating-label-mid"
                    data-rating-target="midLabel"
                    data-rating-index="${i}" contenteditable="true">${esc(lbl)}</span>
            `).join("")}
          </span>
          <span class="rating-label" data-rating-target="endLabel" contenteditable="true">${esc(labels[labels.length - 1] || fallback[fallback.length - 1])}</span>
        </div>
      </div>`
  },

  // Carries the card's own char_limit and the Answer-length select, both of
  // which this rebuild used to drop: a card switched to Open Text lost its
  // stored limit back to 200 and lost the control for changing it until the
  // page was reloaded.
  open_ended: (_opts, ctx = {}) => {
    const max = Number(ctx.charLimit) || 200
    const presets = (ctx.charLimitPresets || [ 80, 140, 200, 500, 1000 ]).slice()
    if (!presets.includes(max)) presets.push(max)
    return `
    <div class="freeform-wrap" data-controller="freeform" data-freeform-max-value="${max}">
      <textarea class="freeform-textarea" placeholder="${esc(t("card.answer_placeholder"))}"
                maxlength="${max}"
                data-freeform-target="input"
                data-action="input->freeform#update"></textarea>
      <div class="freeform-counter" data-freeform-target="counter">0/${max} ${esc(t("card.characters"))}</div>
      <label class="freeform-limit-row">
        <span>${esc(t("card.char_limit_label"))}</span>
        <select data-char-limit
                data-freeform-target="limit"
                data-action="change->freeform#setLimit change->survey-editor#markDirty">
          ${presets.sort((a, b) => a - b).map(n => `
            <option value="${n}"${n === max ? " selected" : ""}>${esc(t("card.char_limit_option", { n }))}</option>
          `).join("")}
        </select>
      </label>
    </div>`
  },

  welcome_card: () => "",

  // Points Checkpoint. No answer is captured — the player fills the body in
  // client-side from the cards already answered — so the editor shows the same
  // placeholder the server renders for it.
  //
  // Missing entirely until now, which meant picking "Points Checkpoint" in the
  // Answer Type panel emptied the card: it is `pickable: true` whenever
  // tokenisation is on, and COMPONENTS falls back to `() => ""`. Exactly the
  // consent_gate defect (BUG-015), in the one other type that had the same gap.
  token_checkpoint: () => `
    <div class="token-checkpoint-placeholder">${esc(t("card.token_checkpoint_placeholder"))}</div>`,

  // Points Intro — the pills are server-rendered (player/_token_intro), so the
  // editor shows the same placeholder contract as token_checkpoint above.
  points_intro: () => `
    <div class="token-checkpoint-placeholder">${esc(t("card.points_intro_placeholder"))}</div>`,
}

function prioritiseHtml(opts, styles = []) {
  return `
    <ul class="choice-list prioritise-list" data-controller="prioritise card-editor">
      ${opts.map((o, i) => prioritiseItemHtml(o, i, styles[i])).join("")}${addOptionBtnHtml()}
    </ul>`
}

function choiceListHtml(opts, mode, styles = [], max = 0) {
  return `
    <ul class="choice-list choice-list--${mode}" data-controller="picker card-editor"
        data-picker-mode-value="${mode}" data-picker-max-value="${max || 0}">
      ${opts.map((o, i) => choiceListItemHtml(o, i, mode, styles[i])).join("")}${addOptionBtnHtml()}
    </ul>`
}

function gridHtml(opts, mode, styles = [], max = 0) {
  // Always two columns — three shrinks the tiles and labels too far, whatever
  // the option count (keep in step with _card_component's grid branch).
  return `
    <ul class="choice-grid choice-grid--${mode} choice-grid-2" data-controller="picker"
        data-picker-mode-value="${mode}" data-picker-max-value="${max || 0}">
      ${opts.map((o, i) => choiceGridItemHtml(o, i, styles[i])).join("")}
    </ul>`
}

// Mirror of nps_helper.rb's render_nps_control + the `when "nps"` block of
// _card_component.html.erb. The vertical "liquid container": the step count
// follows the labels (≥2); a card with no usable labels falls back to the
// default 0–10. The container silhouette is the card's own pick where it has
// one, and the Verto-themed default otherwise (ctx.npsShape).
function npsHtml(opts, ctx = {}) {
  const labels = opts.length >= NPS_MIN_STEPS ? opts : defaultOptionsFor("nps")
  const n = Math.max(labels.length, NPS_MIN_STEPS)
  // Off the classic 0-10, the stops are the creator's to build and each one
  // gets a × with an ＋ beneath the column; on the classic they are the scale
  // rather than copy, so they are neither removable nor retypable. Same
  // three-state read as the server's (NpsHelper#nps_custom_scale?) — which
  // matters most HERE, because a card switched to NPS carries the previous
  // type's options across: three answers become a three-stop scale, which is
  // not the classic and so arrives unlocked, ready to be extended or snapped
  // back to 0-10 with one switch.
  const custom = npsCustomScale(labels, ctx.npsCustomScale)
  const key = npsVesselFor(ctx.npsShape)
  const v = NPS_VESSELS[key]
  const groups = ctx.npsShapeGroups || []
  const opt = (label, slug) => `<option value="${esc(slug)}"${slug === key ? " selected" : ""}>${esc(label)}</option>`
  // Hidden, like the ERB's — it is the apply path the animation picker drives,
  // not a control in its own right. `hidden` is enough on its own: Tailwind's
  // preflight makes [hidden] display:none !important, so the .nps-shape-picker
  // rule below it can't win the way an ordinary author declaration would.
  const picker = groups.length ? `
    <div class="nps-shape-picker" hidden>
      <label class="range-theme-label">${esc(ctx.npsShapeLabel || t("editor.animation_theme"))}</label>
      <select class="nps-shape-select" data-action="change->survey-editor#setNpsShape">
        ${groups.map(g => `<optgroup label="${esc(g.category)}">${g.shapes.map(s => opt(s.label, s.slug)).join("")}</optgroup>`).join("")}
      </select>
    </div>` : ""
  const del = custom
    ? `<button type="button" class="nps-label-delete" data-action="click->card-editor#deleteNpsStop"
               title="${esc(t("card.remove_option"))}" aria-label="${esc(t("card.remove_option"))}">×</button>`
    : ""
  const add = custom
    ? `<button type="button" class="nps-scale-add" data-action="click->card-editor#addNpsStop"
               data-card-editor-nps-add><span aria-hidden="true">＋</span> ${esc(t("card.add_scale_point"))}</button>`
    : ""
  // The anchor lines beside the scale's ends — the ERB's sibling column, and
  // like the ERB's editor branch always rendered here (this builder is
  // editor-only), so the creator has somewhere to type. ctx.npsAnchors is what
  // the slot held before this rebuild, read by _npsAnchorsFor.
  const anchors = ctx.npsAnchors || {}
  const anchorsHtml = `<div class="nps-anchors">${[ "low", "high" ].map(which =>
    `<span class="nps-anchor-row"><span class="nps-anchor-text nps-anchor-${which}" data-role="nps-anchor-${which}" contenteditable="true" data-placeholder="${esc(t(`card.nps_${which}_placeholder`))}">${esc(anchors[which] || "")}</span></span>`
  ).join("")}</div>`
  return `
    <div class="nps-slider${custom ? " is-custom-scale" : ""}"
         data-controller="nps-slider card-editor"
         data-nps-slider-steps-value="${n}"
         data-nps-slider-axis-value="vertical"
         data-action="pointerdown->nps-slider#start keydown->nps-slider#key"
         tabindex="0" role="slider"
         aria-valuemin="0" aria-valuemax="${n - 1}">
      <div class="nps-slider-stage" style="${npsStageStyle(v)}">
        ${anchorsHtml}
        <div class="slider-labels nps-slider-labels">
          ${labels.map(o => `<span class="nps-label-row">${del}<span class="slider-label-text" data-nps-slider-target="label"${custom ? ' contenteditable="true"' : ""}>${esc(o)}</span></span>`).join("")}
        </div>
        <div class="nps-control nps-shape-${key}" data-axis="vertical">
          ${npsVesselSvg(key, v)}
        </div>
      </div>
      ${add}
    </div>${picker}`
}

// Mirror of shared/_change_animation_cta.html.erb — the left-panel CTA a card
// gains when it is switched TO Range or NPS without a server render. Kept here
// rather than in lib/ because this is its only caller; the ERB partial is still
// the source of truth for what the button looks like.
function changeAnimationFabHtml(action) {
  const title = esc(t("editor.change_animation_title"))
  return `
    <button type="button" class="add-animation-fab"
            data-action="click->animation-picker#${action}"
            title="${title}">
      <span class="add-animation-fab-icon" aria-hidden="true">
        <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="3" y="4" width="18" height="16" rx="3"></rect>
          <path d="M10 9l5 3-5 3z" fill="currentColor" stroke="none"></path>
        </svg>
      </span>
      <span>${esc(t("editor.change_animation"))}</span>
    </button>`
}

// A tunable starting point, not a precisely derived number — mirrors
// NpsHelper#resolved_slider_axis (same thresholds), refine visually via the
// /verify skill rather than by adjusting the math.
const SLIDER_AXIS_LABEL_THRESHOLD = 18
const SLIDER_AXIS_COUNT_THRESHOLD = 5

// A Range card is always a 5-point scale (Survey::RANGE_POINTS). Switching a
// card TO Range carries the previous type's options across, so a 4-tile grid
// or a 3-option list would otherwise render a 4- or 3-point slider — and the
// autosave reads the labels straight back off the DOM, persisting it. Mirrors
// Survey.normalize_range_labels exactly: an already-5 scale keeps every stop
// in place, endpoints stay endpoints, a numeric run keeps counting, and no
// stop is left nameless.
const RANGE_POINTS = 5
const RANGE_UPSAMPLE_SLOTS = { 1: [0], 2: [0, 4], 3: [0, 2, 4], 4: [0, 1, 3, 4] }

function nameBlankStops(labels, filler) {
  return labels.map((l, i) => l || filler[i] || DEFAULT_OPTIONS.range[i])
}

function rangeLabels(opts, filler = defaultOptionsFor("range")) {
  const raw = (opts || []).map(o => String(o == null ? "" : o).trim())
  if (raw.length === RANGE_POINTS) return nameBlankStops(raw, filler)

  const given = raw.filter(Boolean)
  if (!given.length) return filler.slice(0, RANGE_POINTS)
  if (given.length === RANGE_POINTS) return nameBlankStops(given, filler)

  const nums = given.map(l => (/^-?\d+$/.test(l) ? Number(l) : null))
  const consecutive = given.length > 1 && nums.every(n => n !== null) &&
                      nums.every((n, i) => i === 0 || n === nums[i - 1] + 1)
  if (consecutive) {
    return Array.from({ length: RANGE_POINTS }, (_, i) => String(nums[0] + i))
  }

  let spread
  if (given.length > RANGE_POINTS) {
    const last = given.length - 1
    spread = Array.from({ length: RANGE_POINTS },
      (_, i) => given[Math.round(i * last / (RANGE_POINTS - 1))])
  } else {
    spread = new Array(RANGE_POINTS).fill("")
    RANGE_UPSAMPLE_SLOTS[given.length].forEach((slot, i) => { spread[slot] = given[i] })
  }
  return nameBlankStops(spread, filler)
}

function resolvedSliderAxis(storedAxis, labels) {
  if (storedAxis === "horizontal" || storedAxis === "vertical") return storedAxis
  const longest = labels.reduce((max, l) => Math.max(max, String(l).length), 0)
  return (longest > SLIDER_AXIS_LABEL_THRESHOLD || labels.length > SLIDER_AXIS_COUNT_THRESHOLD) ? "vertical" : "horizontal"
}

function sliderHtml(opts, ctx = {}) {
  const labels = rangeLabels(opts)
  const n = labels.length
  const storedAxis = ctx.sliderAxis || "auto"
  const axis = resolvedSliderAxis(storedAxis, labels)
  const dots = Array.from({length: n}, (_, i) => {
    const pos = (i / (n - 1) * 100).toFixed(2)
    return `<div class="s-dot" data-slider-target="dot" style="${axis === "vertical" ? `bottom:${pos}%` : `left:${pos}%`}"></div>`
  }).join("")
  const themes = ctx.rangeThemes || []
  const groups = ctx.rangeThemeGroups || []
  const cur = ctx.rangeTheme || ""
  const bySlug = Object.fromEntries(themes.map(t => [t.slug, t.label]))
  const opt = (s) => `<option value="${esc(s)}"${s === cur ? " selected" : ""}>${esc(bySlug[s] || s)}</option>`
  const optHtml = groups.length
    ? groups.map(g => `<optgroup label="${esc(g.category)}">${g.slugs.map(opt).join("")}</optgroup>`).join("")
    : themes.map(th => opt(th.slug)).join("")
  // `hidden`, matching the ERB. It was missing here, so a card switched TO
  // Range in the editor grew a raw <select> labelled "Animation" on the card
  // itself — the creator's control, drawn on the respondent's card, and cloned
  // straight into Preview from there. The modal is the visual picker; this is
  // only the apply path it drives.
  const picker = themes.length ? `
    <div class="range-theme-picker" hidden>
      <label class="range-theme-label">${esc(ctx.rangeThemeLabel || t("editor.animation_theme"))}</label>
      <select class="range-theme-select" data-action="change->survey-editor#setRangeTheme">
        ${optHtml}
      </select>
    </div>` : ""
  const nextAxis = { auto: "horizontal", horizontal: "vertical", vertical: "auto" }[storedAxis] || "horizontal"
  const axisToggleTitle = esc(t(`editor.slider_axis_${nextAxis}`, { default: "Change layout" }))
  return `
    <div class="slider-wrap" data-controller="slider" data-slider-steps-value="${n}" data-slider-axis-value="${axis}" data-slider-auto-value="${storedAxis === "auto"}">
      <div class="slider-track-wrap">
        <div class="slider-track" data-slider-target="track"
             data-action="pointerdown->slider#start">
          ${dots}
          <div class="slider-thumb" data-slider-target="thumb" style="${axis === "vertical" ? "bottom:50%;" : "left:50%;"}">
            <div class="s-line"></div><div class="s-line"></div><div class="s-line"></div>
          </div>
        </div>
      </div>
      <div class="slider-labels">
        ${labels.map(o => `<span class="slider-label-text" data-slider-target="label" contenteditable="true" data-action="input->slider#refit">${esc(o)}</span>`).join("")}
      </div>
      <button type="button" class="slider-axis-toggle" data-action="click->type-panel#setSliderAxis" title="${axisToggleTitle}">
        <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-3-6.7"></path><path d="M21 3v6h-6"></path></svg>
      </button>
    </div>${picker}`
}

export default class extends Controller {
  static targets = [
    "card", "panelEmpty", "cardEditor", "typeList", "panelFooter",
    "panelCardName", "panelHint", "typeOpt", "toast", "toastMsg", "cardCount",
    "allTypesModal", "allTypesList", "allTypeOpt", "modalCardName",
    "tokenSlot", "quizSlot", "tokensEmpty", "quizEmpty",
    "logicSlot", "branchEmpty", "branchNote", "branchCardName",
    "whyCardName", "whyEmpty", "whyBody", "whyNote", "whyFramework",
    "whyCompetencyRow", "whyCompetencyBadge", "whyCompetencyBlurb",
    "whyOutcomeRow", "whyOutcome",
    "whyConditionRow", "whyConditionBadge", "whyConditionBlurb"
  ]

  static values = { quiz: Boolean, tokenisation: Boolean, logic: Boolean, defaultLocale: { type: String, default: "en" } }

  // Emoji shown next to each recommended type in the side panel — 1st-4th place.
  RANK_EMOJI = ["🥇", "🥈", "🥉", "⭐", "⭐"]
  // Five, not four. Everything outside this list is display:none — not ranked
  // low, GONE — so a type missing from a card's COMPATIBILITY row is
  // unreachable from that card entirely. Prioritise was in two rows out of
  // thirteen, which is why it took "a few different answer types to find it"
  // (18 Aug): the only route was switching to Image List — Many first, where it
  // happened to land in the last visible slot. It is in every option-list row
  // now, and the extra slot means adding it displaced nothing.
  TOP_N      = 5

  activeCardEl = null
  pendingType  = null

  // Quiz/Tokenomics settings for a card live in the .quiz-correct-block /
  // .token-award-block rendered inside it (see _card_component.html.erb) —
  // registerCard() remembers where each card's blocks are by direct element
  // reference (not by position/index, which reordering and deletes would
  // invalidate) so selectCard can relocate the selected card's blocks into
  // the sidebar's Tokenomics/Quiz mode sub-tabs regardless of where they
  // currently sit in the DOM. survey_editor_controller reads/writes them
  // through the same registry so autosave keeps working after relocation.
  connect() {
    this._quizBlocks  = new WeakMap()
    this._tokenBlocks = new WeakMap()
    this._logicBlocks = new WeakMap()
    this.cardTargets.forEach(c => this.registerCard(c))
    // A Turbo snapshot can restore with a card's blocks still relocated into
    // the sidebar slots (or the parking div), where the per-card lookup above
    // cannot see them: the rebuilt WeakMaps come back empty for that card,
    // _tokenScope falls back to the card, reads nothing, and the next autosave
    // writes the card without its token keys. Sweep strays home by the
    // owner-cid stamp registerCard leaves on every block.
    this.element.querySelectorAll(
      ".quiz-correct-block[data-owner-cid], .token-award-block[data-owner-cid], .logic-branch-block[data-owner-cid]"
    ).forEach(block => {
      if (block.closest(".survey-card-wrap")) return
      const card = this.element.querySelector(
        `.survey-card-wrap[data-card-cid="${CSS.escape(block.dataset.ownerCid)}"]`)
      if (!card) return
      card.appendChild(block)
      this.registerCard(card)
    })
  }

  registerCard(card) {
    const cid = card.dataset.cardCid
    const remember = (map, block) => {
      map.set(card, block)
      if (cid) block.dataset.ownerCid = cid
    }
    const quiz = card.querySelector(".quiz-correct-block")
    if (quiz) remember(this._quizBlocks, quiz)
    const tokens = card.querySelector(".token-award-block")
    if (tokens) remember(this._tokenBlocks, tokens)
    const logic = card.querySelector(".logic-branch-block")
    if (logic) remember(this._logicBlocks, logic)
  }

  quizBlockFor(card)  { return this._quizBlocks?.get(card) }
  tokenBlockFor(card) { return this._tokenBlocks?.get(card) }
  logicBlockFor(card) { return this._logicBlocks?.get(card) }

  // The registry rewritten for one card, block by block — null UNBINDS, which
  // registerCard never does (it only ever learns). survey-editor's undo calls
  // this after morphing a card back to a snapshot in which a block may have
  // existed, changed or not existed at all.
  bindBlocks(card, { quiz, token, logic } = {}) {
    const cid  = card.dataset.cardCid
    const bind = (map, block) => {
      if (!block) { map.delete(card); return }
      map.set(card, block)
      if (cid) block.dataset.ownerCid = cid
    }
    bind(this._quizBlocks,  quiz)
    bind(this._tokenBlocks, token)
    bind(this._logicBlocks, logic)
  }

  // registerCard with unbinding: for a card whose markup was rebuilt wholesale
  // (✨ Optimise), so a block the new markup no longer has stops resolving to
  // the detached old one.
  rebindCard(card) {
    this.bindBlocks(card, {
      quiz:  card.querySelector(".quiz-correct-block"),
      token: card.querySelector(".token-award-block"),
      logic: card.querySelector(".logic-branch-block")
    })
  }

  // A hidden holding pen for the previously-active card's relocated blocks —
  // they stay attached to the document (so their inputs/values and Stimulus
  // bindings survive) without being visible anywhere until their card is
  // selected again.
  get _parkingLot() {
    if (!this._parking) {
      this._parking = document.createElement("div")
      this._parking.hidden = true
      this.element.appendChild(this._parking)
    }
    return this._parking
  }

  _parkSlotContents() {
    if (this.hasTokenSlotTarget) this._parkingLot.append(...this.tokenSlotTarget.children)
    if (this.hasQuizSlotTarget)  this._parkingLot.append(...this.quizSlotTarget.children)
    if (this.hasLogicSlotTarget) this._parkingLot.append(...this.logicSlotTarget.children)
  }

  // Lazy getter so the JSON blob is read from the current page's DOM on
  // first use, no matter when the module loaded. This avoids both Turbo
  // cache bleed (module-load IIFE saw the previous page) and any
  // connect() lifecycle race with the script tag.
  get typeMeta() {
    if (!this._typeMeta || Object.keys(this._typeMeta).length === 0) {
      this._typeMeta = loadTypeMeta()
    }
    return this._typeMeta
  }

  get eyebrows() {
    if (!this._eyebrows) this._eyebrows = loadEyebrows()
    return this._eyebrows
  }

  // Awareness/Intention/Agency + condition metadata for the Why tab. Lazy +
  // re-readable for the same cache-bleed reason as typeMeta.
  get framework() {
    if (!this._framework || !this._framework.competencies) {
      this._framework = loadFramework()
    }
    return this._framework
  }

  // Verto-themed rating icon, resolved server-side (one source of truth in
  // ApplicationHelper#rating_icon) and exposed on the editor root. Falls back
  // to the classic star so a card switched to "rating" before the attributes
  // exist still renders.
  _ratingIcon() {
    const d = this.element.dataset
    return {
      on:   d.ratingIconOn   || "★",
      off:  d.ratingIconOff  || "☆",
      kind: d.ratingIconKind || "star"
    }
  }

  // The container an NPS card fills. The card's own pick wins; the fallback is
  // the Verto-themed shape resolved server-side
  // (ApplicationHelper#nps_container_shape) and exposed on the editor root.
  // Mirrors NpsHelper#nps_shape_slug — a card switched to NPS in the editor has
  // to land on the same vessel a reload would draw for it.
  _npsShape(card) {
    return card?.dataset.cardNpsShape || this.element.dataset.npsShape || "pill"
  }

  // Grouped vessel list for the hidden <select> a rebuilt NPS card needs — the
  // animation picker drives that select, so a card switched to NPS without a
  // round-trip has to carry one or its "Change animation" CTA applies nothing.
  // Read once from the blob in the editor head.
  get _npsShapePicker() {
    if (this.__npsShapePicker) return this.__npsShapePicker
    let data = {}
    try { data = JSON.parse(document.getElementById("nps-shape-picker")?.textContent || "{}") } catch (_) {}
    data.groups = data.groups || []
    data.label = data.label || "Animation"
    this.__npsShapePicker = data
    return data
  }

  selectCard(event) {
    if (event.target.closest("button[data-action*='deleteCard']")) return
    this.selectCardElement(event.currentTarget, { source: "click" })
  }

  // The selection itself, without a click to read it out of. editor-scroll-sync
  // calls this with source: "scroll" when the feed settles on a different card,
  // so the panel edits what the creator is actually looking at.
  //
  // Re-selecting the already-active card returns early on purpose: everything
  // below relocates three DOM blocks and rebuilds two lists, and the scroll sync
  // would otherwise repeat all of it every time the feed came to rest.
  selectCardElement(card, { source = "click" } = {}) {
    if (!card) return

    // A click is a deliberate arrival at this card: if the publish-and-share
    // panel is open, drop back to the answer-type picker so the click reveals
    // the card's edit options — and open the column if it's collapsed. It fires
    // even for the already-active card, because clicking the selected card is
    // how you reopen a panel you closed with ✕.
    //
    // A scroll is not an arrival. It re-points the panel underneath whichever
    // view is open without yanking the creator off Publish/Design, and without
    // opening a column they chose to close.
    if (source === "click") this.dispatch("cardSelected")
    this._disarmDelete() // moving on ⇒ any half-armed Delete stands down

    if (card === this.activeCardEl) return

    this.cardTargets.forEach(c => c.classList.remove("selected"))
    card.classList.add("selected")
    this.activeCardEl = card

    const cardType = card.dataset.cardType
    const cardNum  = card.dataset.cardNum
    this.pendingType = cardType

    const meta = this.typeMeta[cardType]
    this.panelCardNameTarget.textContent = t("editor.card_n", { n: cardNum, type: meta?.badge || cardType })
    this.panelHintTarget.textContent     = t("editor.choose_format")

    this.panelEmptyTarget.style.display = "none"
    this.cardEditorTarget.style.display = "flex"
    this.typeListTarget.style.display    = "flex"
    this.panelFooterTarget.style.display = "flex"

    this._renderCompatibleTypes(cardType)
    this._updateFeatureSlotsFor(card, cardType)
    this._updateBranchFor(card, cardType, cardNum)
    this._renderWhy(card, cardType, cardNum)

    // Paint the pinned sidebar traffic light immediately (it otherwise only
    // repaints on the next markDirty/refreshAll cycle), and point the panel's
    // Card settings switches (Allow other / Required) at this card.
    const surveyEditor = this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
    surveyEditor?.refreshCard(card)
    surveyEditor?.syncCardFlags(card)
  }

  // Re-run the selection for a card whose content just changed under the
  // panel (an undo, an optimise): type list, feature slots, branching and Why
  // all re-read it. As a scroll, not a click — no cardSelected dispatch, so
  // the publish panel is not closed and a collapsed column not opened.
  reselectCard(card) {
    if (!card?.isConnected) return
    this.activeCardEl = null
    this.selectCardElement(card, { source: "scroll" })
  }

  // The panel's side of an undo/redo: the selected card may have been removed
  // (deselect, as a delete does) or morphed (reselect, so the panel shows what
  // the card is now rather than what it was).
  afterUndoRestore({ removed = [], changed = [] } = {}) {
    this._disarmDelete()
    const active = this.activeCardEl
    if (active && (!active.isConnected || removed.includes(active))) this.deselectCard()
    else if (active && changed.includes(active)) this.reselectCard(active)
    this._updateCount()
  }

  // Relocate the just-selected card's quiz/token blocks (if any) into the
  // Quiz mode / Tokenisation tabs' per-card slots, and toggle those tabs'
  // select-a-card hints. Only one card's blocks are ever out of their card at
  // a time — the previously active card's blocks get parked (not lost — see
  // _parkSlotContents). The slots only render when the feature is on.
  _updateFeatureSlotsFor(card, cardType) {
    const isQ = !NON_QUESTION_TYPES.includes(cardType)

    this._parkSlotContents()
    const tokenBlock = isQ && this.tokenisationValue ? this.tokenBlockFor(card) : null
    const quizBlock  = isQ && this.quizValue         ? this.quizBlockFor(card)  : null
    if (this.hasTokenSlotTarget && tokenBlock) this.tokenSlotTarget.appendChild(tokenBlock)
    if (this.hasQuizSlotTarget && quizBlock)   this.quizSlotTarget.appendChild(quizBlock)
    if (this.hasTokensEmptyTarget) this.tokensEmptyTarget.style.display = tokenBlock ? "none" : ""
    if (this.hasQuizEmptyTarget)   this.quizEmptyTarget.style.display   = quizBlock ? "none" : ""
  }

  // Populate the top-level "Branching" tab for the selected card: relocate its
  // routing block (per-answer "go to…" selects + default row) into the panel if
  // the card is a routable single-pick question, otherwise show a note. Mirrors
  // the Tokenomics/Quiz relocation — only one card's block is ever out of its
  // card at a time; the previous one gets parked (see _parkSlotContents).
  _updateBranchFor(card, cardType, cardNum) {
    if (!this.hasLogicSlotTarget) return // logic off ⇒ no Branching panel

    if (this.hasBranchCardNameTarget) {
      const meta = this.typeMeta[cardType]
      this.branchCardNameTarget.textContent = t("editor.card_n", { n: cardNum, type: meta?.badge || cardType })
    }

    const routable = this.logicValue && ROUTABLE_TYPES.includes(cardType)
    this._parkingLot.append(...this.logicSlotTarget.children) // park previous card's block
    const block = routable ? this.logicBlockFor(card) : null
    if (block) this.logicSlotTarget.appendChild(block)

    // .type-panel-empty forces display:flex, so toggle inline display (not the
    // hidden attribute) the same way the Why panel's empty state does.
    if (this.hasBranchEmptyTarget) this.branchEmptyTarget.style.display = "none"       // a card is now selected
    if (this.hasBranchNoteTarget)  this.branchNoteTarget.style.display  = routable ? "none" : "flex" // only for non-routable
  }

  // Populate the "Why" tab for the selected card: the competency it sits under,
  // the plain-language outcome its answers generate, and any enabling condition
  // it measures. Runs on every card select (whichever tab is visible) so
  // switching to Why always reflects the current card.
  _renderWhy(card, cardType, cardNum) {
    if (!this.hasWhyBodyTarget) return

    const fw      = this.framework || {}
    const meta    = this.typeMeta[cardType]
    const comp    = card.dataset.cardCompetency
    const cond    = card.dataset.cardCondition
    const outcome = card.dataset.cardOutcome
    const isQ     = !NON_QUESTION_TYPES.includes(cardType)

    if (this.hasWhyCardNameTarget) {
      this.whyCardNameTarget.textContent = t("editor.card_n", { n: cardNum, type: meta?.badge || cardType })
    }
    if (this.hasWhyEmptyTarget) this.whyEmptyTarget.style.display = "none"
    this.whyBodyTarget.hidden = false

    const compMeta = comp ? fw.competencies?.[comp] : null
    const condMeta = cond ? fw.conditions?.[cond] : null

    if (this.hasWhyCompetencyRowTarget) {
      if (compMeta) {
        this._paintWhyBadge(this.whyCompetencyBadgeTarget, compMeta)
        if (this.hasWhyCompetencyBlurbTarget) this.whyCompetencyBlurbTarget.textContent = compMeta.blurb || ""
      }
      this.whyCompetencyRowTarget.hidden = !compMeta
    }

    if (this.hasWhyOutcomeRowTarget) {
      if (outcome && this.hasWhyOutcomeTarget) this.whyOutcomeTarget.textContent = outcome
      this.whyOutcomeRowTarget.hidden = !outcome
    }

    if (this.hasWhyConditionRowTarget) {
      if (condMeta) {
        this._paintWhyBadge(this.whyConditionBadgeTarget, condMeta)
        if (this.hasWhyConditionBlurbTarget) this.whyConditionBlurbTarget.textContent = condMeta.blurb || ""
      }
      this.whyConditionRowTarget.hidden = !condMeta
    }

    // A note for intro cards (nothing to measure) and for question cards that
    // predate this feature (no Why data stored yet).
    let note = ""
    if (!isQ) note = t("editor.why_intro_card")
    else if (!compMeta && !condMeta && !outcome) note = t("editor.why_unanalysed")
    if (this.hasWhyNoteTarget) {
      this.whyNoteTarget.textContent = note
      this.whyNoteTarget.hidden = !note
    }
    if (this.hasWhyFrameworkTarget) this.whyFrameworkTarget.hidden = !isQ
  }

  // Colour a Why badge from its framework metadata (label + accent hex).
  _paintWhyBadge(el, meta) {
    if (!el) return
    el.textContent = meta.label || ""
    const accent = /^#[0-9a-fA-F]{6}$/.test(meta.accent || "") ? meta.accent : "#01EACB"
    el.style.color = accent
    el.style.borderColor = accent + "66"
    el.style.background = accent + "1f"
  }

  setType(event) {
    const type = event.currentTarget.dataset.type
    this.pendingType = type
    this.typeOptTargets.forEach(o => o.classList.toggle("active", o.dataset.type === type))
  }

  // Cycles a Range card's slider layout auto -> horizontal -> vertical -> auto
  // and rebuilds it in place. Reuses _applyToCard rather than hand-patching
  // the DOM: the type isn't actually changing (wasType and type are both
  // "range"), so its badge/eyebrow/lottie side effects are all no-ops here —
  // it's just the one code path that already knows how to rebuild this slot.
  setSliderAxis(event) {
    const card = event.currentTarget.closest('[data-survey-editor-target="card"]')
    if (!card || card.dataset.cardType !== "range") return
    const CYCLE = { auto: "horizontal", horizontal: "vertical", vertical: "auto" }
    const current = card.dataset.cardSliderAxis || "auto"
    card.dataset.cardSliderAxis = CYCLE[current] || "auto"
    this._applyToCard(card, "range")
    this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")?.markDirty()
  }

  applyType() {
    if (!this.activeCardEl || !this.pendingType) return
    this._applyToCard(this.activeCardEl, this.pendingType)
    this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")?.syncCardFlags(this.activeCardEl)
    this._toast(t("editor.type_updated", { type: this.typeMeta[this.pendingType]?.badge || this.pendingType }))
    this.dispatch("changed")
  }

  openAllTypes() {
    if (!this.activeCardEl) return
    const cardType = this.activeCardEl.dataset.cardType
    const meta = this.typeMeta[cardType]
    if (this.hasModalCardNameTarget) {
      this.modalCardNameTarget.textContent = meta?.badge || cardType
    }
    this._renderAllTypesModal(cardType)
    this.allTypesModalTarget.classList.remove("hidden")
  }

  closeAllTypes() {
    this.allTypesModalTarget.classList.add("hidden")
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  applyTypeFromAll(event) {
    const type = event.currentTarget.dataset.type
    if (!this.activeCardEl || !type) return
    this.pendingType = type
    this._applyToCard(this.activeCardEl, type)
    this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")?.syncCardFlags(this.activeCardEl)
    this._toast(t("editor.type_updated", { type: this.typeMeta[type]?.badge || type }))
    this.dispatch("changed")
    this.closeAllTypes()
  }

  deleteCard(event) {
    event.stopPropagation()
    // Delete always acts on the card it lives inside. There used to be a
    // fallback to whichever card was merely SELECTED, for a pinned sidebar
    // button that no longer exists — a button with no visual tie to its target
    // deleting the current selection is a trap, so it's gone rather than
    // dormant.
    const btn  = event.currentTarget
    const card = btn.closest("[data-type-panel-target='card']")
    if (!card) return
    // Two-step confirm on the button itself — the first tap arms it (solid
    // fill + "Really delete?"), a second tap within 3s deletes, and anything
    // else disarms it. Replaces the native window.confirm popup, which broke
    // the editor's look mid-flow.
    if (btn !== this._armedDeleteBtn) {
      this._disarmDelete()
      this._armedDeleteBtn = btn
      btn.classList.add("is-armed")
      const label = btn.querySelector("span")
      if (label) {
        btn.dataset.restingLabel = label.textContent
        label.textContent = t("editor.confirm_delete")
      }
      this._armTimer = setTimeout(() => this._disarmDelete(), 3000)
      return
    }
    this._disarmDelete()
    // Remove the whole slot (card + its "Add question" CTA), falling back to the
    // bare card for any context that doesn't use slots.
    const doomed = card.closest(".card-slot") || card
    // The editor's undo base already holds this very node (it snapshots the
    // deck at rest), so ⌘Z re-inserts THIS element — which is what reunites
    // the card with any quiz/token/logic blocks parked in the sidebar
    // (they're keyed off the card element, not its cid).
    doomed.remove()
    if (card === this.activeCardEl) this.deselectCard()
    this._updateCount()
    this.dispatch("changed")
  }

  // Back to the "select a card" state: after the active card was deleted, or
  // an undo removed it.
  deselectCard() {
    this.activeCardEl = null
    this.panelEmptyTarget.style.display  = ""
    this.cardEditorTarget.style.display  = "none"
    this.typeListTarget.style.display    = "none"
    this.panelFooterTarget.style.display = "none"
    // The card's blocks (if relocated into the sidebar) go with it — there's
    // no card left to save their data against.
    this._parkSlotContents()
    if (this.hasTokensEmptyTarget) this.tokensEmptyTarget.style.display = ""
    if (this.hasQuizEmptyTarget)   this.quizEmptyTarget.style.display   = ""
    this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")?.syncCardFlags(null)
  }

  // Put an armed Delete button back to rest (label + styling). Safe to call
  // when nothing is armed, or after the button's card left the DOM.
  _disarmDelete() {
    clearTimeout(this._armTimer)
    const btn = this._armedDeleteBtn
    this._armedDeleteBtn = null
    if (!btn || !btn.isConnected) return
    btn.classList.remove("is-armed")
    const label = btn.querySelector("span")
    if (label && btn.dataset.restingLabel) label.textContent = btn.dataset.restingLabel
    delete btn.dataset.restingLabel
  }

  // ── private ──────────────────────────────────────────

  _renderCompatibleTypes(cardType) {
    const compat = COMPATIBILITY[cardType] || [{ type: cardType, score: 100, note: "" }]
    // Keep only the top N recommendations, ranked by score descending.
    const ranked = [...compat]
      .sort((a, b) => b.score - a.score)
      .slice(0, this.TOP_N)
    const rankMap = new Map(ranked.map((c, i) => [c.type, { entry: c, rank: i }]))

    // Reorder the DOM so wraps render in rank order (1st → 4th, top to
    // bottom). Without this they stay in CardTypes.pickable order.
    const list = this.typeListTarget
    ranked.forEach(({ type }) => {
      const opt  = this.typeOptTargets.find(o => o.dataset.type === type)
      const wrap = opt?.closest(".type-opt-wrap")
      if (wrap && list) list.appendChild(wrap)
    })

    this.typeOptTargets.forEach(opt => {
      const type  = opt.dataset.type
      const slot  = rankMap.get(type)
      // The tile lives inside a .type-opt-wrap whose left rail holds the
      // medal/star emoji — hide/show the wrap so the rail goes with it.
      const wrap = opt.closest(".type-opt-wrap") || opt

      if (!slot) { wrap.style.display = "none"; return }

      const { entry, rank } = slot
      wrap.style.display = ""
      opt.classList.toggle("active", type === cardType)

      const rankEl = wrap.querySelector(".type-opt-rank")
      if (rankEl) rankEl.textContent = this.RANK_EMOJI[rank] || ""

      opt.querySelector(".type-opt-score")?.remove()
      const badge = document.createElement("div")
      badge.className = "type-opt-score"
      if (type === cardType) {
        badge.textContent = t("editor.current")
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = fitTier(entry.score)
      }
      const radio = opt.querySelector(".type-opt-radio")
      if (radio) radio.before(badge)

      // The contextual note is the explainer now — it surfaces in the ⓘ
      // modal (the panel card itself stays compact, desc is hidden via CSS).
      const note = compatNote(cardType, entry)
      if (note) {
        const descEl = opt.querySelector(".type-opt-desc")
        if (descEl) descEl.textContent = note
        const infoEl = opt.querySelector(".type-opt-info")
        if (infoEl) infoEl.dataset.typeExplainer = note
      }
    })
  }

  // Modal: sort every pickable type by its fit score for the current card,
  // re-order the DOM, and decorate each tile with a fit-tier badge.
  _renderAllTypesModal(cardType) {
    if (!this.hasAllTypeOptTarget) return
    const compat = COMPATIBILITY[cardType] || []
    const scoreFor = (t) => {
      if (t === cardType) return 101
      const hit = compat.find(c => c.type === t)
      return hit ? hit.score : 0
    }
    const noteFor = (ty) => {
      const entry = compat.find(c => c.type === ty)
      return entry ? compatNote(cardType, entry) : ""
    }

    const sorted = [...this.allTypeOptTargets].sort((a, b) =>
      scoreFor(b.dataset.type) - scoreFor(a.dataset.type)
    )
    const list = this.allTypesListTarget || sorted[0]?.parentElement
    sorted.forEach(el => list && list.appendChild(el))

    this.allTypeOptTargets.forEach(opt => {
      const type  = opt.dataset.type
      const score = scoreFor(type)

      opt.classList.toggle("active", type === cardType)

      opt.querySelector(".type-opt-score")?.remove()
      const badge = document.createElement("div")
      badge.className = "type-opt-score"
      if (type === cardType) {
        badge.textContent = t("editor.current")
        badge.setAttribute("data-primary", "true")
      } else {
        badge.textContent = score > 0 ? fitTier(score) : t("editor.off_brief")
      }
      const row = opt.querySelector(".type-opt-row > div[style]")
      if (row) row.parentElement.appendChild(badge)

      const note = noteFor(type)
      if (note) {
        const descEl = opt.querySelector(".type-opt-desc")
        if (descEl) descEl.textContent = note
        const infoEl = opt.querySelector(".type-opt-info")
        if (infoEl) infoEl.dataset.typeExplainer = note
      }
    })
  }


  _applyToCard(card, type) {
    const meta = this.typeMeta[type]
    if (!meta) return

    const wasType = card.dataset.cardType

    // The book widget needs its right panel to join the flex-column fill chain
    // (see .split-right--book in application.css) — the server only adds this
    // class on initial render, so a client-side type switch has to toggle it
    // itself or the book silently sits at its min-height. Keyed on PAGED_TYPES
    // to match the server template, which uses Survey::PAGED_TYPES.
    const splitRight = card.querySelector(".split-right")
    if (splitRight) splitRight.classList.toggle("split-right--book", isPaged(type))

    // 1. Update badge + eyebrow
    const badge = card.querySelector(".s-badge")
    if (badge) { badge.textContent = meta.badge; badge.className = `s-badge ${meta.css}` }

    // A tick ceiling belongs to the multi-select types alone, so leaving the
    // old type's number on the card would have the picker — and the caption
    // below — go on advertising a cap the new type can't honour. The server
    // sanitiser would drop it on the next save; the creator is looking at the
    // card NOW.
    if (!MULTI_SELECT_TYPES.includes(type)) delete card.dataset.cardMaxChoices

    const eyebrow = card.querySelector(".q-eyebrow")
    if (eyebrow) {
      eyebrow.textContent = cardEyebrow(this.eyebrows, this.defaultLocaleValue, type,
                                        card.dataset.cardMaxChoices, meta.eyebrow)
    }

    // 2. Swap the interactive component HTML on the RIGHT panel
    const slot = card.querySelector("[data-card-component]")
    if (slot) {
      const opts = this._optionsFor(card, type)
      const builder = COMPONENTS[type] || (() => "")
      slot.innerHTML = builder(opts, {
        ratingIcon:      this._ratingIcon(),
        ratingEmoji:     card.dataset.cardRatingEmoji || "",
        npsShape:        this._npsShape(card),
        npsShapeGroups:  this._npsShapePicker.groups,
        npsShapeLabel:   this._npsShapePicker.label,
        npsCustomScale:  card.dataset.cardNpsCustomScale,
        // Evaluated before `slot.innerHTML =` replaces the old markup, so the
        // words on screen are still there to read.
        npsAnchors:      this._npsAnchorsFor(card),
        rangeThemes:     this._rangeThemePicker.themes,
        rangeThemeGroups: this._rangeThemePicker.groups,
        rangeThemeLabel: this._rangeThemePicker.label,
        rangeTheme:      card.dataset.cardRangeTheme || "",
        // Only the two multi-select builders read this; it is cleared above for
        // every other type, so a switch away drops the cap with the markup.
        maxChoices:      parseInt(card.dataset.cardMaxChoices, 10) || 0,
        sliderAxis:      card.dataset.cardSliderAxis || "auto",
        pages:           this._pagesFor(card, type),
        optionImages:    this._optionImagesFor(card, type),
        optionFocals:    this._optionFocalsFor(card),
        optionStyles:    this._optionStylesFor(card),
        responses:       this._responsesFor(card),
        // yes_no's builder renders the quiz mark-correct button itself.
        quiz:            this.quizValue,
        // Kept off the card's own dataset because it is only ever read here;
        // the select the builder renders is what owns it from then on.
        charLimit:       parseInt(card.querySelector("[data-char-limit]")?.value, 10) || undefined
      })
      // The server renders option icons inline; rebuilt markup must get the
      // same pass or a type switch strips every icon until the next reload.
      injectIcons(slot)
    }

    card.dataset.cardType = type

    // The "Other" block applies to question types only; same for the Required
    // chip on the chrome row (its switch lives in the Answer Type tab's Card
    // settings — see survey-editor#syncCardFlags).
    const isQuestion = !NON_QUESTION_TYPES.includes(type)
    const otherBlock = card.querySelector(".other-block")
    if (otherBlock) otherBlock.hidden = !isQuestion
    const requiredChip = card.querySelector("[data-role='required-chip']")
    if (requiredChip) requiredChip.hidden = !isQuestion || card.dataset.cardRequired !== "true"

    // 3. Swap LEFT panel when entering or leaving Range — Range shows the
    //    reactive Lottie that other types don't, and other types need the
    //    design-prompt / image chrome that the Lottie suppresses.
    if (type === "range" && wasType !== "range") {
      this._mountNpsLottie(card)
    } else if (wasType === "range" && type !== "range") {
      this._unmountNpsLottie(card)
    }
    this._syncAnimationCta(card, type)

    if (card === this.activeCardEl) {
      const num = card.dataset.cardNum
      this.panelCardNameTarget.textContent = t("editor.card_n", { n: num, type: meta.badge })
      this._renderCompatibleTypes(type)
      this.pendingType = type
    }
  }

  // ── NPS left-panel mount/unmount ─────────────────────────
  // The Lottie URLs blob is rendered once per page (see show.html.erb) so
  // we can mount the lottie-player without going back to the server when a
  // card is switched to NPS. CSS (`.split-left:has(.nps-lottie) > …`)
  // handles hiding the image / design-prompt chrome while the Lottie
  // is mounted.

  get _npsLottieUrls() {
    if (this.__npsLottieUrls) return this.__npsLottieUrls
    try {
      const raw = document.getElementById("nps-lottie-urls")?.textContent || "[]"
      this.__npsLottieUrls = JSON.parse(raw)
    } catch (_) {
      this.__npsLottieUrls = []
    }
    return this.__npsLottieUrls
  }

  // Range-card theme picker blob (label + [{slug,label,urls}]). Read once.
  get _rangeThemePicker() {
    if (this.__rangeThemePicker) return this.__rangeThemePicker
    let data = {}
    try { data = JSON.parse(document.getElementById("range-theme-picker")?.textContent || "{}") } catch (_) {}
    data.themes = data.themes || []
    data.groups = data.groups || []
    data.label = data.label || "Animation"
    this.__rangeThemePicker = data
    return data
  }

  _mountNpsLottie(card) {
    const left = card.querySelector(".split-left")
    if (!left || left.querySelector(".nps-lottie")) return
    // Honour the card's chosen theme; fall back to the default basketball set.
    const theme = card.dataset.cardRangeTheme || ""
    const urls = this._rangeThemePicker.themes.find(th => th.slug === theme)?.urls || this._npsLottieUrls
    if (!urls.length) return

    const wrap = document.createElement("div")
    wrap.className = "nps-lottie"
    wrap.dataset.controller = "lottie-player"
    wrap.dataset.lottiePlayerUrlsValue = JSON.stringify(urls)
    // Start on the NEUTRAL middle frame (3 of 5), same as the server-rendered
    // path — see NpsHelper::NPS_NEUTRAL_FRAME. Derived from the set's own
    // length so it stays centred if the frame count ever changes.
    wrap.dataset.lottiePlayerCurrentValue = String(Math.ceil(urls.length / 2))

    const mount = document.createElement("div")
    mount.className = "nps-lottie-mount"
    mount.dataset.lottiePlayerTarget = "mount"
    wrap.appendChild(mount)

    // Position above .panel-progress so the Lottie sits behind the progress
    // bar exactly like the server-rendered version does.
    left.insertBefore(wrap, left.firstChild)
  }

  _unmountNpsLottie(card) {
    const left = card.querySelector(".split-left")
    const wrap = left && left.querySelector(".nps-lottie")
    if (wrap) wrap.remove() // lottie-player controller's disconnect() destroys the lottie instance
  }

  // ── "Change animation" CTA ───────────────────────────────
  // Two types have an animation to change (Range's reaction character, NPS's
  // liquid container) and _split_left renders the CTA for them server-side. A
  // type switch happens without a server render, so without this the creator
  // switched a card to Range or NPS, got the animation, and had no way to
  // change it until the next reload — the control existed and was unreachable.
  //
  // Only the button moves. Every editable card already has a .split-left-cta-row
  // (see _split_left.html.erb: all four media branches render one), so there is
  // no row-building logic to mirror here — which is the whole reason this is a
  // few lines rather than a copy of that partial.
  _syncAnimationCta(card, type) {
    const row = card.querySelector(".split-left-cta-row")
    if (!row) return
    const existing = row.querySelector(".add-animation-fab")
    const action = type === "range" ? "open" : type === "nps" ? "openShapes" : null

    if (!action) { existing?.remove(); return }
    if (existing) {
      // Range → NPS (or back) keeps the button and re-points it.
      existing.dataset.action = `click->animation-picker#${action}`
      return
    }
    const holder = document.createElement("template")
    holder.innerHTML = changeAnimationFabHtml(action).trim()
    row.insertBefore(holder.content.firstElementChild, row.firstChild)
  }

  // What the rebuilt card should be given as its options.
  //
  // What is ON SCREEN wins. data-card-options is written once, by the server,
  // at page render, and nothing updates it — so preferring it meant re-applying
  // a type rebuilt the card from labels the creator had already replaced, and
  // the autosave that followed persisted the revert. Only when the card has no
  // options on screen (it is currently a type that has none) does the snapshot
  // matter: that is the switch-away-and-back memory it exists for.
  // The anchor lines beside an NPS scale's ends, as { low, high }. What is on
  // screen wins, for _optionsFor's reason; the server-written snapshot
  // (data-card-nps-anchors) is the switch-away-and-back memory, so nps → other
  // → nps keeps the creator's words the way options do.
  _npsAnchorsFor(card) {
    const live = {}
    for (const which of [ "low", "high" ]) {
      live[which] = card.querySelector(`[data-role='nps-anchor-${which}']`)?.textContent.trim() || ""
    }
    if (live.low || live.high) return live
    try {
      const snap = JSON.parse(card.dataset.cardNpsAnchors || "{}")
      return { low: snap.low || "", high: snap.high || "" }
    } catch (_) { return live }
  }

  _optionsFor(card, type) {
    if (type === "yes_no") return defaultOptionsFor("yes_no")

    const live = this._liveOptions(card)
    if (live.length) return live

    let original = []
    try { original = JSON.parse(card.dataset.cardOptions || "[]") } catch (_) {}
    if (original.length) return original
    return defaultOptionsFor(type)
  }

  // The same nodes serialize() reads, so the panel and the save agree about
  // what the card currently says.
  _liveOptions(card) {
    const editor = this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
    if (!editor?._optionEls) return []
    const labels = editor._optionEls(card).map(el => el.textContent.trim())
    // Mirror serialize()'s rule exactly: a RANGE label is a POSITIONAL stop,
    // and a blank one is an unnamed stop, not an absent option. Filtering it
    // here handed the rebuild 4 labels, whose upsampler then re-spread them
    // across 5 stops — sliding the creator's remaining labels onto the wrong
    // positions and autosaving the shuffle.
    const kept = card.dataset.cardType === "range" ? labels : labels.filter(Boolean)
    return kept.some(Boolean) ? kept : []
  }

  // Existing pages if this card already had some (switching away from
  // Scenario and back preserves what was written), else a fresh blank page.
  _pagesFor(card, type) {
    if (!isPaged(type)) return []

    // Same rule as _optionsFor: live pages beat the render-time snapshot.
    const editor = this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
    const live = editor?._pageEls
      ? editor._pageEls(card).map(el => ({
          id: el.closest(".book-page")?.dataset.pageId || "",
          text: el.textContent.trim()
        })).filter(p => p.text)
      : []
    if (live.length) return live

    let original = []
    try { original = JSON.parse(card.dataset.cardPages || "[]") } catch (_) {}
    if (Array.isArray(original) && original.length) return original
    return DEFAULT_PAGES[type] || []
  }

  // Existing option_images if this card already had some (switching away
  // from Tap Cards and back restores the previous designs), else a fresh
  // set generated from the same curated pool addTapOption draws from —
  // applying Tap Cards for the first time shouldn't leave every statement a
  // bare gradient when a ready-made pool of on-brand images already exists.
  //
  // Unlike _pagesFor/_optionsFor, a freshly generated result is written back
  // onto card.dataset.cardOptionImages before returning it (not just handed
  // to the builder for this one render). That dataset attribute is the only
  // record of a tap card's images — the autosave serializer reads it
  // directly, and this same method reads it back on the NEXT call to decide
  // whether to restore vs. regenerate. Without persisting it here, a fresh
  // set would render once, never reach the server, and regenerate a
  // different random set every time the card round-tripped through this
  // type again.
  _optionImagesFor(card, type) {
    if (type !== "tap_card") return []
    let original = []
    try { original = JSON.parse(card.dataset.cardOptionImages || "[]") } catch (_) {}
    if (Array.isArray(original) && original.length) return original
    const generated = this._generateTapOptionImages(card, this._optionsFor(card, type).length)
    if (generated.length) card.dataset.cardOptionImages = JSON.stringify(generated)
    return generated
  }

  // Per-statement repositions for the rebuild, positional against
  // option_images. Carried through a type switch for the same reason the
  // images are: a creator who tries another type and comes back should find
  // their framing, not every picture snapped back to centre.
  _optionFocalsFor(card) {
    try {
      const focals = JSON.parse(card.dataset.cardOptionFocals || "[]")
      return Array.isArray(focals) ? focals : []
    } catch (_) {
      return []
    }
  }

  // Per-option style overrides for the rebuild, from the same snapshot
  // serialize() refreshes (data-card-option-styles) — positional, like
  // option_images. Styles survive a type switch between choice-shaped types
  // because every such builder threads them back into the rows.
  _optionStylesFor(card) {
    try {
      const styles = JSON.parse(card.dataset.cardOptionStyles || "[]")
      return Array.isArray(styles) ? styles : []
    } catch (_) {
      return []
    }
  }

  // The tap card's response scale for the rebuild, from the same snapshot
  // serialize() refreshes (data-card-responses). Carried through a type switch
  // like option_images, so a creator who built a 5-point scale, tried Range and
  // came back finds their scale rather than the default three. An empty array
  // means "no stored scale", which resolveResponses reads as the historic three.
  _responsesFor(card) {
    try {
      const list = JSON.parse(card.dataset.cardResponses || "[]")
      return Array.isArray(list) ? list : []
    } catch (_) {
      return []
    }
  }

  _generateTapOptionImages(card, count) {
    const pool = this._swipeCardPool(card)
    if (!pool.length || !count) return []
    const picks = []
    for (let i = 0; i < count; i++) {
      const unused = pool.filter(u => !picks.includes(u))
      const choices = unused.length > 0 ? unused : pool // exhausted → allow repeats
      picks.push(choices[Math.floor(Math.random() * choices.length)])
    }
    return picks
  }

  // Mirrors card_editor_controller.js#_pickSwipeUrl's pool lookup — the
  // curated swipe-card URLs live as a data attribute on the editor root.
  _swipeCardPool(card) {
    const editorRoot = card.closest("[data-swipe-card-urls]") || this.element.closest("[data-swipe-card-urls]")
    if (!editorRoot) return []
    try {
      const pool = JSON.parse(editorRoot.dataset.swipeCardUrls || "[]")
      return Array.isArray(pool) ? pool : []
    } catch (_) { return [] }
  }

  _updateCount() {
    if (!this.hasCardCountTarget) return
    const n = this.cardTargets.length
    this.cardCountTarget.textContent = t("editor.cards_count", { n })
  }

  _toast(msg) {
    this.toastMsgTarget.textContent = msg
    this.toastTarget.classList.add("show")
    setTimeout(() => this.toastTarget.classList.remove("show"), 2200)
  }
}
