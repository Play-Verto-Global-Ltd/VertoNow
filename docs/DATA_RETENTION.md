# Data retention & respondent rights

Written for P0-7. Describes what Playverto stores about respondents, how long,
who can remove it, and the limits of what the platform can actually honour.

## What is stored about a respondent

Every Verto ends with an automatically appended demographic tail
(`DemographicQuestions`): birth month/year, where they live, and gender. So in
practice **every** Verto holds personal data, not just ones whose creator chose
to ask for it. Creators can additionally add two opt-in demographic questions
(`DemographicQuestions::OPTIONAL_CARDS`) — Heritage (ethnicity) and
Neurodiversity — from the add-question modal; those are stored only on Vertos
whose creator chose to ask.

A `responses` row can hold:

| Field | What it is |
|---|---|
| `answers` | Their answers, keyed by card index |
| `demographic_birth_year`, `demographic_gender` | From the demographic tail |
| `demographic_heritage`, `demographic_neurodiversity` | From the opt-in demographic questions, when the creator added them |
| `region_country`, `region_label` | Derived from the location answer |
| `locale`, `device_kind` | Language and rough device class |
| `started_at`, `completed_at`, `created_at` | Timings |
| `consent_agreed_at` / `consent_declined_at`, `consent_text_snapshot` | The consent record, including the exact wording shown |
| `score`, `quiz_max`, `token_totals` | Quiz and token scoring |
| `session_token` | A random per-session UUID minted in the browser |
| `respondent_code_digest` | HMAC of a code the respondent chose, if the creator enabled codes |
| `player_key_digest` | HMAC of a random key the browser minted for this Verto; recorded only where a feature needs a per-device identity — the leaderboard, the contact gate, ask-once questions, or No retests on a Verto that collects no respondent code |

No email address, name or account is attached to a response **row**. Since
respondent accounts shipped there is one link from the outside, and it is
worth stating precisely because the sentence above used to be unqualified:
where a creator turns on the end-of-Verto ask (`join_prompt_enabled`, off by
default) and the respondent gives an address **and then follows the link
emailed to it**, a `player_claims` row names that response by id and belongs to
a `players` row that holds the address. The response itself gains no column, no
digest and no flag — it is unchanged, and nothing in the creator's results or
export reveals that a claim exists (see "Respondent accounts" below).

There used to be one further deliberate, creator-chosen exception — the
**contact card**
(`contact_form`), which stored whatever the respondent typed into its name /
company / industry / email fields inside `answers`, like any other answer.
That card type has been **retired**: it can no longer be added to a Verto, the
player skips any copy left in a published deck, and the server refuses an
answer to one, so no response created from now on can carry identifying data
of this kind.

Details collected while the card was live are still held, in the `answers` of
the responses that carry them, and are still shown in that Verto's results and
CSV/Excel export to the creator who collected them. They ride the existing
respondent-data export and deletion paths (`/respondent-data`) like the rest of
the response, and go when the response or the Verto does. Retiring the card
stopped the collection; it did not delete what was already collected.

### Free text is held until it is moderated

A typed answer — an `open_ended` value, or an "Other" write-in on any card —
is the one place a respondent can put anything at all into the platform. It no
longer lands in `answers` directly (`app/lib/moderation.rb`):

1. **Scrub.** Email addresses, phone numbers, URLs and social handles are
   replaced with `[removed]` before the text is stored anywhere. This is
   deterministic and has no off switch.
2. **Hold.** What is left is moved out of `answers` into a `held_texts` row
   (`HeldText`, text encrypted at rest with Active Record encryption), and a
   marker — `"held" => { "value" => true }` — is left in its place. The
   response still counts as answered; results totals include it; the results
   page, exports, Ask Verto and the AI report have no text to show because
   there is none in the row.
