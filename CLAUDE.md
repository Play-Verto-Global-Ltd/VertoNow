# Survey-POC (Playverto)

Rails 8 app (importmap, Stimulus/Turbo, Tailwind, sqlite in dev/test, Postgres in prod).
"Verto" = a survey; the public respondent player lives at `/play/:token`.

## Git workflow — push to Main

Work happens **directly on the `Main` branch** (note the capital M — it's the
default branch). Do NOT create or push `claude/*` session branches or open PRs
unless the owner asks for one — repo owner's standing instruction, 2026-06-11.

Before every push to Main, the full local suite must be green:

```
bin/rails test        # ~3,400 tests, ~70s with one worker per core
bin/rails test:system # ~500 browser tests, run on its own, ~5 min at 4 workers
bin/rubocop
bin/brakeman --no-pager
bin/importmap audit
```

`bin/gate` runs exactly those five, in that order, and is the way to run them:
it fetches first and refuses to start if the branch is behind origin, runs the
three static checks alongside the system suite, prints one summary line with
real durations plus the `--test` flags for `bin/trello_log`, and fetches again
at the end to say whether a push is still safe. Logs land in `tmp/gate/`, and
so does a copy of a failed system run's screenshots — the rerun that tries to
reproduce the failure empties `tmp/capybara` at load (`KEEP_TEST_STORAGE=1`
keeps it).

It also **fetches every 45 seconds throughout** and aborts the moment origin
moves, rather than telling you at the end — a push that lands in minute one
used to cost you the other six. And `bin/gate --push` pushes the instant it
comes back green, which is the only way to close the gap between "safe to
push" and the push; it refuses a dirty tree, because the checks run on the
working tree and the push sends the commit. The header prints the measured
push rate and what it implies for a run this long, so that cost is a number
rather than a feeling. Exit 2 is behind-at-the-start, 3 is origin moved.

**The full system suite runs before EVERY push — including after a rebase, and
including when the commits you rebased onto touch none of your files.** No
shortcut on the grounds that the overlap is zero, that the suite passed before
the rebase, or that the change is server-side and "covered by the integration
tests". Owner's standing instruction, 2026-08-25, after exactly that reasoning
was used to skip one.

Other sessions push to Main through the day, so even a ten-minute gate often
finishes to find origin has moved. Rebase and run it again. Losing the race is
the expected cost, not a reason to trim the gate.

**Run the gate in the foreground, and never end a turn while it or CI is still
running.** A session that reports "suite running" and stops is not waiting —
nothing wakes it when the run finishes, so the result is never read and the
push never happens. Backgrounding the suite was the right adaptation when it
took 25 minutes; at ~6½ it fits inside a single turn, and the adaptation now
costs far more than it saves. Measured across 12–14 September, this was the
single largest source of lost time in the repo — larger than every CI failure,
merge conflict and push collision combined: one change its own author had
scoped at twenty minutes sat **12h45m** because the session parked and never
processed two messages about it; another pushed with `rails test:system` still
running, recorded in its own commit message; a third went idle reporting "CI
running on main", leaving nobody watching the one job that can still fail.
Drive a change through to pushed-and-logged in one turn, or say plainly what is
blocking and stop on purpose. Owner's standing instruction, 2026-09-14.

**A check you start is a check you wait for — including the ones you invent.**
The rule above is about `bin/gate`, but it generalises to any gate a session
sets for itself: a review workflow, a subagent fan-out, a second opinion you
commissioned. If its verdict would change what you push, the push waits for it;
if it wouldn't, don't run it. 14 September, a 128-agent adversarial review
titled "before it goes to Main" was still running when its own diff was pushed.
It deserved to exist — between them those reviewers found a thank-you message
box collapsed to `display: none` on the one surface whose whole job is typing
that message, a Preview handing creators the editor's placeholder as though it
were the respondent's copy, a translation cache key that would have left the new
scale captions in the source language in all 25 other languages, and a digest
change that would have made every translation approval in the product read
"Approved, then edited". All of it arrived thirty-one minutes AFTER the code
deployed, because nobody waited. A gate you don't wait for is a post-mortem.

**Size a check to the decision it informs.** In that same run five reviewers
produced every finding that reached the fix-forward commit, and a 123-agent
verify phase then spent the bulk of the budget re-checking conclusions already
implemented and shipped. Fan out to find things, not to audit the finders; and
when a phase can no longer change what you push, stop it rather than let it
finish. Every session on this repo draws on one weekly usage budget shared with
every other session running that day — an afternoon of four sessions shipping is
worth more than one session's exhaustive proof of a diff that is already live.
Owner's standing instruction, 2026-09-14.

