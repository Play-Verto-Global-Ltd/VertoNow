# Bug log

Bugs found and fixed while hardening the platform, kept because several of them
share a shape worth recognising: **the obvious check said the code was fine.**

Each entry records what broke, how it was found, why the usual check missed it,
and what now stops it coming back. Newest first.

---

## BUG-043 — Every reading landed one card down

**Severity:** every "What the answers tell us" box on every results page
described the question above it — fluent prose citing that question's numbers
under this question's chart. The first question's box stayed empty and the
last question's reading was dropped. The cache replayed the shift on every
visit until the response count moved.
**Found:** the owner, from a screenshot — "the little summaries on the right
panel seem to fall below the question they are referring to."

The layout was the obvious suspect and was fine: the box is a flex sibling
inside its own card, nothing measures or moves it, and the Stimulus controller
fills slots by key. The digest the model reads labels questions `Q#{idx + 1}`
over the whole deck and skips the welcome card at index 0, so the first line
it ever sees is "Q2". The tool then asked for "the question's index, exactly
as given in the digest (Q1 is index 0)" — a zero-based number the prompt never
printed, anchored to a label that wasn't there. Haiku copied the Q number.
`resolve` only range-checked it, and 3 is in range for a deck of twelve, so
the reading of "Q3" — the card the page calls "Card 3" — was filed under "3"
and drawn beside Card 4. The service test fed its fake client already-correct
indices and asserted separately that the prompt said "Q2": each half was
pinned, the translation between them never.

**Fix:** the tool asks for `question`, the number printed on the line, copied;
the service subtracts one and files a reading only against a question it
actually offered — not the welcome card, not a withheld or thin question, not
anything past the deck — and drops anything else rather than clamping or
coercing it. `QuestionInsights::VERSION` is stamped into the cache and required
back from it, so every row written under the old numbering is a miss on its
next visit rather than a replay. A card save now clears the column too: the
readings are keyed by position and the cache was keyed by count alone.

**Guard:** `test/services/question_insights_test.rb` — a client that reads the
digest it was handed and copies the number off the "Would you come back?"
line, asserting that number is 3 and the reading lands under "2"; plus the
welcome card, a thin question, a string and the deck size offered as Q numbers.
`test/integration/question_insights_test.rb` — a cache without the current
version is read afresh, and a deck save clears the readings.

**Lesson:** when the prompt prints one numbering and the tool asks for another
of the same thing, the model copies the prompt. Ask it to copy what was printed
and translate in code. And a cache that doesn't carry the version of the code
that wrote it keeps a fix from ever reaching the rows already written — the
count that keyed it had no reason to move.

---

## BUG-042 — An undo that covered nine gestures and greyed out after the rest

**Severity:** the editor's Undo sat disabled after most edits, and a ⌘Z pressed
after one of them undid an earlier structural change instead of the edit just
made.
**Found:** the owner, editing — "when you make a change it's often greyed out;
it should work like undo in Word, every change is undoable."

BUG-014 fixed the asymmetry between delete and add by making every
*structural* gesture push an inverse. That left the stack operation-based,
with nine call sites, and everything else — typing, options, NPS stops, tap
statements, the answer type, the fifteen per-card switches, flow renames and
exits, routing, media, ✨ Optimise, a "recently deleted" restore — marking the
deck dirty and pushing nothing. The button read the stack's length, so it was
right about the stack and wrong about the deck. The design comment gave two
reasons: `serialize()` reads live DOM and there is no render-from-JSON path,
so a snapshot couldn't be put back; and text is better left to the browser.
The second is BUG-014's own lesson left unfinished: a stack that owns some
changes silently misattributes the next keystroke.

**Fix:** a snapshot history hooked at `markDirty()`, the one call every deck
change already makes, so coverage is automatic — including for controllers the
change never touched and the next one written. Per card, a snapshot is the
`serialize()` JSON (content identity: selection, pulses and renumbering are
not changes), the outerHTML (what to restore), its relocated quiz/token/logic
blocks and its translation-store entry; plus the flows array and the title.
The "no render path" objection is answered by keeping element identity: a card
is restored by morphing its own element, so the Maps keyed on it survive, and
a deleted card comes back as the same detached node. Typing coalesces per pause
(700 ms) or per move to another field; every other gesture is one entry; the
one gesture that spans an await (a flow from a route) holds the stack open.
Redo is the same entry applied the other way, with a button beside Undo. ⌘Z
inside a deck field belongs to the history now; fields outside the deck (the
consent gate, the settings panels) keep the browser's. Optimise morphs in
place too, which also fixes the panel's `activeCardEl` pointing at a detached
node afterwards.

**Guard:** `test/system/editor_undo_test.rb`, seventeen tests: typing (with
redo, grouping and persistence), an option, the answer type, a switch, a flow
rename, the Verto's name and theme, a translation tab, an optimise replace, the
consent-gate exception, the live guard, and BUG-014's structural cases.

**Lesson:** an operation stack is only as complete as its call sites, and the
next feature never knows it owes one. Hook the choke point instead — and if a
history is worth having, it is worth having for everything, or it lies.

---

## BUG-041 — The save warning named no card, and the log said nothing

