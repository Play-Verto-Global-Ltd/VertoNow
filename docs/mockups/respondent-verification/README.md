# Respondent verification, and the Google door — mockups

Two changes to the account a respondent is offered at the end of a Verto:

1. **A verification email on the password signup.** Today that door never proves
   the address, and `PlayerAudience.for_survey` filters on
   `where.not(email_verified_at: nil)` — so every respondent who signs up with an
   address and a password is silently excluded from every mail the creator ever
   sends them, including the one the card promised. (Two routes out of that state
   do exist — a later Google sign-in at the same address, or an emailed sign-in
   link — but neither is signposted and one needs you to sign out of a working
   account. Board B.)
2. **The extra step in the Google flow.** `/you/join/:token` — the screen titled
   "One last tap" — shows a second *pixel-identical* "Continue with Google"
   button. The page exists for a real reason; the tap on it is a separate,
   reversible decision.

Nothing here is built. `index.html` is a design deliverable — five boards plus a
worked example and a spec, with numbered callouts keyed to a numbered spec
(§1–§11) at the foot of the same page, so the boards and the technical
implications stay in one document. The spec ends with a costing table.

It is the sibling of `../responder-accounts/` and `../responder-share/` and
continues their fiction — the same Haverley Town Council, the same "Car-free
High Street". Unlike those two, **this deck draws what is actually shipped**:
every screen on board A is the current markup at the current copy out of
`config/locales/en.yml`, and boards that propose new words mark them as
proposed.

## Looking at it

Open `index.html` in a browser, or read `shots/*.png`.

| Board | File |
|---|---|
| Worked example (Priya, and the two doors) | `shots/00-worked-example.png` |
| A · The two doors today, tap by tap | `shots/01-two-doors-today.png` |
| B · What "unverified" costs: the silent account | `shots/02-silent-account.png` |
| C · The verification mail, and what the link opens | `shots/03-verification-mail.png` |
| D · The end card and `/you`, with the address proved | `shots/04-card-and-you.png` |
| E · The Google door, one tap shorter | `shots/05-google-door.png` |
| Spec §1–§11 and the costing table | `shots/06-spec.png` |

## What the deck argues, in five lines

1. **The gate already exists and is already firing.** Nothing needs building to
   *enforce* verification — `PlayerAudience` has refused to mail unverified
   players since it was written. §1 is not "add a gate", it is "give the people
   already behind it a way through". That is why there is no migration:
   `Player` already has `email_verified_at` and an idempotent `verify_email!`.
2. **Nothing else should be gated.** The creator gate is on *publishing* because
   an unproven creator can collect strangers' birth dates under a borrowed
   address. An unproven respondent can only fail to hear back, so the
   consequence and the remedy are the same thing.
3. **The Google interstitial is more load-bearing than its own docstring says,
   but the "extra step" is mostly a copy defect.** The page has to exist:
   `cached_play_page` caches the `/play/:token` HTML as *shared bytes* across
   respondents, so its CSRF token was minted during a stranger's request. What
   makes the step *feel* like a wasted tap is that `_join_block` and
   `player_joins/show` render the **same I18n string** — you press "Continue
   with Google" and arrive at a page whose button is also "Continue with
   Google". Relabel it first (one string, one view line); only then consider
   auto-submitting.
4. **The verification mail re-arms a vector the repo deliberately disarmed.**
   `PLAYER_JOIN_RATE_LIMIT_SCALE` was loosened on 14 September explicitly
   because `#join` no longer sends mail — "which a mail-bomb guard could not
   be". Sending from there makes that env var the multiplier on how many
   strangers one IP may write to, so the mail needs its own unscaled bound. §11
   is the reason P1 is not a half-day change.
5. **Three live bugs sit on this path**, independent of both changes — board E.
   The worst: in an **embedded** Verto neither door can finish. Both end by
   navigating in-frame to `/you/...`, which the global `frame_ancestors :self`
   refuses to be framed by, while `allow_embedding` covers only the player
   pages. So a framed Verto can collect answers and cannot create a single
   account — and `player_embedding_test.rb` contains the word "join" zero
   times. The other two: an already-signed-in respondent loses the run they
   just played, and the venue rate-limit lever does not reach the interstitial.

## Re-shooting and rebuilding

```
cd docs/mockups/respondent-verification
python3 build.py     # assemble index.html from parts/*.html
node shoot.mjs       # screenshot each board to shots/
```

`build.py` concatenates `parts/*.html` and splices the two base64 fonts, the
stylesheet and the shared SVG symbols out of `../responder-accounts/index.html`,
so the three decks stay
visually identical and this one carries no CDN reference either — it works from
`file://` and from any host. It asserts its splice boundaries, so if that file
is restructured the build fails loudly rather than emitting a broken page.
**Edit the files in `parts/`, not `index.html`.**

Playwright comes from the global install and Chromium from `/opt/pw-browsers`
(the same pair `.claude/skills/verify/SKILL.md` uses); override with
`PLAYWRIGHT_DIR` and `CHROMIUM`. `shoot.mjs` fails loudly if a board in its
`BOARDS` list has no matching element, so adding a board means adding one row.

## The PDF

```
node make_pdf.mjs      # per-board parts into .pdf-parts/ (gitignored)
python3 merge_pdf.py   # stitches and numbers them
```

`merge_pdf.py` needs `pymupdf`. It prints the page rather than stitching
`shots/*.png`, so every word stays real vector text. 10 pages.

Two deliberate differences from the siblings' copy of `make_pdf.mjs`, both
because this deck's boards are taller than theirs: the multi-sheet headroom is
**1.30, not 1.18** (board A is a flow strip whose notes column re-balances at
print width, and at 1.18 it spilled a third, nearly empty sheet), and `CAP` is
**2700, not 2000** (at 2000 the sheet height was the binding constraint on the
eleven-item spec, which packed into three and pushed its last 900 characters
onto a fourth). Raise either again if a board ever gains a near-empty page.

## Conventions

Same build-stamp convention as its siblings — bump it in `build.py` when you
change the deck, and check it in view-source to be sure you are looking at the
copy you think you are:

```html
<html lang="en" data-build="2026-09-15-a">
```

It lives under `docs/` rather than `public/` deliberately: `public/` is served in
production, and these are internal design documents.