**Render a visual change and look at it before you spend a gate on it.** The
`/verify` skill drives the real app; `test/application_system_test_case.rb`
already builds the CSS. Either is seconds against seven and a half minutes. On
14 September one piece of feedback about card backgrounds took six commits and
six gates, and three of them — the white panel that should not have been
there, the answer row you could see the photograph through, the scrim dimming
the texture a creator had just chosen — are things that looking at the render
would have caught and no test was ever going to. The other three were misread
briefs, which a render does NOT catch: this buys you the *look* being wrong,
not the *ask* being wrong. Reread the request for that.

**Tried and rejected, so nobody rebuilds it:** a push queue or a lock, so
sessions take turns on the gate. Pushes arrive at ~3.5/hour against a
7.5-minute gate — 45% utilisation, which queues about six minutes of waiting
to save 4.3 minutes of re-running, and collapses in exactly the 17:00-style
bursts that are the problem. Also rejected: timing a push for a quiet moment.
Arrivals are Poisson and therefore memoryless — there is no quiet moment to
aim for, and a session waiting for one is a session not running the suite.

**A red Main is fixed with a new commit, never with a re-run.** When a push
turns CI red, land a fix-forward or a `git revert` — a NEW commit, gated like
any other — rather than pressing "Re-run failed jobs" to get green. Every CI
failure in this repo's history has been a browser test that raced (six in 80
runs, zero product regressions caught), so a re-run's likely outcome is a
green-by-luck that hides a race the local gate cannot see: by definition it
passed locally. A red run withholds only its own deploy; the next green push
deploys the branch head, so speed matters less than the new commit being
gated. The one legitimate retry is a run that never started
(`startup_failure`): a `workflow_dispatch` on Main. Owner's standing
instruction, 2026-09-13. The nightly flake hunt
(`.github/workflows/flake_hunt.yml`) is where races are meant to be found
first — read its red runs before they reach a push.

Both suites fork **one worker per core** (`test/test_helper.rb`); each worker
gets its own SQLite file and, for system tests, its own Puma and Chrome.
`PARALLEL_WORKERS=N` overrides that — never above the core count (6 workers on
4 cores flaked three browser timings, 2026-09-12), and `PARALLEL_WORKERS=1` is
the old serial run for bisecting a cross-test interaction. A test that writes a
file must name it per test or per process (`SecureRandom`, `Process.pid`):
`public/` and `tmp/` are shared by every worker.

## Work log (Trello)