**BUG-041 — "Saved, but an image didn't stick" pointed at the wrong image.** A
creator uploaded a picture, saw that sentence in the status pill, and found the
picture on the Verto anyway — so was anything wrong? The upload had saved fine.
The warning was `sanitize_cards_images!` dropping an image on ANOTHER card: an
old inline upload over the byte cap, or a brand-library asset stored without an
extension — decks that predate both fixes still exist, and the production
backfills that would have converted them (`card_images:backfill`,
`brand_assets:fix_filenames`) have never been run. The editor rebuilds every
card from the DOM and never reads the deck back from a save, so the refused
picture stayed on screen looking saved and was re-sent, re-dropped and
re-warned about on every autosave until a reload. The pill said "an image", not
which; the server logged nothing; there was nothing to trace afterwards.

Now `sanitize_cards_images!` collects a detail per media drop (card cid, slot,
and the SHAPE of the rejected value — type and size, never the payload),
`#update` returns them as `warning_details` beside the codes and writes one log
line per drop, and the editor names the card ("the image on card 3 didn't
stick") and takes the refused picture off the page through the media picker's
own writer, so the next autosave sends what the server holds and says "Saved".

Why the usual check missed it: `SurveysUpdateTest` proved the warning fired for
a bad image, and `SaveWarningMessageTest` proved the sentence matched the code.
Both were right; neither asked whether the sentence could be acted on.

---

## BUG-033 to BUG-040 — What a second pair of eyes found

Eight defects from five independent adversarial reviews of the day's ~20
commits, each verified first-hand before being fixed. The theme across them:
**a fix that is right about its own case and wrong about the case next door.**

**BUG-033 — going offline burned the submit queue's retry budget.** The service
worker's drain loop counted every failed replay against `MAX_QUEUE_ATTEMPTS`,
including replays that failed because the device had no network at all — the
one situation the queue exists for. A phone that spent a day offline could
arrive at attempt 25 with the answer never having reached the network once,
and the queue then deleted it. The drain now skips the attempt bookkeeping
entirely when `navigator.onLine === false`: no network, no verdict, no charge.

**BUG-034 — the hoisted consent gate kept its flow routing.** `hoist_consent_gate`
moved the gate to the front of the deck but left `flow_id`, `next` and
`lane_label` on it. FlowCompiler chains flow members in deck order, so a gate
that had been sitting inside a flow arrived at the front still claiming
membership — splicing the gate into the flow's chain and skipping the question
the route pointed at. The hoist now strips all three and pushes a
`consent_gate_moved` warning through the same channel image rejections use.
The editor's ▼ on the gate is also disabled next to a question, so the creator
is never shown an order the save would silently revert.

**BUG-035 — a declined consent wasn't terminal.** Declining purges the
response's answers, but the endpoints happily kept accepting progress and
submits for that session afterwards — so a purge meant to be a data-protection
event was just a pause. Decline is now a terminal state: progress, submit and
grade all refuse the session with a 403 until the respondent explicitly
re-agrees (which clears `consent_declined_at`). The consent endpoint also
gained its own rate limit, and response lookup is scoped to the survey, so a
token from one Verto can't open a row on another.

**BUG-036 — every server fault on the public write path reported as the
client's fault.** `progress`/`submit`/`grade` wrapped everything in
`rescue => e` → 422. The service worker treats 4xx as permanent and deletes
the queued submit — so a transient server bug threw away a respondent's
answers instead of retrying them. The rescue is now split: malformed JSON is
400, a cross-survey token is 403, and anything unexpected is a 500, which the
queue retries. Same class of loss, opposite direction from BUG-033.

**BUG-037 — a declined consent posted offline was fire-and-forget.** The
service worker queued `/submit` POSTs but let `/consent` fall through to the
network, so a decline (or an agree) made offline vanished. Both now go through
the same IndexedDB queue. CACHE_VERSION bumped to v26.

**BUG-038 — purging answers didn't tell the results dashboard.** The
results broadcast fired only for responses currently counted as answered, so
the decline-purge — an answered→unanswered transition — updated nothing: a
creator watching the dashboard kept seeing a response that no longer existed.
The broadcast now also fires when `answered` *changes*, either direction.

**BUG-039 — blanking one range label slid the others onto the wrong stops.**
`_liveOptions` filtered blank labels for every card type, but a range label is
a positional stop — blank means "unnamed stop", not "one fewer option". Reapply
the type with a blanked label and the rebuild got 4 labels, which the
upsampler re-spread across 5 stops, moving words the creator had placed and
autosaving the shuffle. Range now keeps blanks positionally, mirroring
`serialize()`'s own rule.

**BUG-040 — duplicating a card dropped its translations.** The BUG-030 shape
on yet another path: `_spliceCard` posted the card JSON (i18n and all) to
`render_card` but spliced the returned HTML without seeding the translation
store, so the duplicate's first autosave wrote it back monolingual. The splice
now passes the JSON through to `seedCardStore` — and the restore-deleted-card
path, which had the same gap, was fixed the same way.

Smaller findings fixed in the same pass: `#optimise_card` losing a card's
description when the optimiser returned none; flow-undo entries going stale
when the flow was deleted before ⌘Z; two undo browser tests that passed with
their guard deleted (empty stacks — they now plant a stack entry and refute it
fires); the BUG-030 server contract itself untested (an integration test now
pins `card:` in the generate response); the welcome-email test not naming the
mailer it asserted; and the previous-keys initializer now calls
`reset_column_information`, so encrypted columns pick up appended keys
regardless of load order.

How they were found is the entry's real lesson: five reviewers were told to
distrust every comment and commit message and to read only the code. Every
finding above sat in code whose comments correctly described what the code was
*supposed* to do.

---

## BUG-029 to BUG-032 — The last four from the hunt

**BUG-029 — a removed consent gate came back on its own.** The gate's inline
editor saves on a 900ms debounce, and the timer's closure read the element when
it FIRED rather than when it was queued. `removeConsent` resets that same element
to its default copy before saving an empty one — so typing a word and then
clicking ✕ Remove inside the debounce window let the pending timer land
afterwards with the DEFAULT consent text, putting a live consent gate back on a
Verto the creator had just taken it off. Nothing on screen said so: the card was
hidden and the CTA was back.

Fixed twice over — the text is captured at queue time, and every add/remove
cancels the pending timer first.

**BUG-030 — generated cards discarded translations that had just been paid
for.** `#generate_card` calls `translate_card!`, which bills one Claude call per
secondary locale, and returned `{ ok: true, html: }` — the i18n map computed and
thrown away. The editor could not have recovered it: `_seedStore()` reads a blob
rendered into the page, so it only knows the deck as it was at page load. A card
added afterwards had no store entry, `_captureLocale` filled one from the
language on screen, and the next autosave wrote the card back monolingual. The
endpoints now return the card JSON and `seedCardStore` teaches the store about
it; the flow-generation path had the same gap and the same fix.

**BUG-031 — a Prioritise card created from "Add question" arrived with no
options.** `add_question_controller` carried its own `DEFAULT_OPTIONS`, under a
comment claiming to mirror `type_panel_controller`'s. It was missing `nps` and
`prioritise`, so the modal showed no option rows and `_collectCard` emitted no
`options`.

**BUG-032 — the compare view built an empty block for a consent gate.**
`results_compare_controller`'s `SKIP_TYPES` was a hand-copy of
`NON_QUESTION_TYPES` that predated `consent_gate`.

**The two of those share a cause worth naming.** `NON_QUESTION_TYPES` was
written out by hand in **four** JS files; three stayed in step and the fourth
did not. `DEFAULT_OPTIONS` existed twice and the second copy was short two
entries. Both are single modules now (`lib/question_types.js`,
`lib/default_options.js`) and the parity test asserts not just that they match
Ruby but that **nobody re-declares them** — because the previous guard compared
three named files and could not see the fourth copy, which was spelled
`SKIP_TYPES` and lived somewhere it was not looking.

That guard, `card_types_test.rb`, was itself the third one this week that was
shaped like the bug it was written for rather than like the rule.

---

## BUG-028 — Declining consent kept the data anyway

**Severity:** the platform collected and published data from people who had
explicitly refused to give it.
**Found:** the boundary hunt. Fixed to the owner's decision, not mine — this one
was a policy question, not a defect with one right answer.

A consent gate is an ordinary deck card, so it could sit at position four, and
`/progress` persists answers on every advance. By the time a respondent read the
sheet and tapped "No thanks", their earlier answers were already stored, already
counted as a responder, and already feeding the creator's results and the public
`/results` and `/regions` aggregates. `#consent` stamped `consent_declined_at`
and touched nothing else. The creator's respondent-data screen renders only
"agreed"/"none", so a declined respondent looked like someone who had never been
asked — while their answers sat in the table.

**Decided and built:**

* **Declining purges.** `answers` is cleared, and so are the denormalised
  `region_*` / `demographic_*` / score / token / respondent-code columns —
  those are copies of the answers, and clearing only the JSON would leave the
  personal data behind in its own columns. The row survives:
  `consent_declined_at` plus the wording they were shown is the evidence the
  decline was honoured, and the decline rate is worth knowing. Clearing
  `answers` drops `answered` to false via `sync_answered`, which is what removes
  it from every responder-scoped view.
* **The gate is hoisted ahead of the first question on save**, so the situation
  cannot arise on any deck built from now on. Not to index 0: non-question cards
  may still precede it, because a welcome card captures nothing and "Hello →
  consent → questions" is the better flow. The rule is *before any QUESTION*.
  Safe to reorder there because `#update` refuses any edit to a Verto that is
  published or has responses, so a deck reaching the sanitiser has no stored
  answers to misalign — and answers are keyed by card index.
* **The client drops its own copy too**, so an unload flush or a queued submit
  can't re-upload what the server just purged.

**A regression I introduced and caught mid-change:** the new whole-answer
`_isAnswered(ans)` silently **shadowed** an existing `_isAnswered(value)` further
down the same class. Its two callers pass a bare value, which the new one reads
as "not an object" and reports unanswered — so `_saveProgress` would have
stopped saving and the required-question guard would have stopped guarding.
JavaScript takes the later definition without a word. The two are now one method
(`_isAnswerGiven`), which is what should have happened first: `_isCardAnswered`
had already reimplemented the `other` clause by hand, so the codebase held the
right rule in a place `_applyTokenEarn` never looked.

**Guard:** `test/integration/consent_decline_purge_test.rb` — nine tests
covering the purge, what survives it, the public aggregates, the hoist and its
three edge cases, plus the negative case that agreeing changes nothing.

---

## BUG-024 to BUG-027 — Four ways a respondent's work went missing

A batch from the boundary hunt, all respondent-facing, all confirmed by three
independent refuters before being touched.

**BUG-024 — the client and the server disagreed about what "answered" means.**
`PlayerController#answered?` decides what a later submit may not overwrite;
`_isBlankAnswer` in the player decided whether a token-awarding card locks. They
disagreed twice, and both ways round cost the respondent:

* an **"Other"-only** answer — the client read `.value` and never looked at
  `.other`, so it left the card unlocked and awarded nothing while the server
  called it answered and locked it. The respondent believed they could still
  come back; their correction was discarded and the points went with it.
* an **empty Hash** — a grid or tap card with nothing picked. The server called
  that answered and locked a card the respondent had *skipped*. Here the client
  was right, so the rule moved on the server.

**BUG-025 — a response answered only via "Other" was recorded as unanswered.**
`Response#content_answered?` checked `value.present?`, which is false for an
Other-only answer *and* for a boolean `false`. That flag drives every
responder-scoped view, so real completed responses were silently uncounted.

The rule now exists **once**, as `Response.answered_entry?`. It had three
implementations and all three disagreed; the controller delegates and the JS
mirrors it.

**BUG-026 — deleting a tap-card statement shifted every picture onto the wrong
one.** `option_images` are positional and `serialize()` bounds the array by
truncating its **tail**, so removing statement 1 of 5 left images 1–4 against
statements 2–5. Nothing looked wrong at the time — the backgrounds are inline on
the surviving nodes — so it only appeared after a reload, by which point the
deck had been saved.

**BUG-027 — quiz grading had no failure path.** `_gradeRemote` returned bare
`null` for everything, and the caller silently returned on a falsy result. When
the Verto closed mid-quiz or the signal dropped, "Check answer" did *nothing*:
no error, no hint, a button that looked broken and a respondent who could not
move on. The line's own comment said "couldn't grade — allow a retry", which was
true and useless — the retry was permitted but never suggested.

**Guards.** `test/system/answer_parity_test.rb` is the one worth copying: it
drives the SAME table of seventeen answer shapes through both implementations
and asserts they agree case by case, rather than asserting each is separately
correct. That is the assertion that would have caught BUG-024, and it names the
exact disagreeing case when it fails. Alongside it,
`test/integration/answered_locking_test.rb`,
`test/system/tap_card_images_test.rb` and
`test/system/quiz_grade_failure_test.rb` — every one checked against a
deliberately broken build.

**Two fixtures that were quietly proving nothing**, both caught that way:

* the empty-grid locking test used a plain grid card, but `locked_merge` only
  protects *graded or token-awarding* cards — so it passed whichever rule was in
  force. The card now awards tokens.
* the quiz-failure tests set `currentValue` without calling `_update()`, so the
  card was never displayed and its error note could not be visible. Capybara
  reported the element as present-but-not-visible, which is the tell.

---

## BUG-021, 022, 023 — Three ways the editor discarded work you could see on screen

All three share the shape this log keeps returning to: the DOM is the editor's
source of truth, and each of these trusted something else instead.

**BUG-021 — re-applying a type reverted every option edit of the session.**
`_optionsFor` / `_pagesFor` rebuilt a card from `data-card-options` and
`data-card-pages`. The server writes those once, at page render, and nothing
ever updated them — so re-applying a type restored the labels the card had when
the page loaded, and the autosave a type change triggers then persisted the
revert. Both now prefer what is on screen (the same nodes `serialize()` reads),
falling back to the snapshot only when the card currently has no options at all
— which is the switch-away-and-back case the snapshot exists for. `serialize()`
also refreshes the snapshot now, so that memory means "last saved" instead of
"as first rendered".

**BUG-022 — the editor let you write a page the server would throw away.**
`Survey::MAX_SCENARIO_PAGES` (6) had no JS counterpart, so `＋ Add page` kept
going. The sanitiser keeps `.first(6)`, so a seventh page was written, saved,
reported as saved, and gone on reload. `lib/page_limits.js` mirrors both bounds
now; the button greys out at the cap and refuses past it. The parity test also
asserts the Rules-of-the-Game thresholds stay *stricter* than the hard caps (5
pages / 400 chars against 6 / 600), so a creator is nudged well before anything
is discarded.

**BUG-023 — deleting a narrative page never saved.** `addPage`/`deletePage`
dispatch `scenario:changed`; the editor root listened for `type-panel:changed`
and `card-editor:changed` and not that one. Adding usually survived by accident
— typing into the new page fires `input`, which the root does listen to. Deleting
had no such accident: the page vanished, nothing marked the editor dirty, and it
came back on reload. One missing action in the root's `data-action`.

**Guards:** `test/system/type_reapply_test.rb` and
`test/system/scenario_pages_test.rb`. Six of their seven tests fail against the
unfixed build. Two test-authoring notes worth keeping:

* the re-apply tests originally called `_applyToCard` directly, which skips the
  `markDirty` the real gesture causes — so the "and the revert is not then
  autosaved" test passed whether or not the bug existed. They now go through
  `applyType`, the public entry point.
* the add-page test first asserted on the last page in the DOM. `addPage`
  inserts after the page currently open, not at the end, so it was editing an
  existing page and measuring nothing.

`CACHE_VERSION` bumped to v22 — `scenario_controller.js` drives the player's
page turns, not just the editor's.

---

## BUG-020 — A closed Verto told respondents their answers were saved

**Severity:** silent, permanent loss of a respondent's completed response —
with an affirmative message saying the opposite.
**Found:** the boundary bug hunt; confirmed by three independent refuters.

The player HTML is served stale-while-revalidate, so a respondent can be part
way through a Verto that the creator has since unpublished or closed. On submit
the server correctly returns **410 Gone**. The service worker then did:

```js
const res = await fetch(req)
if (!res.ok) throw new Error(...)   // ← a 410 is not an outage
```

which fell into the offline branch: the answers went into IndexedDB and the page
got a synthesised `202 {ok: true, queued: true}`. The respondent was shown
**"Saved — will sync when you're back online."** Nothing was saved and nothing
ever would be — `drainQueue` deleted an item only on `res.ok`, so the 410 was
retried on every same-origin GET for the life of the browser profile.

The player could not have told the difference either: `if (!res.ok) throw` sent
a refusal and a network failure to the same `catch`, whose only question was
`navigator.onLine`.

**Fix, both halves:**
* the worker queues only when no response arrived at all, or the server asked to
  be retried (429/5xx). A 4xx is passed to the page unchanged. `drainQueue`
  drops an item on any non-retryable status, and gives up after
  `MAX_QUEUE_ATTEMPTS` so a submit that can never land stops costing battery on
  every page view;
* the player distinguishes *refused* from *queued* and says so, in all 19
  locales.

**Guard:** `test/system/submit_rejected_test.rb`, including the negative case —
a successful submit must show **no** pill, or an unconditional one would pass
every other assertion while telling every respondent their answers were lost.

`CACHE_VERSION` bumped to v21: without it no returning respondent would get the
fixed worker, which is the whole point of the rule.

---

## BUG-019 — An edit made during a save was marked clean by that save

**Severity:** silent loss of a creator's edit.
**Found:** the boundary bug hunt.

`_doSave` cleared `_dirty` *after* awaiting its response, so an edit typed while
a save was in flight — which `markDirty` had correctly flagged — was marked
clean by a request that did not contain it.

On its own that only delays the edit: `markDirty` re-arms the 1.5s timer. The
loss needs the page to go away inside that window, and `flushSave`, the
pagehide/visibilitychange safety net, opens with `if (!this._dirty) return`.
Typing something and immediately switching tabs is an ordinary thing to do.

**Fix:** a generation counter. `markDirty` bumps it; `_doSave` snapshots it
before serializing and only clears `_dirty` if it hasn't moved.

**Guard:** `test/system/autosave_race_test.rb` holds the PATCH open from the
test rather than sleeping, so "while the save is in flight" is a state under
control rather than a window being raced — a timing-dependent version would
pass on a fast machine either way. The second test cancels the re-armed timer
before flushing: without that it passed against the unfixed build, because the
ordinary debounced save landed the edit and `flushSave` was never the thing
being tested.

---

## BUG-018 — "✨ Optimise" destroyed eleven fields on the card it improved

**Severity:** data loss on a single click, including the card's identity.
**Found:** the same hunt, then confirmed by reconstructing the payload.

The editor sent one card to be rewritten as:

```js
card: { type: card.dataset.cardType, ...this._readCard(card) }
```

`_readCard` returns four keys. The server merges the AI's rewrite **onto**
whatever it is given and re-renders the card from the result, so everything
absent from that payload was absent from the card afterwards:

```
stored card : cid common_question_id common_question_set_id competency
              condition correct flow_id image logic options outcome required
              text tokens type
after       : options outcome pages text type
LOST        : cid common_question_id common_question_set_id competency
              condition correct flow_id image logic required tokens
```

The `cid` matters most: other cards' logic routes point **at** it, so
optimising a card silently orphaned every branch that led to it.

The server's own comment claimed *"competency/condition ride along from the
original card untouched"* — describing an intent the client made impossible, the
same way BUG-013's guard described protection it wasn't providing.

**Fix:** send `this.serialize().cards[idx]` — the card's complete current
object, and the same idiom `flows#duplicateCard` already uses.

**Guard:** `test/system/optimise_card_test.rb` asserts on the payload itself,
because the payload *is* the defect; it fails against the old shape. Its fixture
turns quiz and tokenisation **on**, because `serialize()` only emits `correct`
and `tokens` when they are — with them off the test would have passed while
proving less than it claimed.

**Lesson:** "merge the improvement onto the original" is only safe when the
original is the original. Here one side said merge and the other sent a
summary — and each side, read alone, looked right.

---

## BUG-017 — Every autosave stripped the framework tags off every card

**Severity:** silent, permanent loss of the provenance the "Why this card?"
panel exists to show — on cards the creator never touched.
**Found:** a bug hunt aimed specifically at the BUG-015 shape.

`SurveyGenerator` tags each generated card with the Awareness/Intention/Agency
competency it sits under, its enabling condition and a plain-language outcome.
`_card_row.html.erb:40-42` carries all three into the DOM, the editor renders
them in the Why panel, and `sanitize_cards_images!` preserves them perfectly.

`serialize()` never read them back. It rebuilds each card as `const out = { type }`
and adds only the keys it knows about, so the first autosave posted every card
without them and the panel emptied for the whole deck.

Proven by round trip rather than by reading:

```
sanitiser keeps competency? true  condition? true  outcome? true
after an editor round trip: ["cid", "options", "text", "type"]
```

**Fix:** carried through from `data-card-competency` / `-condition` / `-outcome`,
the way `common_question_id` and `range_theme` already are.

**And the half that came with it:** carrying a field from the client means the
server starts receiving it on a PATCH. `SurveyGenerator#normalize_framework!`
allowlists competency and condition, but that runs on *generation* — not on
save. Before this, a crafted PATCH could put any string in the Why panel and a
5,000-character outcome in the column. The sanitiser now applies the same
allowlist, and caps `outcome` (free text by design) at `MAX_OUTCOME_LENGTH`.

**Guard:** `test/system/framework_tags_test.rb`. The regression test edits a
*different* card, because that is the property that matters — `serialize()`
rebuilds the whole deck, so a gap in it destroys data on cards nobody opened.
Both round-trip tests fail against the unfixed build.

**Lesson:** every "carry this through" line in `serialize()` exists because
something was once lost. The list is not a feature list, it is a scar list —
and anything the DOM carries but `serialize()` omits is already lost.

---

## BUG-016 — The guard written for BUG-015 was shaped like BUG-015

**Severity:** one more blanked card type, and a test that read as coverage.
**Found:** the same hunt, immediately.

`token_checkpoint` is `pickable: true` whenever tokenisation is on and had no
entry in the type panel's `COMPONENTS` table, which falls back to `() => ""`.
Picking "Points Checkpoint" therefore emptied the card — the identical defect to
consent_gate, in the only other type that had it.

The parity test shipped with BUG-015 asserted *every paged type has a builder*.
That is the property the bug happened to have, not the rule. It passed the whole
time `token_checkpoint` was missing.

The same test banned `type === "scenario"` across a hand-written list of the two
files that had just been fixed — and so missed `lib/verto_rules.js`, which still
had it.

**Fix:** the table check now covers every **pickable** type, and the literal ban
scans every JS file under `app/javascript` (comments stripped, since
`paged_types.js` documents the banned pattern by quoting it).

**Lesson:** a guard written immediately after a bug tends to encode that bug's
incidental properties rather than the rule it violated. Ask what the rule is,
then check where else it could be broken — not where it *was* broken.

---

## BUG-015 — A consent gate that recorded no consent

**Severity:** the highest in this log. A compliance feature that blocked
respondents, showed them a blank screen, and stored no record of what they
agreed to.
**Found:** by an adversarial pass over items the backlog audit had called
*done*. The first auditor read the model, the migration, the player and 231
lines of green tests and concluded the feature shipped. It had not.

`consent_gate` joined `Survey::PAGED_TYPES` on the server. The editor's
`serialize()` still said:

```js
const primPages = type === "scenario" ? … : []
```

`serialize()` rebuilds every card from live DOM on **every** save and PATCHes
the whole deck, so a consent gate always arrived with no `pages`, and the
sanitiser's `Array(nil)` rewrote them to `[]`. Confirmed by running the exact
payload the editor emits through the sanitiser:

```
pages after a round-trip   : []
consent_gate_card?         : true
consent_gated?             : true
consent_snapshot_text      : nil
```

The gate goes on blocking respondents — with nothing on the screen — and
`Response#consent_text_snapshot` records nothing. Because autosave fires 1.5s
after *any* edit, editing an unrelated card destroyed the consent copy.
Translated pages died with it, on the same gate.

A second omission sat next to it: the type panel's `COMPONENTS` table had no
`consent_gate` entry, and the lookup falls back to `() => ""`, so picking
"Consent screens" blanked the card. `welcome_card` is listed explicitly as
`() => ""`, which is what shows the empty fallback here was an oversight rather
than a decision.

**Why every test passed:** `consent_gate_card_test.rb` calls the sanitiser with
pages already supplied and renders from cards seeded via `create!`. Its only
PATCH test asserts `:locked`. No test made a round trip through the editor, and
there is no JS test runner, so nothing in the suite could see `serialize()`.

**Fix:** `app/javascript/lib/paged_types.js` mirrors `Survey::PAGED_TYPES`, and
the four places that hardcoded `"scenario"` now ask `isPaged(type)`. Added the
missing `consent_gate` component builder.

**Guards:** `test/system/consent_gate_editor_test.rb` drives a real editor
round trip — three of its four tests fail against the unfixed build, including
the snapshot one. `test/lib/js_constant_parity_test.rb` asserts the JS and Ruby
lists agree, that every paged type has a component builder, and that neither
file gates on the literal `"scenario"` again. It checks `ROUTABLE_TYPES` against
`LogicGraph::ROUTABLE` too — same mirroring, same latent drift.

**Lesson:** two constants kept in step by a comment that says "keep in
lock-step" are not kept in step. And a feature is not shipped because its model
and its player agree — the editor has to be able to author it.

---

## BUG-014 — An undo stack that undid the wrong action

**Severity:** ⌘Z silently reverted an edit the creator had finished with, while
leaving the one they meant to undo in place.
**Found:** auditing the backlog against the code rather than against the plan.

`recordCardDeletion` and the reorder handlers pushed inverse operations. Adding
a card pushed **nothing** — so the stack was asymmetric, and the next ⌘Z popped
whatever delete or reorder happened *before* the add.

The test makes the shape unmistakable. Delete card 2, add a new card, press ⌘Z.
Expected three cards; the unfixed build gives **five** — the deleted card is
back and the added one is still there. Two wrong outcomes from one keystroke.

**Fix:** `recordCardInsertion` as the mirror of `recordCardDeletion`, wired into
all four insertion gestures (add-question modal, duplicate, add-card-to-flow,
and the flow-panel starter card). Flow creation gets `recordFlowCreation`
instead: that gesture mints a flow *and* several cards, so a per-card inverse
would let ⌘Z strand a flow holding fewer cards than it was built with. One
gesture, one undo entry.

**Guard:** `test/system/editor_undo_test.rb`, five tests, verified against a
build with `recordCardInsertion` disabled — which is how the five-card result
above was produced.

**Also found while writing it:** the "Add consent gate" CTA wears the same
`aq-insert-btn` class as the per-card "Add question" CTA and sits earlier in the
DOM, so the obvious selector adds a consent gate instead. Not a user-facing bug
— they have distinct `data-action`s and sit in different places on screen — but
worth knowing before writing another editor test.

**Lesson:** an incomplete undo stack is not a partial feature, it is a wrong
one. Every operation that mutates the structure has to push, or the stack
silently misattributes the next keystroke.

---

## BUG-013 — A blank rename erased a Verto's name, past a guard written to stop it

**Severity:** a stray select-all-delete in the editor wiped the Verto's name,
and the autosave persisted it 1.5 s later with no confirmation.
**Found:** P2-5, on the first run of the editor browser suite.

The editor had a guard for exactly this. On `blur`:

```js
restoreRenameIfBlank() {
  if (el.textContent.trim()) return
  el.textContent = this.titleValue      // ← already blank by now
}
```

The `input` handler fires first and does `this.titleValue = next` with `next`
being the empty string, so the blur guard restored the blank **over the blank**.
It read the one value the bug had already destroyed. The server took whatever
it was sent — `attrs[:title] = payload["title"] if payload.key?("title")` — so
nothing else stood in the way.

**Fix:** `renameVerto` now bails on a blank instead of storing it, which both
keeps blanks out of the payload and leaves the blur guard something real to
restore. The server independently drops a blank title, and strips the one it
does keep.

**Guard:** the browser test that found it, plus two integration tests over the
server half — one asserting three flavours of blank are ignored, one asserting a
padded-but-real name still renames, so the fix can't over-correct into refusing
legitimate titles. Both were verified to fail against the unfixed controller.

**Lesson:** the same shape as BUG-008 and BUG-003 — a guard that reads state the
bug has already corrupted is not a guard. No unit test would have caught it
either: the defect lives in the *ordering* of two DOM event handlers, which is
only observable in a browser. It sat in code that shipped with a comment
explaining the protection it wasn't providing.

---

## BUG-012 — A key added after the translation payload was dispatched

**Severity:** three locales would have rendered a raw dot path.
**Found:** P2-2, by a parity check over the locales that had landed.

Fixing BUG-011 created `flash.surveys.image_unverified` — a key that did not
exist when the six translator agents received their payload. Three of them
(de, it, nl) therefore had no translation for it; three others picked it up
only because they had been told to read `en.yml` first to match its style,
which was luck rather than design.

**Fix:** backfilled by hand into every locale, with a guard in the backfill
script that refuses to touch a file whose `flash` section has not been written
yet, so it can be re-run safely as the remaining locales land.

**Lesson:** a fan-out's input is frozen at dispatch. Any key added after that
point is invisible to it, and the only thing that catches the gap is a parity
check run afterwards over the union of what exists — not over what was sent.

---

## BUG-011 — A class-body constant can't hold a translation, and dev never notices

**Severity:** would have failed the production deploy at boot.
**Found:** P2-2, by force-loading the controller after a scripted edit.
**Fixed in:** `b7a5f03`

The extraction that moved controller flash copy into i18n keys rewrote two
class-body constants:

```ruby
EDITING_LOCKED_MESSAGE = t("flash.surveys.editing_locked")
```

`t` is not defined in a class body. `bin/rails runner 'puts "boot ok"'` printed
**boot ok**, because development does not eager-load controllers, so the constant
was never evaluated. `Rails.application.eager_load!` — what production actually
does at startup — raised `NoMethodError: undefined method 't' for class
SurveysController`. The app would not have started.

A second bug was hiding behind the first: even if `t` had resolved, a constant is
evaluated **once at boot**, pinning every creator to whichever locale happened to
be active then. That is the exact behaviour the change existed to remove.

**Fix:** all three message constants became methods
(`editing_locked_message`, `settings_locked_message`,
`could_not_verify_image_message`). The third was still hardcoded English and
gained a key of its own.

**Guard:** `Rails.application.eager_load!` is now run as an explicit gate
alongside the usual four before pushing. `bin/rails runner` is not evidence that
the app boots.

---

## BUG-010 — Stashing files that concurrently running agents are writing

**Severity:** produced a pushed commit whose message misdescribes its contents.
**Found:** P2-2, by reading `git show --stat` after the push.

To commit the English extraction cleanly I ran `git stash push` on three locale
files, committed, then popped. Background translator agents wrote to those same
files during that window, so `git add -A` swept up four locales (fr, de, it, nl)
that the commit message says are not there.

The code is correct; the description is not. History was not rewritten — the
follow-up commit corrects the record instead.

**Fix / lesson:** do not use the working tree as scratch space while background
agents hold it. Either wait for them, or have the agents return data instead of
writing files. The rest of that workflow did the latter deliberately, and only
the translation phase — chosen for file-disjointness — wrote directly.

---

## BUG-009 — A browser test that passed with the feature disabled

**Severity:** the test proved nothing it claimed to.
**Found:** P2-5, by deliberately breaking the feature and re-running.
**Fixed in:** `d87b2a8`

The first system tests for keyboard selection passed with
`picker#pickOnKey` removed. Cuprite's `Element#send_keys` **clicks** the element
to focus it first, so the click handler did the work and "selected with the
keyboard alone" was asserting nothing.

**Fix:** focus through the DOM (`element.focus()`), then deliver the key with the
CDP keyboard, so no pointer is involved. Disabling the handlers now fails all
three tests.

**Guard:** every test in that file was re-checked against a deliberately broken
build before being trusted.

---

## BUG-008 — A "is this controller rate limited?" matcher that returned true for everything

**Severity:** a security guard that guarded nothing.
**Found:** P1-12, by running the matcher against controllers known to have no limit.
**Fixed in:** `4e7f20b`

The first matcher looked for any `before_action` lambda originating in
`action_controller`, and so reported **true for every controller inheriting
`ApplicationController`** — including `LegalController` and
`OrganisationsController`, which have no rate limits at all.

**Fix:** match only lambdas defined in
`action_controller/metal/rate_limiting.rb`.

**Guard:** a test asserts the matcher still reports **zero** for those two
controllers, so it cannot rot back into a tautology.

---

## BUG-007 — Two unauthenticated password oracles

**Severity:** brute-force against any account, unthrottled.
**Found:** P1-12, by auditing every call site of `User.authenticate_by` rather
than only the ones the plan named.
**Fixed in:** `4e7f20b`

`InvitesController#accept` and `FunderInviteAcceptancesController#accept` both
verify a password using an email taken from the **form**, not the invite, and
neither had any rate limit. Anyone holding an invite link could test passwords
against any address in the system.

**Fix:** both bounded per IP. Per-address was deliberately not used there — the
action multiplexes several flows, and keying on a blank address would throttle
legitimate signed-in joins.

---

## BUG-006 — A time-window test that flaked

**Severity:** a flaky test is worse than no test.
**Found:** P1-11, by a single failure in one full-suite run that two later runs
did not reproduce.
**Fixed in:** `76568f1`

`SharedRateLimiter` keys its budget on `Time.now.to_i`. Calls straddling a
second boundary got a fresh window, so "the next call must be refused" failed
intermittently.

**Fix:** the budget tests freeze the clock with `travel_to`. What is under test
is the counting, not the wall clock.

---

## BUG-005 — A foreign key that would have broken organisation deletion

**Severity:** would have started raising on a normal user action.
**Found:** P1-9, by asking what the new constraint makes *fail* rather than only
what it prevents.
**Fixed in:** `c272974`

`CommonQuestionSet` had no `has_many :partnership_common_question_sets`, so
deleting a set left its share rows behind. Harmless while the column was
unconstrained; with a foreign key it becomes an aborted destroy — and
`Organisation` destroys its sets, while a set can be shared with a partnership in
a **different** organisation whose cascade never touches those rows.

**Fix:** added the missing association with `dependent: :destroy`, in the same
commit as the constraint.

**Guard:** two cascade tests, both verified to fail without the association.

---

## BUG-004 — A JS-facing string outside the `js:` namespace renders as a raw key

**Severity:** respondents saw `player.tokens_earned` on screen.
**Found:** in the browser. No test could see it.
**Fixed in:** the token-reveal work.

`layouts/_i18n_js.html.erb` exposes only the `js:` namespace as `window.I18N`.
A key added under `player:` instead of `js.player:` resolves server-side and
fails in the browser.

**Guard:** new browser-facing strings are checked against the actual
`window.I18N` payload, not just `I18n.t`.

---

## BUG-003 — `attachment.try(:named_variants)` is permanently false

**Severity:** silently defeated the whole change it was guarding.
**Found:** reading the Active Storage source rather than trusting `try`.

`named_variants` is **private**, so `try` returns nil and the guard never fired.
The thumbnail preprocessing looked correct and did nothing.

**Fix:** read the reflection from the record's public
`attachment_reflections` instead.

---

## BUG-002 — `remove_method` on a real `def self.call`

**Severity:** broke ten unrelated tests.
**Found:** twice — the second time recognising it as the same mistake.

Stubbing a class method with `define_singleton_method` and then
`remove_method` deletes the *original* definition, not the stub.

**Fix:** use the repo's own `stub_method` helper in `test/test_helper.rb`, which
restores the original.

---

## BUG-001 — `rack-timeout`'s `wait_timeout` silently clamps the service timeout

**Severity:** would have quietly reduced a deliberate 240s bound.
**Found:** reading the gem's source instead of its README.
**Fixed in:** `0dfddc4`

`Rack::Timeout` reduces `service_timeout` based on `wait_timeout` unless
`service_past_wait` is set. The generous tier for AI endpoints would not have
been generous.

**Fix:** `wait_timeout: false` on every instance.

---

## The recurring shape

Nine of these (001, 003, 008, 009, 011, 013, 014, 015, and BUG-004's whole
class) share one pattern: **the check that was available said everything was
fine.** `bin/rails runner` booted. `try` returned nil without error. The matcher
returned true. The browser test went green. The blur guard restored the title.
231 lines of consent tests passed. In each case the only thing that found the
bug was deliberately trying to make it fail — force the eager load, break the
feature and re-run the test, run the matcher against a known-negative.

Green is evidence only when you know what red looks like.

## The second shape: a boundary nobody tests

013, 014 and 015 add one of their own. Each lived exactly where two halves of
the system meet and each half looked correct on its own:

* an input handler and a blur handler, correct apart, wrong in sequence;
* a stack that pushed on delete and not on insert;
* a Ruby constant and its JS mirror, agreeing everywhere except the one type
  that had just been added.

No unit test can see any of them, because no unit owns the boundary. Two of the
three were found only once a browser could drive the editor, and the third only
because a second reader was asked to *refute* the first one's "done" rather than
confirm it. Both are worth keeping: the harness, and the habit of not accepting
a verdict from whoever produced the work.
