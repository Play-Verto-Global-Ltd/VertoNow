import { Controller } from "@hotwired/stimulus"
import { tapResetRowHtml } from "lib/tap_response_templates"
import { t } from "lib/i18n"

// The one place this file builds markup from a translated string. Small enough
// to state here rather than pull in a helper: an aria-label is the only
// attribute involved, and a stray quote in a locale would otherwise close it.
function escapeAttr(s) {
  return String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")
}

export default class extends Controller {
  static targets = [
    "overlay", "card", "backBtn", "nextBtn",
    "finishBtn", "thankyou", "returnBtn", "editBtn", "progress",
    "thankyouTitle", "thankyouBody", "thankyouForward"
  ]
  static values = { current: { type: Number, default: 0 } }

  open() {
    this._syncPreviewCards()
    this._syncThankyou()
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")
    this.currentValue = 0
    // Each Preview is a fresh run, so every intro modal is unmet again. Keyed
    // by element rather than by cid: these cards are rebuilt from the editor's
    // DOM on every open, and a creator previewing right after adding a card
    // has one with no cid yet.
    this._modalSeen = new WeakSet()
    this.thankyouTarget.classList.remove("active")
    this._update()
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.classList.remove("flex")
  }

  next() {
    // Scenario: mirror player_controller's interception so Preview behaves
    // exactly like the real player — Next turns the page until the book's
    // own answer page is showing.
    if (this._scenarioTurn(this.currentValue, 1)) return
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back() {
    if (this._scenarioTurn(this.currentValue, -1)) return
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  // See player_controller.js — same pattern, duplicated because this preview
  // overlay clones the editor DOM independently rather than sharing the
  // player's controller.
  _scenarioController(idx) {
    const card = this.cardTargets[idx]
    if (!card) return null
    const el = card.querySelector('[data-controller~="scenario"]')
    if (!el) return null
    return this.application.getControllerForElementAndIdentifier(el, "scenario")
  }

  _scenarioTurn(idx, delta) {
    const ctrl = this._scenarioController(idx)
    if (!ctrl) return false
    return delta > 0 ? ctrl.next() : ctrl.back()
  }

  finish() {
    if (this._scenarioTurn(this.currentValue, 1)) return
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    if (this.hasEditBtnTarget) this.editBtnTarget.classList.add("hidden")
    this.returnBtnTarget.classList.remove("hidden")
    this.progressTarget.textContent = ""
  }

  returnToDesign() {
    this.close()
    // Reset so next open() starts clean
    this.thankyouTarget.classList.remove("active")
    this.returnBtnTarget.classList.add("hidden")
    this._update()
  }

  // Close the preview and drop the user back into the editor with the
  // card they were just looking at selected (so the type panel shows
  // that card's options).
  edit() {
    const idx = this.currentValue
    this.close()
    this.thankyouTarget.classList.remove("active")
    this.returnBtnTarget.classList.add("hidden")
    this._update()
    const editorCards = document.querySelectorAll('[data-type-panel-target="card"]')
    const target = editorCards[idx]
    if (!target) return
    target.scrollIntoView({ behavior: "smooth", block: "center" })
    target.click()
  }

  _update() {
    const total = this.cardTargets.length
    const idx   = this.currentValue

    this.cardTargets.forEach((c, i) =>
      c.classList.toggle("active", i === idx))
    // The creator's intro modal, if this card has one and this preview run has
    // not met it yet. Same placement as the player's: before the nav work, so
    // the attribute that hides the nav is set by the time it runs.
    this._syncCardModal(this.cardTargets[idx])

    this.progressTarget.textContent = `Card ${idx + 1} of ${total}`

    // Back: invisible on first card so layout doesn't shift
    this.backBtnTarget.classList.remove("hidden")
    this.backBtnTarget.classList.toggle("invisible", idx === 0)
    this.backBtnTarget.classList.remove("invisible-off")

    // Edit: always visible while previewing, hidden on the thank-you screen
    if (this.hasEditBtnTarget) this.editBtnTarget.classList.remove("hidden")

    // Next vs Finish
    const isLast = idx === total - 1
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
    this.returnBtnTarget.classList.add("hidden")
  }

  // Rebuild preview cards from the editor's live DOM. The editor card
  // markup IS the source of truth — autosave reads from it too. We
  // deep-clone each editor `.split-card`, strip the editor-only chrome
  // (contenteditable, delete/add buttons, the "Add media" FAB, the tap card's
  // statement pager, the card-editor controller binding), and drop it into the matching
  // `.preview-card` wrapper. Stimulus's MutationObserver rebinds the
  // picker / tap-stack / slider / rating controllers automatically.
  // The thank-you screen is server-rendered once, at page load, and the feed's
  // gate card is edited live — so opening Preview after typing a new title used
  // to show the OLD one, next to cards that were perfectly up to date. Same
  // rule as the cards above: the editor's markup is the source of truth, so
  // read it rather than the value the page happened to boot with.
  //
  // Reads the CARD, not the save: gate-cards debounces its POST by 900ms, so
  // waiting for persistence would mean previewing stale copy for a second
  // after every keystroke.
  _syncThankyou() {
    const feed = (sel) => document.querySelector(sel)
    // fallbackAttr null means the field has no default to fall back to.
    const copy = (target, source, fallbackAttr = "defaultText") => {
      if (!target || !source) return
      const written = source.textContent.trim()
      target.textContent = written || (fallbackAttr && source.dataset[fallbackAttr]) || ""
    }

    copy(this.hasThankyouTitleTarget ? this.thankyouTitleTarget : null,
         feed("[data-gate-cards-target='tyTitle']"))
    // No fallback for the message: it has no default any more. The box's
    // data-default-text is its PLACEHOLDER now (the byline it used to hold
    // moved to its own line), and falling back to it put "Add a short message"
    // on the screen as though a respondent were meant to read it.
    copy(this.hasThankyouBodyTarget ? this.thankyouBodyTarget : null,
         feed("[data-gate-cards-target='tyBody']"), null)

    // The forward button is an <input> pair in the editor and a pill here, so
    // it is rebuilt rather than copied — and hidden when there is no URL,
    // exactly as the player hides it.
    if (this.hasThankyouForwardTarget) {
      const url   = feed("[data-gate-cards-target='tyForwardUrl']")
      const label = feed("[data-gate-cards-target='tyForwardLabel']")
      const href  = url ? url.value.trim() : ""
      this.thankyouForwardTarget.classList.toggle("hidden", href === "")
      if (href !== "") {
        const text = label && label.value.trim() !== ""
          ? label.value.trim()
          : (label ? label.placeholder : "")
        if (text) this.thankyouForwardTarget.textContent = `${text} →`
      }
    }
  }

  _syncPreviewCards() {
    const editorCards = Array.from(
      document.querySelectorAll('[data-type-panel-target="card"]')
    )
    const previewBody = this.element.querySelector(".preview-body")
    if (!previewBody) return

    let previewCards = Array.from(previewBody.querySelectorAll(".preview-card"))

    // Reconcile count — add wrappers for new cards, remove trailing
    // wrappers if the editor has fewer cards now.
    while (previewCards.length < editorCards.length) {
      const wrap = document.createElement("div")
      wrap.className = "preview-card"
      wrap.setAttribute("data-preview-verto-target", "card")
      // Insert before the thank-you screen so it stays at the end.
      const thankyou = previewBody.querySelector(".preview-thankyou")
      previewBody.insertBefore(wrap, thankyou)
      previewCards.push(wrap)
    }
    while (previewCards.length > editorCards.length) {
      const extra = previewCards.pop()
      extra.remove()
    }

    editorCards.forEach((editorCard, i) => {
      const splitCard = editorCard.querySelector(".split-card")
      if (!splitCard) return

      const clone = splitCard.cloneNode(true)
      this._stripEditorChrome(clone)

      const previewCard = previewCards[i]
      previewCard.innerHTML = ""
      previewCard.appendChild(clone)
    })
  }

  // ── The creator's intro modal, in Preview ─────────────────────────────────
  // This overlay is a second, independent implementation of the deck walk (see
  // _scenarioController's note on why), so the modal needs its open/dismiss
  // here too. It is the player's behaviour, deliberately: once per card per
  // preview, the nav away while it is up, the re-open pill afterwards — a
  // preview that skipped the pop-up would be a preview of a different Verto.

  _playeriseCardModal(clone) {
    const layer = clone.querySelector("[data-role='card-modal']")
    if (!layer) return
    // The editor renders a replica on EVERY card (the serialiser needs its
    // nodes there whether or not a modal exists, and CSS hides the ones that
    // are off). The player renders one only where there is a modal, and this
    // clone has to look like the player's markup, not the editor's — otherwise
    // every card in Preview opens an empty pop-up over itself.
    const words = [ "card-modal-title", "card-modal-body" ]
      .some(role => layer.querySelector(`[data-role='${role}']`)?.textContent.trim())
    if (!words) {
      layer.remove()
      clone.querySelector("[data-role='card-modal-reopen']")?.remove()
      return
    }
    layer.classList.remove("is-editing", "is-folded")
    layer.hidden = true
    const cta = layer.querySelector(".card-modal-cta")
    if (cta) {
      cta.removeAttribute("tabindex")
      cta.dataset.action = "click->preview-verto#dismissCardModal"
    }
    const reopen = clone.querySelector("[data-role='card-modal-reopen']")
    if (reopen) reopen.dataset.action = "click->preview-verto#reopenCardModal"
  }

  _syncCardModal(card) {
    const layer = card?.querySelector("[data-role='card-modal']")
    if (layer && layer.hidden && !this._modalSeen?.has(card)) this._openCardModal(card)
    else if (!layer || this._modalSeen?.has(card)) this._closeCardModal({ seen: false })
  }

  _openCardModal(card) {
    const layer = card.querySelector("[data-role='card-modal']")
    if (!layer) return
    layer.hidden = false
    card.querySelector(".split-card")?.classList.add("card-modal-open")
    card.querySelector("[data-role='card-modal-reopen']")?.setAttribute("hidden", "")
    this.overlayTarget.setAttribute("data-card-modal-open", "")
  }

  _closeCardModal({ seen }) {
    this.overlayTarget.removeAttribute("data-card-modal-open")
    this.cardTargets.forEach(card => {
      const layer = card.querySelector("[data-role='card-modal']")
      if (!layer || layer.hidden) return
      layer.hidden = true
      card.querySelector(".split-card")?.classList.remove("card-modal-open")
      if (seen) {
        this._modalSeen.add(card)
        card.querySelector("[data-role='card-modal-reopen']")?.removeAttribute("hidden")
      }
    })
  }

  dismissCardModal() {
    this._closeCardModal({ seen: true })
    this._update()
  }

  reopenCardModal(event) {
    const card = event.currentTarget.closest("[data-preview-verto-target='card']")
    if (card) this._openCardModal(card)
  }

  _stripEditorChrome(clone) {
    // 1. Remove editor-only chrome elements outright. quiz-correct-block /
    //    token-award-block are the creator's Tokenomics/Quiz mode controls
    //    (relocated into the editor's sidebar tabs, or parked off-screen —
    //    either way still present in the editor DOM this clones from) and
    //    must never reach a respondent-facing view.
    clone.querySelectorAll(
      ".pick-item-delete, .tap-card-delete, .pick-add-btn, .tap-add-btn, .add-media-fab, " +
      ".split-left-design-prompt, .quiz-correct-block, .token-award-block, " +
      ".book-edit-tools, .logic-branch-block, .mark-correct, .mark-correct-grid, " +
      ".tap-card-image-btn, .slider-axis-toggle, .add-animation-fab, " +
      // The panel's OTHER creator CTAs. These are not inert decoration: like the
      // 🎨 below, `media-picker` is bound on the editor root — an ancestor of
      // this overlay — so a cloned "Background" or "Reposition" opened the
      // creator's media modal from inside a respondent view, over the top of the
      // preview they were checking. .add-bg-fab covers .card-bg-fab and
      // .media-adjust-fab, which both carry it.
      ".add-bg-fab, .tap-card-adjust-btn, " +
      // …and the empty rail they sat in. It is absolutely positioned over the
      // panel, and its own :not(:has(…)) collapse only fires when every child is
      // hidden rather than gone; removing it outright says what is meant.
      ".split-left-cta-row, " +
      // …and the device frame's stand-in for it beside the phone. It sits
      // outside .split-card, so it only reaches a clone that starts at the
      // wrap — belt and braces, for the same reason as the row itself.
      ".card-media-dock, " +
      // The creator's "Answer length" select under an open-ended card. Worse
      // than chrome: its <select> carries change->survey-editor#markDirty, so
      // changing it while "previewing as a respondent" autosaved a new character
      // limit onto the deck.
      ".freeform-limit-row, " +
      // The two hidden apply paths the animation picker drives. They are
      // `hidden` in the editor and would stay hidden here, but a respondent view
      // has no business carrying the creator's controls at all — and one of them
      // shipped without its `hidden` for a while, which is exactly how a hidden
      // thing becomes a visible one.
      ".range-theme-picker, .nps-shape-picker, " +
      // The NPS scale's own ＋ and ×. `card-editor` is stripped from the clone
      // below, so these would be inert — but an inert × beside every number on
      // a respondent's scale is still a scale that looks like it can be taken
      // apart. The .nps-label-row wrapper STAYS: it is the flex item the column
      // lays its stops out with, on the player as much as here, so removing it
      // would collapse the scale rather than tidy it.
      ".nps-label-delete, .nps-scale-add, " +
      // The intro modal's editor strip — the label, the fold chevron and
      // Remove. The modal itself STAYS: this overlay is "preview as a
      // respondent", and the pop-up over the question is part of what a
      // respondent gets. Turning the replica into the real thing is
      // _playeriseCardModal below.
      ".card-modal-chrome"
    ).forEach(el => el.remove())

    // 1b. The tap card's statement pager is the one piece of editor chrome that
    //     cannot simply be deleted, because it does not SIT BESIDE a
    //     respondent control — it takes one's place. The editor renders the
    //     pager INSTEAD of the reset row (a creator has a deck to walk, a
    //     respondent has answers to take back), so removing it on its own would
    //     hand a previewed tap card no way to start its deck over, which is a
    //     control the player has. Swap, don't strip.
    //
    //     Everything in the list above is additive chrome, which is why a flat
    //     remove has served until now. This is the first replacement, and the
    //     reason it is a separate step rather than another selector in it.
    clone.querySelectorAll(".tap-nav-row").forEach((row) => {
      const holder = document.createElement("template")
      holder.innerHTML = tapResetRowHtml().trim()
      const reset = holder.content.firstElementChild
      reset ? row.replaceWith(reset) : row.remove()
    })

    // 1c. The scenario/consent book's pager is the SAME shape of problem, and it
    //     was the one still on the wrong side of it. The editor's nav row
    //     carries a full-width "Next page ›" button with a separate dot strip
    //     floating above it; the player's is one capsule — ‹ · · · › — with the
    //     dots between the two chevrons ("the owner's pick from the three mocked
    //     treatments"). So a previewed scenario showed a control the player does
    //     not have, in a layout the player does not use, on the card type whose
    //     whole point is how it reads.
    //
    //     Both halves, in order: drop the editor's stray dot strip (the one
    //     OUTSIDE the row), then swap the button for the player's dots + right
    //     chevron. scenario_controller finds both by data-scenario-target, so
    //     the swapped-in pair is the working pager, not a picture of one.
    clone.querySelectorAll(".book-dots").forEach((dots) => {
      if (!dots.closest(".book-nav-row")) dots.remove()
    })
    clone.querySelectorAll(".book-nav-row .next-btn").forEach((btn) => {
      const holder = document.createElement("template")
      holder.innerHTML = `
        <div class="book-dots" data-scenario-target="dots"></div>
        <button type="button" class="book-chevron" data-scenario-target="nextBtn"
                data-action="click->scenario#next"
                aria-label="${escapeAttr(t("editor.scenario.next_page"))}">›</button>`
      btn.replaceWith(...holder.content.children)
    })

    // 1d. The editor's per-answer STYLE and REMOVE controls. `option-style` is
    //     bound on the editor root (surveys/show), which is an ancestor of this
    //     overlay as well, so a cloned 🎨 is not inert decoration — it opens the
    //     creator's colour/icon popover from inside a respondent view.
    //
    //     On a tap card it also breaks answering outright. The popover's real
    //     click target there is the answer MARK itself (see _tap_responses:
    //     "users want to be able to update the icons, and the icon is what they
    //     click"), and option-style#open stops propagation — so a previewed
    //     respondent tapping an answer opened a style popover instead of
    //     choosing it, and the deck never advanced. Hence stripping the action
    //     as well as the buttons: with both gone the row falls back to its own
    //     tap-stack#pick, which is what the player does.
    clone.querySelectorAll(".option-style-btn, .tap-response-delete").forEach(el => el.remove())
    clone.querySelectorAll('[data-action*="option-style#"]').forEach((el) => {
      const kept = (el.getAttribute("data-action") || "")
        .split(/\s+/).filter(a => a && !a.includes("option-style#")).join(" ")
      kept ? el.setAttribute("data-action", kept) : el.removeAttribute("data-action")
      // The hover ring that advertised the mark as a control goes with it.
      el.classList.remove("rotate-action-btn--editable")
    })

    // 1e. …and the row itself goes back to being a BUTTON. _tap_responses renders
    //     a <div> in editor mode and a <button> in player mode, deliberately:
    //     contenteditable inside a button doesn't reliably take a caret, and the
    //     creator has to be able to retype the label. The clone inherited the
    //     div, so a previewed tap answer was a generic element — not focusable,
    //     no aria-label, unreachable by keyboard on the one card type that is
    //     nothing but answer buttons. Clicking it worked, which is why this
    //     survived the earlier passes: the mouse could not tell.
    //
    //     Rebuilt rather than patched with role/tabindex: the player's markup is
    //     a button and the honest way to match it is to be one. Everything else
    //     — classes, the fan's inline --tap-x/--tap-y, the tap-stack data
    //     attributes — moves across untouched, and the accessible name comes
    //     from the label span that is already inside it.
    clone.querySelectorAll("div.rotate-action[data-tap-response]").forEach((row) => {
      const btn = document.createElement("button")
      for (const { name, value } of Array.from(row.attributes)) btn.setAttribute(name, value)
      // After the copy, not before: a `type` carried over from the div would
      // otherwise turn this into a submit button inside whatever form it lands in.
      btn.type = "button"
      btn.setAttribute("aria-label", row.querySelector(".rotate-action-label")?.textContent?.trim() || "")
      btn.append(...row.childNodes)
      row.replaceWith(btn)
    })

    // 2. The "+ Other" CTA is disabled in the editor itself (there the
    //    checkbox above it does the toggling, not the button) — re-enable it
    //    so a "Preview" respondent can actually open the free-text panel.
    clone.querySelectorAll(".other-cta-btn").forEach(el => el.removeAttribute("disabled"))

    // 3. Strip contenteditable from everything so preview is read-only.
    clone.querySelectorAll("[contenteditable]").forEach(el =>
      el.removeAttribute("contenteditable")
    )

    // 3a. An NPS anchors column the creator never filled. The player renders
    //     no column at all for it, and an empty one still costs a stage gap
    //     that shifts the vessel — the class of drift the preview audit exists
    //     to catch.
    clone.querySelectorAll(".nps-anchors").forEach(col => {
      const words = Array.from(col.querySelectorAll(".nps-anchor-text")).some(el => el.textContent.trim())
      if (!words) col.remove()
    })

    // 3b. The intro modal, turned from the creator's editable replica into the
    //     thing a respondent meets: the editor's fold and border classes go,
    //     it starts shut (this overlay opens it on arrival, as the player
    //     does), and its CTA is re-pointed at THIS controller — the real one
    //     names player#dismissCardModal, which nothing here answers to, so
    //     leaving it would put an undismissable pop-up over the card the
    //     creator came to look at.
    this._playeriseCardModal(clone)

    // 4. Drop editor-only marker attributes.
    clone.querySelectorAll("[data-card-component], [data-card-media]").forEach(el => {
      el.removeAttribute("data-card-component")
      el.removeAttribute("data-card-media")
    })

    // 5. Strip the "card-editor" Stimulus controller binding — only
    //    "picker" / "tap-stack" should survive on the preview clone.
    clone.querySelectorAll("[data-controller]").forEach(el => {
      const cleaned = el.getAttribute("data-controller")
        .split(/\s+/).filter(c => c && c !== "card-editor").join(" ")
      el.setAttribute("data-controller", cleaned)
    })

    // 6. Reset interactive state so each open() starts clean.
    clone.querySelectorAll('[data-picker-target="item"]').forEach(el => {
      el.setAttribute("data-selected", "false")
      el.classList.remove("selected", "active")
    })
    clone.querySelectorAll(".rotate-card").forEach(el => {
      // Drop inline transform from mid-swipe state but keep the gradient
      // background that the ERB partial sets via style="background:…".
      const bg = el.style.background || el.style.backgroundImage
      el.removeAttribute("style")
      if (bg) el.style.background = bg
    })
    // A Range card's reaction character tracks its slider (lottie-player#show
    // records the frame it renders), so a clone taken after the creator dragged
    // the editor slider would open mid-expression. Park it back on the neutral
    // middle frame, derived from the set's own length.
    clone.querySelectorAll(".nps-lottie").forEach(el => {
      let frames = 0
      try { frames = (JSON.parse(el.dataset.lottiePlayerUrlsValue || "[]") || []).length } catch (_) { /* leave as-is */ }
      if (frames) el.dataset.lottiePlayerCurrentValue = String(Math.ceil(frames / 2))
    })
    // The clone is deep, so it carries the <svg> lottie-web already rendered
    // into the editor's mount. Empty the mounts so the preview's own
    // lottie-player starts from a bare container and draws exactly one
    // animation rather than stacking a second under the cloned one.
    clone.querySelectorAll(".nps-lottie-mount, .card-lottie-mount")
         .forEach(el => el.replaceChildren())

    // 7. Drop the editor's active-card outline class if present.
    clone.classList.remove("selected")
  }
}