After a push to Main passes the local suite (i.e. you're actually pushing),
log a card summarizing what shipped:

```
bin/trello_log "Short title of what shipped" "1-3 sentence summary" \
  --frontend "What changed in views/Stimulus/Tailwind, if anything." \
  --backend "What changed in models/controllers/services, if anything." \
  --test "rails test:pass" --test "rails test:system:pass" --test "rubocop:pass" \
  --test "brakeman:pass" --test "importmap audit:pass" \
  --screenshot tmp/screenshots/whatever.png \
  --points 5
```

This posts to the current week's list on the team's Trello board
(https://trello.com/b/ntNghZRN) via the REST API — `Done - Week of 10th
August 2026`-style, weeks running Monday–Sunday, named for the Monday. The
list is found-or-created automatically, with the newest week kept leftmost of
the weekly block; setting `TRELLO_LIST_NAME` still targets that list verbatim
instead. Cards land newest-first, directly under the week's pinned summary
card (see below). (`bin/trello_backfill_done_weeks` regroups an old flat `Done` list
into weekly lists, should one reappear.) `--frontend`/`--backend` are
rendered as `## Frontend`/`## Backend` sections in the card description —
omit whichever side didn't change. `--test NAME:STATUS` (repeatable) adds a
"Tests" checklist item per suite, checked iff STATUS is `pass` — use the
actual result of the five commands above, not a guess (`bin/gate` prints the
flags ready to paste). `--screenshot PATH`
(repeatable) attaches a mockup/screenshot file to the card; only pass this
when the change is user-visible and a screenshot was actually taken (e.g. via
the `/verify` skill) — don't invent one. `--points N` sets a Fibonacci story
point value (1, 2, 3, 5, 8, 13) as a card label, colored by the board's
default label colors (green → blue as complexity rises) — estimate it
yourself based on the size/risk of the change, the same way you judge test
results, don't skip it out of laziness. All flags are optional; a bare
`bin/trello_log "title" "summary"` still works exactly as before.

Requires `TRELLO_API_KEY` and `TRELLO_TOKEN` env vars (set at the environment
level, never committed). If they're not present in this session, skip logging
rather than failing the push — the code change is what matters, the log
entry is best-effort.

Each weekly list also carries a pinned `Week summary — N pts · M cards` card
maintained by `bin/trello_week_summary` (no args = the week containing today,
UTC; `--week DATE`; `--all` for every weekly list; `--dry-run` to preview):
story-point totals, frontend/backend split, test-checklist tally, and
Claude-written theme highlights (`CLAUDE_MODEL_FAST`; falls back to a plain
title list when `ANTHROPIC_API_KEY` is absent or the call fails). A Claude
session running without that key should compose the bullets itself instead:
`--print-cards` emits the week's card lines, `--highlights PATH` (or `-`)
feeds the composed bullets back in place of the API call. The
`Week summary` title prefix is **reserved** — never `bin/trello_log` a card
whose title starts with it. A scheduled Sunday-evening task re-runs the
script for the closing week; re-runs idempotently update the existing card
(cards logged late Sunday are picked up by the next run), so there's no need
to run it after every push.

## Deploys

Render runs the production image CI builds, pulled from
`ghcr.io/play-verto-global-ltd/vertonow` (image-backed since 2026-09-13: a
source build was 2–3 min per deploy, a pull is about one; in the org's own
namespace since the repo moved there 2026-09-21, so CI's token can write it
without a cross-account grant — `ghcr.io/napps9/survey-poc` still holds every
pre-move `:<sha>`, which is what a rollback past it pulls). Every Main run
pushes `:<sha>`; once
every other job in `.github/workflows/ci.yml` (test, test_postgres,
system_test, lint, scan_ruby, scan_js, build_image) is green, the `deploy` job
moves `:main` onto that sha and POSTs the service's Deploy Hook naming it — so
`:main` always means the last green commit, and the deploy is of the exact
image CI proved. Image-backed services have no auto-deploy: that hook is the
only automated path, and the job goes red rather than quiet if the secret is missing or
the POST fails. A `workflow_dispatch` on Main deploys too — that is the
recovery for a run that died with `startup_failure`; the dashboard's Manual
Deploy → "Deploy latest reference" pulls `:main`, the last green commit (after
a dashboard rollback that is the build rolled back from, so fix forward
first). A red push to Main therefore doesn't deploy — but don't rely on that:
push green.
The switch itself (dashboard, `render.yaml`) is in `docs/DEPLOYMENT_RUNBOOK.md`
§7.

## Gotchas

- Importing a partner's survey export means writing a **deck**
  (`app/lib/verto_decks/`), not editing `VertoCsvImporter` — the importer is the
  machinery, a deck is the questions and the account. Spec ORDER is card order
  is the positional key every answer is stored under, so reordering a deck after
  an import re-points every stored answer. `IMPORT_DECK=<key>` selects one;
  `VertoDecks.available` lists them.
- Some exports carry a data column their header doesn't name, and the two halves
  of one export can be shifted **differently** — WLL's paper file is +1 to the
  end, its digital file is +1 for six preamble columns and then aligned again.
  `VertoExportLayout` measures the preamble and the questions separately and
  refuses an ambiguous file. Don't replace it with a fixed offset: the importer
  reads every column by name, so a wrong offset produces a clean-looking import
  of comprehensively wrong answers.
- The partner export CSVs **are** committed, gzipped, under
  `db/seeds/exports/` (~18MB — deliberate, so any checkout can run the
  runbook's import; see `docs/DEPLOYMENT_RUNBOOK.md` §2). Anything not
  already in that directory is handed over out of band.
- The test suite stubs all Anthropic clients, but service constructors do
  `ENV.fetch("ANTHROPIC_API_KEY")` — the var must exist (any value) to run
  tests. CI sets a stub value.
- GitHub Actions branch filters are case-sensitive: the branch is `Main`,
  not `main` (ci.yml watches both).
- Locale strings live in 26 files under `config/locales/` — new UI strings
  must be added to all of them (they mirror en.yml's structure).
  **`en-US.yml` is GENERATED**, not hand-written: `bin/rails i18n:en_us`
  respells en.yml through `EnglishSpellings` (a word list, because "analysis",
  "promise" and "otherwise" are identical in both variants and a rule mangles
  them). Add your string to en.yml and the other 24, then regenerate;
  `LocaleEnUsTest` fails if the file is stale or if en.yml grows a spelling the
  word list hasn't decided about. `bin/rails i18n:translate` skips English
  variants for the same reason.
  `test/lib/locale_structure_parity_test.rb` enforces this for the
  browser-facing namespaces (`js`, `defaults`, `card`, `templates`,
  `demographics`, `ask`, `unsubscribe`, plus the five respondent-account ones);
  JS reads strings via
  `window.I18N`, which carries `js:` plus the curated slice in
  `app/views/layouts/_i18n_js.html.erb` — a JS-facing string anywhere else
  renders as a raw dotted key.
- `bin/rails i18n:translate` has the same escape hatch as
  `bin/trello_week_summary`, for a session with no `ANTHROPIC_API_KEY`:
  `PRINT=path|1` dumps the missing keys as `{locale => {key => english}}` JSON
  and stops, and `TRANSLATIONS=path` reads that shape back and writes it. A
  Claude session composes the translations itself in between. Both modes build
  the API client lazily, so neither trips the eager `ENV.fetch`.
  Three things the writer will not do, all of them measured rather than
  assumed: it **appends** rather than re-emitting the file (regenerating
  `fr.yml` from a Hash rewrites 1,224 of its 1,896 lines and destroys every
  comment — the files are hand-quoted and Psych emits minimal quoting), it
  re-parses what it wrote and reverts if any pre-existing leaf moved, and it
  refuses a locale with no file (`zh` is in `SupportedLocales.codes` but has no
  `zh.yml`; creating one would enter it into three parity suites and the
  language switcher). Expect **+N lines, 0 deletions** per file; a deletion
  means stop. Placeholders are checked against the English source on the way
  in — `LocaleProperties` holds the scanner so the task and the parity suites
  check the same thing.
- Dev/test run SQLite; production runs Postgres, and they disagree on real
  things — `LOWER()` on a `json` column and `DISTINCT` over rows containing
  one both pass SQLite and 500 on Postgres (this took Ask Verto down in prod,
  2026-08-12). Raw SQL must run on both engines (`LOWER(CAST(col AS TEXT))`,
  dedupe via id-subquery instead of `.distinct` on full rows). CI's
  `test_postgres` job runs the whole suite on Postgres to catch this class;
  keep it green, don't delete it to get a deploy out.
- Dashboard/player styling is mostly inline `style` attributes plus classes
  in `app/assets/tailwind/application.css`; match the file you're editing.
- System tests render the **compiled** `app/assets/builds/tailwind.css`, which is
  gitignored and is NOT rebuilt just because `app/assets/tailwind/application.css`
  changed underneath it — `bin/rails test:system` passes a path argument, and any
  path argument skips `test:prepare` (and this app leaves the test_unit railtie
  off, so there is no `test:prepare` anyway); only `db:test:prepare` builds it.
  So `test/application_system_test_case.rb` builds it itself, once per run, at
  load: every way of running system tests sees the CSS of the tree it is
  testing. `SKIP_TAILWIND_BUILD=1` opts out. 2026-08-14, a stale build made a
  passing fan-arc test look like a geometry bug in someone else's commit;
  2026-09-12 it failed a locked-feed test twice, in the gate run that added the
  build.
- System tests pay for waits, not for pages: a bare player visit is 0.7s. The
  base class (`test/application_system_test_case.rb`) carries the idioms that
  keep it that way — `agree_to_consent_gate` (reads the server-rendered gate,
  never waits for a button that isn't coming; `SystemTestHygieneTest` bans the
  old three-second guard), `sign_in_as` (mints the session cookie; the form
  has its own test), `dismiss_cookie_banner` (the cookie is preset; the call
  now waits for the page's Stimulus controllers to connect, which the
  Accept-all click used to do by accident), `wait_until` for a server-side
  state, `settle_box` before reading geometry. A fixed `sleep` is for proving
  nothing happens; for anything that does happen, wait for it.
- The PDF renders (report + share card) exec wkhtmltopdf from the
  `wkhtmltopdf-binary` gem. The suite passes on Ubuntu runners because they
  already carry its shared libraries; production is `ruby:slim`, which
  doesn't, and the gem inflates its gzipped binary into the root-owned gem
  dir on first use while the app runs as uid 1000. The `Dockerfile` installs
  the libs and runs `bundle exec wkhtmltopdf --version` as root so the image
  build fails if either regresses — a green suite says nothing about it.
  The Drive export needs the **Google Drive API** enabled on the Cloud
  project (the Sheets export only needs the Sheets API); a 403 there is
  passed through to the modal rather than shown as "try again".
- `/play/:token` is served through a Service Worker (`app/views/pwa/service-worker.js.erb`)
  with **network-first (3.5s timeout) + offline cache fallback** for the
  player HTML. Content/markup/CSS fixes therefore reach respondents on their
  next ordinary online visit with **no** `CACHE_VERSION` bump. A bump is
  still required when the **worker's own behaviour** changes (caching
  strategies, the submit queue, cache layout) — and the `controllerchange`
  reload in `app/javascript/sw_register.js` delivers such worker changes
  same-visit. History: the HTML used to be stale-while-revalidate, which
  pinned respondents on stale copies (one deploy shipped invisibly until a
  v2→v3 bump) — that's why it's network-first now; don't quietly revert it.
  A 502/503/504 on a player navigation is Render answering for an app that
  isn't there (every deploy is a stop/start while the service has its disk),
  and the worker answers it with the cached Verto or `public/deploying.html`
  — the branded "we're deploying" page, inlined into the worker by the one
  ERB tag in that file. The studio and first-time visitors still see Render's
  page; `docs/DEPLOYMENT_RUNBOOK.md` §8 says how to show them ours.
