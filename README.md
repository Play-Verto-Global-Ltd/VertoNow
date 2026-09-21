# Playverto

A multi-tenant SaaS for building and running **Vertos** — short, game-like
surveys that respondents play rather than fill in. Creators describe what they
want to learn, Claude drafts the deck, and a public player collects responses
that feed live results, AI summaries and exportable reports.

The repository directory is still `Survey-POC` and the git history starts as a
proof of concept. It hasn't been one for a long time: the app has auth,
organisations, partnerships and funder programmes, persistence on Postgres,
background jobs, 19 locales, a PWA player that works offline, and GDPR tooling.

## Stack

- **Rails 8.1** on Ruby 3.3.6 — importmap, Hotwire (Turbo + Stimulus), Tailwind
- **Postgres** in production, SQLite in development and test
- **Solid Queue** for background jobs, **Solid Cache** for `Rails.cache`,
  **Solid Cable** for Action Cable — all on the primary database, no Redis
- **Active Storage** on a Render persistent disk (organisation logos, brand
  asset libraries, card images)
- `anthropic` Ruby SDK — `ClaudeModels::DEFAULT` for generation and analysis,
  `ClaudeModels::FAST` for cheap classification; both overridable by env var
- Deployed to Render from `Main` via `render.yaml`, gated on CI

## Getting started

```bash
bundle install
cp .env.example .env      # ANTHROPIC_API_KEY is required, even to run tests
bin/rails db:prepare
bin/dev                   # Rails + Tailwind watcher
```

Open <http://localhost:3000> and create an account. To get a populated account
instead of an empty one:

```bash
DEMO_PASSWORD='pick-a-passphrase' bin/rails demo:seed
```

That builds `demo@vertonow.com` with three live Vertos, one editable draft and
around a hundred responses — enough for the results screens, the regions map
and the AI report to have something to say. It's idempotent: it destroys and
rebuilds only the demo organisation.

> Every service constructor does `ENV.fetch("ANTHROPIC_API_KEY")`, so the
> variable must exist even though the test suite stubs every Claude client.
> Any value works: `ANTHROPIC_API_KEY=stub bin/rails test`.

## How it fits together

**Creating.** The wizard (`SurveysController#generate`) hands off to
`BuildVertoJob`, which calls `SurveyGenerator`, translates into each secondary
locale, and populates imagery. Vertos can also be imported from a PDF, a Google
Form, or pasted questions. Everything expensive runs in a job — see
`docs/PRODUCTION_READINESS_PLAN.md` P0-3 for why.

**Editing.** `app/javascript/controllers/survey_editor_controller.js` is the
centre of gravity, and its source of truth is the **DOM**: `serialize()`
rebuilds the cards array by reading live markup on every autosave, and new card
markup is always minted server-side via `POST /surveys/:id/render_card`. There
is no render-from-JSON path, which constrains anything that wants to
reconstruct a card client-side.

**Playing.** `/play/:token` is a PWA served through a Service Worker —
network-first with an offline cache fallback for the player HTML. Answers are
keyed by **card index**, which is why a deck
freezes once responses exist — see `Survey#editing_locked?`. The verified
accounts in `LIVE_EDIT_USER_EMAILS` (`LiveEditAccess`; the owner by default)
may edit a frozen deck anyway, with the editor warning what that does to
stored answers.

**Analysing.** Live results over Action Cable, streamed AI summaries and chat, a
generated report with PDF and Google Docs/Sheets export, and cross-Verto
aggregation for Common Question sets shared across an organisation or a funder
programme.

## Working in this repo

Read `CLAUDE.md` first — it carries the working agreements, including when a
`CACHE_VERSION` bump is (and is no longer) required.

The four gates, all of which must pass before pushing to `Main`:

```bash
bin/rails test          # ~1,200 tests across 150+ files
bin/rubocop
bin/brakeman --no-pager
bin/importmap audit
```

A few things that surprise people:

- **`Main` has a capital M.** GitHub Actions branch filters are case-sensitive;
  `ci.yml` watches both spellings.
- **Locale strings live in 19 files** under `config/locales/`, all mirroring
  `en.yml`. A string the browser needs must go under the `js:` namespace, or it
  renders to respondents as a raw key.
- **A `CACHE_VERSION` bump is needed only for service-worker behaviour
  changes** (`app/views/pwa/service-worker.js.erb` — strategies, submit queue,
  cache layout). Player content/markup/CSS fixes ship on their own: the
  player HTML is network-first, so respondents pick them up on their next
  ordinary online visit.
- **Deploys are gated on CI.** Render runs the image CI builds
  (`ghcr.io/play-verto-global-ltd/vertonow`): once every other job is green on
  a commit, the `deploy` job moves the `main` tag onto that commit's image and
  POSTs the Render deploy hook naming it, so a red push to `Main` doesn't
  ship — but don't lean on that; push green.

## Documentation

| Document | What's in it |
|---|---|
| `CLAUDE.md` | Working agreements, git workflow, gotchas |
| `docs/PRODUCTION_READINESS_PLAN.md` | The P0/P1/P2 hardening plan and what's been done |
| `docs/DATA_RETENTION.md` | What's stored about respondents, for how long, and how to answer an access or erasure request |
| `docs/DEPLOYMENT_RUNBOOK.md` | Deploy, rollback, and the one-time service setup |
| `docs/TOOLING_AND_VENDORS.md` | Third-party services and what each one costs |
| `docs/how-vertos-get-their-imagery.md` | The asset pipeline: Pexels, the brand library, moderation |

## Status

P0 (launch blockers) is complete. P1 is largely done, with the remaining items
gated on operational access rather than code — backup verification, encryption-key
escrow, a read-only Blazer role. P2 is quality and scale work: accessibility,
browser tests, `json` → `jsonb`.

There is **no billing or usage metering** of any kind, which is the outstanding
prerequisite for charging anyone.
