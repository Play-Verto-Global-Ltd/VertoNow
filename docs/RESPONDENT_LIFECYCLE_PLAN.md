<!-- Investigated and written 15-16 September 2026 against origin/Main a86dddf.
     NOTHING HERE IS BUILT. This is a plan, and the code it describes has moved
     on since — re-check the line references before trusting one. Its companion
     is docs/mockups/respondent-verification/, which draws the first three asks. -->

# The respondent lifecycle: from finishing a Verto to hearing back

## Context

A respondent finishes a Verto, creates an account with an address and a password,
and then never hears from anyone again. `PlayerController#join` mints a sign-in
link with `ORIGIN_SIGNUP`, which `proves_address?` treats as no proof at all, so
`email_verified_at` stays nil — and `PlayerAudience.for_survey` filters on
`where.not(email_verified_at: nil)`. The account exists, holds its claims, and is
structurally unmailable. The card's own copy promises the opposite.

The ask is the whole loop the account was always for: verify the address, land the
person back on what they just played, then keep them in touch — as results move,
as the creator follows up or runs it again, as impact lands, and as Playverto
itself has something worth playing.

Seven behaviours, as stated:

1. Finish a Verto → create an account → **be asked to verify the address**.
2. Accounts that never verified → a **"claim your account"** email.
3. Opening the account from that mail → **straight to the Verto they played**,
   with their results comparison.
4. **The following day** → an email showing how the results have moved.
5. A creator marks a Verto as a **follow-up or a pulse** → respondents are emailed
   that the next one is ready.
6. The same when a creator **publishes Impact**.
7. When **Playverto** publishes a Verto → the respondent community is emailed to
   play it, and gets highlights.

## The short version

- **Asks 5 and 6 are already shipped** — Impact and follow-up notifications both
  exist with a creator button each. What they lack is anyone to send to.
- **Ask 1 is the switch.** `PlayerAudience` refuses unverified addresses and the
  password door never verifies one, so today those mails reach Google signups only.
  Verification is not the first feature; it is what turns the other six on.
- **"Pulse" already has a model**: `SurveyWave`, named open/close cycles of the
  same Verto. It just notifies nobody.
- **Three live bugs surfaced on the way**, all fixed inside this work — see below.
- **The largest unstated requirement is frequency.** With all seven live, one
  person can receive six emails in a day. There is no cooldown or ceiling
  anywhere.

Estimate: **9–10 implementation days**, stages 2–4 parallel once stage 1 lands.

## Three live bugs this work must fix

1. **The second follow-up notice silently skips everyone already told.**
   `surveys_controller.rb:935-939` states that adding a second follow-up months
   later is "a legitimate second send about a different Verto". It is not.
   `notify_players_job.rb:37` builds
   `told = PlayerNotification.where(survey_id: survey.id, kind: kind)` — keyed on
   the **source** survey, not the target — and excludes those players in SQL before
   any claim is attempted. So the second notice reaches only people who were not
   reachable the first time (joined since, or undeliverable then); every respondent
   already told about follow-up A is dropped from the send about follow-up B, with
   no error and nothing in the UI to show it. The button's confirm text ("anyone
   already told about it won't be emailed again") and its own controller comment
   contradict each other, and the confirm text is what the code does. Fixed by
   keying the claim on the target via `period` (§4).
2. **A stranger can hold an account at your address.** `#join` does
   `Player.create!(email_address:, password:)` with no proof, and
   `PlayerSessionsController#create` does not check verification — so whoever
   typed it can sign in. Today the blast radius is their own run. The moment a
   claim mail goes out, the real owner clicks it and lands in an account whose
   password a stranger knows. `Player#adoptable?` does not help: it requires
   `password_digest.nil?` and this row has one. Fixed in §2.2.