3. **Screen.** A background job asks Claude to classify each held text.
   Confidently clean text is released back into the answer; confidently
   identifying, abusive or spam text is removed (a `removed` marker stays in
   the answer); anything uncertain, anything a Verto in `review_all` mode
   holds, and anything that reads as a safeguarding disclosure waits for a
   person. Every failure — the screen off, the daily cap spent, the API
   erroring — leaves the text held, never shown.

Held texts follow the response: they are deleted with it, with the Verto, with
the organisation, and by the consent-decline purge. The subject access export
includes them (`held_answers`, with each text's status) because a held copy is
still the respondent's data. A **removed** text is kept, readable to staff
only, for `Moderation::REMOVED_RETENTION` (7 days) so a question about the
decision can be answered, and is then blanked by `SweepHeldTextsJob`; the row
remains as the record that a removal happened. A text the respondent replaced
before it was decided (`superseded`) is blanked on the same schedule.
Safeguarding texts are never auto-purged: a person reads them.

The `respondent_code_digest` is a one-way HMAC keyed per Verto
(`Survey#respondent_code_key`), so a code is comparable **within** one Verto and
nowhere else, and the plaintext is never stored, logged or returned.

### Recall, and what it changes

A `respondent_code` card can opt in to **recall** (`recall: true` on the card,
off by default). With it on, entering a code at `POST /play/:token/recall`
returns that identity's previously given answers **to ask-once questions only**,
so "asked once" holds across devices rather than only across visits to one
browser.

This is the one place the product reads a digest back rather than merely
grouping by it, and the digest's key is a code the respondent chose to be
memorable — which is to say guessable. So it is bounded on every side that can
be bounded (`RespondentRecall`, `PlayerController#recall`):

- off unless the creator turned it on, on the card itself;
- only cards *currently* flagged ask-once, and never a graded or token-awarding
  one;
- nothing else from the response — no demographics, region, locale, contact
  details, score, totals, timestamps or counts;
- a card whose stored answers **disagree** under one digest is dropped, on the
  assumption that two people invented the same code;
- one response shape for unknown code, blank code, recall off and nothing
  recallable, so the endpoint cannot be used to confirm that a code exists;
- three budgets: requests per IP, *distinct codes* per IP, and lookups per code.

The residual exposure, stated rather than implied: a correctly guessed code
returns that person's ask-once answers. A creator who does not need cross-device
ask-once should leave recall off, which is the default, and still gets wave
matching — that has never required reading anything back.

## Retention period

Responses are kept for the life of the Verto. Deleting a Verto deletes its
responses (`dependent:` on the association); archiving one does not.

`rake responses:purge[days]` removes responses older than N days across all
organisations, for a controller who wants a shorter horizon than "forever".
It is **not scheduled by default** — retention length is the customer's policy
decision, not ours, and silently deleting a funder's research data would be
worse than keeping it. Run it deliberately, or add it to `config/recurring.yml`
once a period has been agreed.

```
bin/rails responses:purge[365]          # delete responses older than a year
bin/rails "responses:purge[365,dry]"    # count them without deleting
```

## Subject access and erasure

Admins get **Results → Download CSV → One respondent's data…**
(`/surveys/:id/respondent-data`), which:

- finds a respondent's rows by session token or by respondent code;
- exports **everything** held about them as JSON (Article 15 / 20) — including
  the demographics, consent record, derived region, device, timings and scoring
  that the ordinary results export leaves out, and any free text still held
  or removed by moderation (`held_answers`);
- erases those rows permanently (Article 17).

Erasure is a hard delete, not an anonymisation pass. A stripped-but-present row
would still be personal data if it could be re-linked, and the right is erasure.
The consequence is honest: response counts drop, and any cached summary or
report keyed to the old count regenerates the next time it is opened.

The creator is the data controller here. A respondent's request reaches them,
not Playverto, so this is a creator-facing tool rather than a self-service
portal.

## The limit worth knowing

**Most respondents cannot be identified after the fact.** The session token
lives in `sessionStorage`, keyed to the Verto's submit URL, and is gone when the
browser tab closes. Unless the creator enabled respondent codes — in which case
the respondent knows their own code — a person who comes back a week later has
no handle on their own row, and neither does anyone else.

This was a real gap in honouring Article 17 on request, and a deliberate
consequence of collecting no identifier. Closing it meant either showing
respondents a receipt code at the end of a Verto that they could quote later, or
storing a durable identifier — which trades a privacy property for a rights one.
That was called a product decision rather than a bug fix, and left unmade.

**It has since been made, in one direction and by the respondent.** See
"Respondent accounts" below: a respondent may now be offered an account at the
end of a Verto, and the address is a durable handle on their own rows. It
closes the gap only for people who chose it, on Vertos whose creator switched
the ask on — which is the point. Everyone else is exactly as unidentifiable as
this section describes, and the default is off.

The `respondent_code` card narrows the gap where a creator uses it — a
respondent who chose a code has a handle on their own rows, and
`RespondentDataController` already accepts one — but it does not close it:
entering a code is required to proceed wherever the card or pre-screen
appears, yet the code is only as good as the respondent's memory, and
nothing stops a throwaway entry they can never reproduce.

Creators also see per-responder groupings — the export's Responder column
and the results page's Responders card — but only under minted anonymous
names (`RespondentAlias`, erased with the responses they name): never the
code, its digest, or anything derived from either.

## Respondent accounts

A creator may switch on an ask at the end of their Verto: *keep this, and hear
what happens next*. It is **off by default** (`surveys.join_prompt_enabled`),
the wording is the creator's, and a respondent who ignores it leaves exactly
the row this document describes everywhere else.

What is stored, and where:

| Table | Holds |
|---|---|
| `players` | The address, a name if they give one, their locale, and when the address was verified |
| `player_sessions` | Signed-in sessions, like `sessions` for creators |
| `player_sign_in_links` | An outstanding emailed link: its **digest** only, its expiry, and the claims it will make |
| `player_claims` | `(player_id, survey_id, response_id, claimed_at, source)` — the one cross-Verto join in the app |
| `player_email_preferences` | `(player_id, organisation_id, unsubscribed_at)` — an opt-out from ONE organisation's mail |
| `player_notifications` | One row per intended send: which Verto, which kind, an unsubscribe token, and whether it went |
| `player_identities` | A linked Google account: `(provider, uid)` plus the name and address Google last reported |
| `player_oauth_handoffs` | A sign-up in flight: its **digest** only, its expiry, and the claims it will make. Holds no address — at that point nobody knows one |

Five properties this design is built on, all of them checkable in the code:

1. **Nothing is stored against an address until someone proves they can reach
   it.** `PlayerController#join` writes no claim, and neither does
   `#join_google` — each parks the claims on a row and hands back a link. The
   claims are made on the way back in, by `PlayerSignInsController#create` or
   `PlayerOauthSessionsController#create`, through one definition
   (`PlayerClaimPayload.apply`). A sign-up abandoned at Google's consent
   screen leaves a digest and an expiry behind, and no address anywhere.
2. **The response is not modified.** No `responses.player_id`, and no digest —
   `player_claims` materialises `response_id`. A claim is invisible in the
   creator's results, in the CSV export's "Device group" column, and on the
   leaderboard.
3. **Special-category answers and an address never meet.**
   `Survey#contact_form_excludes_neurodiversity` covers `join_prompt_enabled`
   exactly as it covers `contact_form_enabled`: a Verto may ask the
   neurodiversity question or ask for an address, never both.
4. **Every credential is single-use, a digest, or somebody else's — and the
   one token that is none of those grants nothing.** This
   point used to read "there is no password and no sign-in form", and it has
   been wrong since 2026-09-10, when the card started taking a password on the
   owner's instruction; Google sign-in is the third way in. What is still true
   of all three is the discipline:
   - the emailed link is single-use, valid for 20 minutes, and stored only as
     a digest. `GET` on it consumes nothing (inbox scanners follow GETs); the
     `POST` behind a button does the work;
   - the password is a bcrypt digest with the same 12-character floor as a
     creator's, and there is no respondent password reset — the emailed link
     is the recovery route;
   - Google sign-in stores no credential at all, only `(provider, uid)`. An
     address is accepted from it **only when Google says it has verified it**,
     which is what stops a new identity walking into an existing account by
     claiming its address — and is why an account made this way is verified
     without any mail having to arrive.

   The address confirmation (2026-09-23) is the exception, and it is one on
   purpose. A password signup never proves its address, so it is sent one
   mail whose link stamps `email_verified_at`. That link is a
   `generates_token_for` token: reusable for 7 days, never stored, keyed on
   the address so changing it voids the link. It is none of the three kinds
   above because it is not a credential — it signs nobody in and opens
   nothing, and spending it only lets the organisations the person kept
   Vertos from write to an address that has now shown it can read them.
5. **`/you` is `no-store` and `noindex`,** and its cookie is separate from the
   creator's in every respect — different name, different table, different
   `Current` attribute.

### Rights, and where one creator's authority ends

**Access (Art. 15).** `/respondent-data` accepts an email address as a third
identifier alongside the session token and the respondent code, and matches
only claims **on that Verto**. The export gains an `account` section naming
the address, whether it is verified, and how many Vertos the account holds.

**Erasure (Art. 17).** Erasing a respondent's responses erases their claims on
that Verto with them, and the records of having told them about it. A standing
mail preference is deliberately NOT erased where the account survives: it is
the person's own choice about that organisation rather than data about the
erased Verto, and silently re-subscribing them would be the worst available
reading of an erasure request. If the account is then holding nothing at all, the
`players` row goes too — keeping a bare address after an erasure request is
the half-measure this whole flow refuses. If the account still holds claims on
**other** Vertos, the row stays: the creator is the data controller for their
own Verto, not for the rest of that person's account.

### Mail, and the two ways to stop it

An account is written to only when a creator publishes what their Verto
changed, or points it at a follow-up — both deliberate actions in the editor,
never automatic. A send honours, in this order: an unverified address is never
mailed at all; an opt-out from *that organisation*; and the global
`EmailSuppression`, which also carries hard bounces and complaints. A
`player_notifications` row is claimed before each mail on a unique index, so a
retried job or a double-pressed button cannot mail one person twice.

Every message carries **both** unsubscribe links, narrow one first:

- *Only stop emails from this organisation* — a `player_email_preferences`
  row. It is also the target of the RFC 8058 one-click header, because "this
  sender" is what a reader thinks a mail client's unsubscribe button stops.
- *Stop all Playverto emails* — `EmailSuppression`, which is unique on `email`
  and subtracted from every send in the product, creator campaigns included.

The narrow one exists because the wide one is shared: without it, a respondent
who wanted fewer emails from one council would have been silencing the results
digest of any creator using the same address — and creators play their own
Vertos, so that is a matter of time rather than a hypothetical. A missing or
malformed scope resolves to the narrow one, because an unintended narrow
opt-out is a support ticket and an unintended global one is a person cut off
from mail they never meant to stop.

**Self-service.** The account holder deletes the whole account from
`/you/account` (the account page behind the name in the corner of `/you`) —
the player, its sessions, its outstanding links, its mail preferences, its
notification records and all of its claims. Never the `Response` rows: those are pseudonymous research data belonging to the
creators who collected them, and are not this person's to delete from here.
This is the first self-service erasure path in the app, and it exists only
because a respondent now holds a durable handle at all.

## Related

- Consent enforcement: `Survey#default_consent_gate?` (P0-6)
- Small-cell suppression on public comparisons: `Response::MIN_REGION_SAMPLE_SIZE`
- Encryption keys backup: `PRODUCTION_READINESS_PLAN.md` P1-6