3. **No frequency control of any kind.** `THROTTLE = 0.1` permits ~36,000
   sends/hour/thread against SMTP tiers of 100–300/**day**, and `PlayerAudience`
   has no cap, cooldown or "last mailed at". Fixed in §1.3.

## What is already built

**Ask 6 is done.** The creator writes the impact fields in the editor's Publish
panel (`app/views/surveys/show.html.erb:2049-2091`) and presses *"Publish this,
and email everyone who asked"* (`SurveysController#publish_impact:922`) →
`NotifyPlayersJob(id, "impact")`. One-shot, latched on `impact_published_at`.

**Ask 5's follow-up half is done.** Tick up to three of your own Vertos
(`show.html.erb:2112-2134`, `follow_up_survey_ids`), press *"Tell everyone who
asked about it"* (`#notify_follow_up:940`).

**Ask 5's pulse half has a model but no name and no send.** `SurveyWave`
(`app/models/survey_wave.rb`, `Survey#start_next_wave!` at `survey.rb:2318`, UI at
`show.html.erb:2379-2473`) models named open/close cycles of the same Verto, with
responses tagged `survey_wave_id` so wave-over-wave comparison already works.

**The delivery layer is solid — reuse it.** `NotifyPlayersJob` batches 25 with a
100ms throttle and re-enqueues itself; `PlayerNotification.claim` wins a unique
index so a doubled press cannot mail twice; every notification carries both
unsubscribe scopes with RFC 8058 one-click on the narrow one; the house template
and `I18n.with_locale(player.preferred_locale)` are translated across 26 locales.

## Promises this falsifies

All must be rewritten in the same commits, not after. This repo treats its prose
as load-bearing.

- `docs/DATA_RETENTION.md`: *"An account is written to only when a creator
  publishes what their Verto changed, or points it at a follow-up — both
  deliberate actions in the editor, **never automatic**."* Asks 2, 4 and 7 are
  automatic. The same section's title — **two** ways to stop mail — becomes three.
- `you.emails_hint` (`en.yml:1649`): *"One email per Verto, only when there's
  something to say — what changed, or a follow-up to play."* The replacement
  should state the cooldown, which is what makes it true again.
- *"An address nobody has proved they own is never mailed"* — stated in
  `player_audience.rb`, `Comms::AudienceResolver` and the doc. Ask 2 carves it out.
  **Implement the carve-out as a separate `for_claim` scope, never by relaxing
  `for_survey`** — relaxing `for_survey` silently starts mailing unverified
  addresses for every existing kind.
- `player_controller.rb:99-106` says the per-IP caps can be scaled for a crowd
  *because* join does not send mail, "which a mail-bomb guard could not be". From
  §2.3 on, it does.

---

# The plan

## Stage 0 — Schema (alone, first) · ~0.5d

Five additive migrations with backfilled defaults, so nothing observable changes.

- **`period` on `player_notifications`**, `NOT NULL DEFAULT ""`; swap the unique
  index to `[player_id, survey_id, kind, period]`. **Non-null deliberately: a NULL
  in a unique index does not collide, so a nullable column would silently destroy
  the existing one-shot guarantee.** Widen `chk_player_notifications_kind` to
  `('impact','follow_up','claim','results_digest','wave','community')`.
- **`kind` on `player_email_preferences`**, `NOT NULL DEFAULT ""`; unique index
  becomes `[player_id, organisation_id, kind]`. `""` = "everything from this org",
  today's meaning, preserved by the default.
- **`players.community_opt_in_at`** — a datetime, not a boolean; a consent record
  has to answer *when*.
- **`player_sign_in_links.destination_survey_id`** (nullable, FK
  `on_delete: :nullify`) and `community_opt_in` (nullable boolean); the same
  boolean on `player_oauth_handoffs`, which already has `survey_id`.
- **`surveys.pulse_notifies`**, `NOT NULL DEFAULT false`.

Two hazards: SQLite rebuilds the whole table for a check-constraint change,
reordering `schema.rb` columns (expect one noisy commit); and
`remove_check_constraint` + `add_check_constraint` is not auto-reversible, so
write explicit `up`/`down`.

## Stage 1 — Preferences, audience, cooldown, sweep · ~1.5d

No user-visible change; existing tests stay green on the `""` defaults.

**1.1 The third axis.** `PlayerEmailPreference.unsubscribed?(player_id, org_id,
kind = "")` checks `kind: ["", kind]` — the broad row always wins, so someone who
said "stop everything from this council" does not start hearing again because a
new kind shipped. Note this also gives **ask 7's opt-out for free**: Playverto is
itself an organisation, so "only stop emails from Playverto" already reads
correctly through the existing per-org axis.

**1.2 `PlayerAudience`** grows `kind:` on `for_survey` and `deliverable?`, plus:
- `for_claim` — the one place unverified is *required*. Keep it separate (above).
- `for_community(survey)` — the first global cross-survey scope. Must stay a
  **scope**, not materialised, so `NotifyPlayersJob`'s `order(:id).limit(25)`
  still bounds it; otherwise the first broadcast loads every respondent in the
  product into one job on a 512 MB instance.

**1.3 The cooldown — new, and required.** Inside `deliverable?`:
`THROTTLED_KINDS = %w[results_digest wave community]` held behind a ~20-hour
quiet period, transactional kinds never held. Plus a process-wide daily ceiling
from an env var, so a misconfigured broadcast cannot burn the SMTP quota in
ninety seconds. This is also what makes the rewritten `emails_hint` true.

**1.4 `NotifyPlayersSweepJob`** + a `config/recurring.yml` entry every 10 minutes.
`NotifyPlayersJob` is `discard_on StandardError`, self-re-enqueuing, inside Puma
under a memory watchdog — `Comms::SweepJob`'s header says exactly why that needs a
safety net. Today a lost chain costs a few impact mails; after stage 3 it is a
daily job failing silently and cumulatively.

## Stage 2 — Asks 1–3: verify → claim → land on the Verto · ~2d

**2.1 Token: reuse `PlayerSignInLink`, not `generates_token_for`.** The landing
must show `/you/v/:id`, which needs a session, so it is a bearer credential; the
question is only how it is stored. `generates_token_for` is stateless and
therefore **cannot be single-use** — the GET/POST split throughout this app exists
because inbox scanners follow GETs, and a stateless token makes every holder of
the mail equally capable until expiry. `player_sign_in_link.rb:1-3` already
records the decision: "See the migration for why this is a row rather than
`generates_token_for`." The row also already carries `claim_payload`, atomic
`consume!`, a rate-limited GET/POST pair and a styled confirm page.

Add `ORIGIN_VERIFY` (7 days) and `ORIGIN_CLAIM` (30 days is the agent's
suggestion; **I would start at 7–14** — it signs somebody in, and an expired one
can offer a fresh send rather than dead-ending). `proves_address?` becomes
`[ORIGIN_EMAIL, ORIGIN_VERIFY, ORIGIN_CLAIM].include?(origin)` — **the single
highest-value line in the release**, because it is what makes the join-card
population mailable at all. `mint!` takes `destination_survey_id:` and a lifetime.

**2.2 The confused deputy — claiming evicts everyone else.** In
`PlayerSignInsController#create`, in the same transaction as `consume!` and before
`start_player_session_for`: when the link proves the address and the account is
not yet verified, **null the `password_digest`, delete every `PlayerSession`, and
consume every other outstanding link**. An unverified row is a *provisional*
account: whoever proves the inbox wins it and nobody else keeps a way in. It is
idempotent — a verified account re-opening its link keeps its password.

**This manufactures a lockout unless one more thing ships with it.** A wiped
account has no password and usually no Google, so its only way back is
`/you/sign-in/email` — which `PlayerSessionsController`'s header says is
deliberately unlinked from every page because it could not work until SMTP was
fixed. That reasoning expires here. **Surface the emailed-link option on
`app/views/player_sessions/new.html.erb`**, guarded by
`MailConfigCheck.deliverable?`. Also land them with a one-time banner offering to
set a password (`YouController#update_password` already handles the no-password
case).

**2.3 Ask 1 — the verification mail.** Sent from `#join`, only on the two branches
that create or adopt an account, guarded by `MailConfigCheck.deliverable?` and
wrapped so a mail failure cannot fail the join (the
`EmailConfirmationsController.deliver` pattern). Return `verification_sent:` in
the JSON so the card does not promise an inbox on a deploy with no SMTP.

Because `#join` now mails stranger-typed addresses, add a **per-address verify
cooldown** (one per address per hour regardless of IP) — the per-IP gates are
multiplied by `PLAYER_JOIN_RATE_LIMIT_SCALE` and the code comment explicitly
disclaims mail-bomb duty. Update that comment.

The mail names what was created and where, and carries a **"this wasn't me"** link
that deletes the account — `YouController#destroy` already does self-service
erasure. Without it, "ignore this email if it wasn't you" is an invitation to
leave a stranger holding your address.

**2.4 Ask 2 — the claim mail.** A daily job over `for_claim`: unverified, holds
≥1 claim, created between 48 hours and 30 days ago, no prior notification of any
kind, not suppressed. Once per account, ever. The notification row uses the
**most recently claimed** survey for `survey_id`/`organisation_id` — both stay
`NOT NULL`, the per-org unsubscribe reads correctly, and the mail genuinely is
about that Verto. Carries the ask-7 opt-in.

**2.5 Ask 3 — the landing.** `PlayerSignInsController#create` redirects to
`you_verto_path(@link.destination_survey_id)` when set, else `you_path`.
`PlayerClaimPayload.apply` already runs first, so the claim exists by the time
`#verto` scopes on it. A deleted Verto nullifies the FK and degrades to a normal
landing; an unheld one already redirects with `t("you.not_found")`.

## Stage 3 — Ask 4: the day-after digest · ~2d

**Gate once per Verto, not once per recipient** — a Verto with 1,284 respondents
must not do 1,284 double-aggregations. An hourly job: candidate surveys are
`DISTINCT survey_id` from `player_claims` claimed 24–25 hours ago; then
`compare_results?`, then `Response::MIN_REGION_SAMPLE_SIZE = 5` (the mail contains
the suppressed payload, so the floor applies), then **movement** — two passes of
the existing `aggregate_results`, one cut at 24 hours ago, moved if any option's
share shifts by ≥3 points or the responder count grows by ≥5. Lift the check into
`app/lib/results_movement.rb` so it is testable without a controller, and lift
`comparison_for`/`comparison_rows` out of `YouController` into
`app/lib/player_comparison.rb` so the mailer and `/you/v/:id` cannot drift.

Fires once per (player, survey), so `period: ""`. If it ever recurs weekly,
`period: Date.current.beginning_of_week.iso8601` is the drop-in.

**No per-recipient timezone exists** — `Comms::SendSlot` says so explicitly and
defaults to UTC. "The following morning" is one wall-clock hour globally. A
decision, not a surprise; `players` has no timezone column to fix it with.

## Stage 4 — Ask 5: follow-up and pulse as two things · ~1.5d

- **Follow-up** — data unchanged, UI relabelled. **Fix the second-send bug**:
  claim with `period: "to:#{target_id}"` and enqueue one job per newly-added
  target.
- **Pulse** — `surveys.pulse_notifies` is the creator switch; new kind `wave` with
  `period: "wave:#{wave.id}"`, which is the case that makes `period` necessary.
  Audience: respondents of *earlier* waves who have not answered this one, via
  `PlayerClaim → Response#survey_wave_id`.

**Do not hang the send off `SurveyWavesController#create`.** That controller is
member-level on purpose — its header says starting a wave "grants no new
visibility to anyone outside the org". Mail voids that, and would sit *below* the
`require_admin!` bar that `publish_impact` and `notify_follow_up` sit on for the
stated reason that they send mail (`player_notifications_test.rb:451` asserts it).
New admin-gated `#notify` action instead.

**A direction mismatch worth naming.** You asked for a creator to say a Verto *is*
a follow-up; `follow_up_survey_ids` lives on the **pointing** Verto, deliberately
("a wave is not a special case in the data… 'Wave 2' is a label"). Don't invert it
with a new column — derive the badge by inverting in Ruby across the ~50 surveys
the dashboard already loads. The column is `json`, so a SQL reverse lookup would
differ between SQLite and Postgres.

**Dashboard surface.** Today `_dashboard_card.html.erb` mentions none of this. Add
a badge beside `ask_verto_badge` (`:104`), driven by a grouped hash built in
`SurveysController#index:180` exactly as `@ask_states` is, to avoid an N+1.

## Stage 5 — Ask 7: the Playverto broadcast · ~1.5d

**Build on `NotifyPlayersJob`, not by widening Comms.** `email_campaign_recipients
.user_id` has no foreign key — the precise hazard `PlayerAudience`'s header was
written about. More decisively, **the unsubscribe semantics are incompatible**:
Comms' unsubscribe is global, so routing player mail through it would offer a
respondent only "stop everything Playverto ever sends" — exactly what the
two-tier model exists to avoid.

Sender = the existing Playverto organisation (`db/seeds.rb:1-3`,
`PlayvertoStaff::SLUG`), which already owns a Verto and has a brand palette.
Survey = the Verto being promoted, so both `player_notifications` columns stay
`NOT NULL`. Gate on `PlayvertoStaff.member?`, not org-admin — this crosses every
tenant. `player_notification_mailer.why` currently says "because you asked to hear
from organisations whose Vertos you've answered", which is false for this kind and
needs its own string.

**Highlights should mean *this Verto's* results**, reusing `results_summary`.
`player_notifications.survey_id` is `NOT NULL`, so a Verto-less newsletter cannot
use the ledger without weakening the unique index that makes double-sends
impossible. If one is wanted later it is a separate mechanism.

**Opt-in capture.** An unticked checkbox on the join card, and the same ask on the
claim confirm page. **It must not be written by `#join`** — `DATA_RETENTION.md`
invariant 1 ("nothing is stored against an address until someone proves they can
reach it") is stated as checkable in code, which is why `#join` writes no claims.
The flag rides on the link/handoff and is applied on consumption, beside
`PlayerClaimPayload.apply`. Plus a revocable toggle on `/you/account`.

## Stage 6 — Deliverability · ~0.5d + vendor lead time

A bounce/complaint webhook: `POST /webhooks/email`, signature verification,
`EmailSuppression.record!`. Nothing in the app writes `hard_bounce` or `complaint`
today and there is no inbound route anywhere.

**Blocking for ask 7 only.** Asks 1–6 mail people who have a relationship with the
sender, at per-Verto volumes. Ask 7 broadcasts to the whole respondent base from
**the same envelope domain as the sign-in links** — one `MAIL_FROM`, generic SMTP,
no message streams. A complaint spike there degrades the transactional mail that
this release has just made load-bearing, and there is no respondent password reset
to recover with. Minimum mitigation if it ships sooner: a separate
`MAIL_FROM_BROADCAST` subdomain.

## Stage 7 — Copy, 26 locales, docs · ~1d, last

New namespaces for the verification mailer and four notification kinds, a second
`why`, the per-kind preference matrix on `/you/account`, the join-card opt-in
label, the editor relabelling, and the doc rewrites above. A new mailer namespace
must join `NAMESPACES` in `test/lib/locale_respondent_parity_test.rb` **in the same
commit** — that file's header records an English-only feature hiding for three
pushes because it did not.

---

## Sequencing

```
0 schema                  0.5d   alone, first
1 prefs + audience + sweep 1.5d  freezes every signature
  ├ 2 verify/claim/land    2.0d  ┐
  ├ 3 day-after digest     2.0d  ├ parallel
  └ 4 follow-up vs pulse   1.5d  ┘
5 community broadcast      1.5d  gated on 6
6 webhook                  0.5d  + vendor lead time
7 copy, locales, docs      1.0d  last
```

One developer should do 2 first regardless: 3, 4 and 5 all mail an audience that
does not exist until it lands. Roughly 12–14 `bin/gate` runs at ~7½ min each.

## Verification

- The four most-affected test files already carry ~90 tests
  (`player_notifications_test.rb` 28, `player_claims_test.rb` 21,
  `you_settings_test.rb` 18, `you_dashboard_test.rb` 23). Extend rather than
  rewrite — both are good canaries for an accidental semantic widening in stage 1.
- **One guard will stop guarding silently:** `player_claims_test.rb:178` uses
  `assert_no_difference { ActionMailer::Base.deliveries.size }`, which cannot see a
  `deliver_later` under the `:test` queue adapter (`config/environments/test.rb:71`).
  It must become `assert_enqueued_emails` in the same commit. Line 200's
  `PlayerSignInLink.last.origin` assertion will break honestly once a second link
  is minted; pin it to the signup link rather than "the last row".
- New tests: claiming wipes the password and kills other sessions; a claimed link
  lands on `/you/v/:id`; an opted-out kind is excluded; the digest does not fire
  when comparison is off, suppressed or unmoved; a wave notice is once per wave; a
  second follow-up target actually sends.
- End to end with the `/verify` skill for the join card, the claim landing and
  `/you/account`.
- `bin/gate` before every push.

## Where the framing needs adjusting

1. **"All seven as one release" is right about the preference model and wrong
   about ask 7's send.** The third axis, the opt-in column and its capture points
   should ship with everything else; the broadcast itself should wait for a bounce
   loop and a separate domain, because it is the one send that can take the
   transactional mail down with it.
2. **Ask 7's audience is zero on release day** and grows only from the opt-in.
   Correct and principled — and it means ask 7 cannot be validated at launch.
3. **Asks 5 and 6 are not new work.** The release's actual content for them is:
   make the audience exist, make the kinds separately stoppable, and fix the
   second-send bug.
4. **"The numbers actually moved" has no stored baseline.** It is a second
   aggregation pass with a time cut, not a flag — computable, but it is a query,
   and it must run per Verto.
5. **Frequency is the largest requirement nobody stated.** Six mails a day to one
   person is currently possible and uncapped.
