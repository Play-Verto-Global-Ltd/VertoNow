# Playverto — Tooling & Vendor Selection Guide

_Companion to `PRODUCTION_READINESS_PLAN.md`. Researched 2026-07 with live pricing;
confirm the exact figure on each vendor's page before committing — prices move._

This guide picks the concrete tools/services needed to execute the readiness plan,
tuned to the actual constraints: **Rails 8, Render (single 512 MB instance),
Postgres already provisioned, cost-sensitive early stage, possibly EU respondents.**

## The one-line answer

Lean on **Postgres for infrastructure** (Rails 8 Solid stack — zero new services),
**Cloudflare R2 for files** (zero egress), **a single Rails-native observability
vendor**, **a Merchant-of-Record for billing** (offload EU VAT), and a
**minimal, mostly-free compliance kit**. Net new fixed cost to get production-ready
is roughly **$0–35/month** beyond current hosting, plus a % of revenue once billing
is live.

---

## Recommended stack at a glance

| Need | Plan item | Recommended | Cost | New infra? |
|------|-----------|-------------|------|------------|
| Background jobs | P0-3 | **Solid Queue** (Postgres), in-Puma non-forking worker | $0 | No |
| Cache store | P0-5 | **Solid Cache** (Postgres) | $0 | No |
| WebSocket adapter | P1-1 | **Solid Cable** (Postgres) or `async`; delete the dead Redis config | $0 | No |
| Object storage | P0-1, P1-7 | **Cloudflare R2** (zero egress) | ~$0 (free tier) | External bucket |
| Transactional email | P0-8, P2-6 | **Postmark** (or Resend to start free) | $15/mo (or $0) | External |
| Error + APM + uptime | P0-2 | **AppSignal** all-in-one (or **Sentry** if EU/PII residency matters) | $0 → ~$23/mo | External |
| Uptime/status (free supplement) | P0-2, P1-3 | **Render notifications** (on) + **Better Stack** free status page | $0 | External |
| Billing / subscriptions | CT-2, P0-4 | **Paddle** (Merchant of Record) via the **`pay`** gem | % of revenue | External |
| Legal policies | P0-6 | **iubenda** (~$7/mo) or **Termly** ($14/mo) | ~$7–14/mo | External |
| Cookie consent | P0-6 | **Not needed** since Clarity was removed (2026-10-01) — only strictly necessary cookies remain; **orestbida/cookieconsent** (open-source) if a tracker ever comes back, see below | $0 | No |
| GDPR export/erasure | P0-7 | **Build in Rails**, optionally on the **gdpr_admin** gem | $0 | No |
| Rate limiting | P0-4 | Keep Rails 8 **`rate_limit`**; add **rack-attack** only if abused | $0 | No |

---

## 1. Jobs / Cache / Cable — the Rails 8 "Solid" stack (all on existing Postgres)

**Decision: adopt Solid Queue + Solid Cache + Solid Cable, all backed by the
existing Render Postgres. Net new infra: none. Net new cost: $0/mo.** The
alternative (Sidekiq/Redis) adds **$10–17/mo** and a stateful service to operate,
buying throughput this workload doesn't need.

**Why it fits here specifically:** the AI jobs are **I/O-bound** — a Claude call
spends 30–120s *waiting on the Anthropic API*, releasing Ruby's GVL. So workers can
be **threads inside the existing Puma process**, costing almost no CPU or RAM.

- **Jobs — Solid Queue, run in-Puma in _non-forking_ (threaded) mode.** Not a
  separate Render worker service (+$7/mo, overkill now) and **not** the default
  *forking* Puma-plugin mode (forks a second ~150–250 MB Rails process — dangerous
  on a memory-tuned 512 MB box already running jemalloc + a cgroup memory
  watchdog).
  Non-forking runs workers as threads with near-zero extra RAM. Keep worker
  threads low (2–3) and ensure the DB pool ≥ web threads + worker threads.
  - _Alternative worth knowing:_ **GoodJob** (also Postgres, built-in dashboard,
    lower LISTEN/NOTIFY latency) — its own maintainer still recommends it for
    Postgres apps. For 30–120s jobs the latency edge is irrelevant, so Solid Queue
    wins on being the zero-decision Rails default. **Sidekiq** only pulls ahead
    above ~3,000 jobs/min — nowhere near current scale.
- **Cache — Solid Cache.** Fixes the real bug that `rate_limit` counters and
  geocode caches currently live in an ephemeral per-process file store (wiped every
  deploy, not shared). DB-cache latency is theoretically higher but a non-issue at
  this volume; durability matters more.
- **Cable — Solid Cable** (or `async`, since you run a single Puma process). Either
  way **delete the production `redis` adapter + `REDIS_URL`** so the broken pointer
  can't bite once someone adds a broadcast. Latent today (no broadcasts exist).

**Migration sketch:** `bundle add solid_queue solid_cache solid_cable` → run
installers → set `queue_adapter = :solid_queue` and `cache_store = :solid_cache_store`
in `production.rb` → point Solid tables at the existing `survey-poc-db` → enable the
Puma plugin non-forking → move the 30–120s Claude generation into a job. Watch
[solid_queue#617](https://github.com/rails/solid_queue/issues/617) (Puma-plugin boot
ordering on Render) and confirm `db:prepare` creates the Solid tables before Puma
starts the plugin. **Upgrade path:** promote to a dedicated `type: worker` service
(+~$7/mo) only if a CPU-heavy job later starves web requests.

_Render Key Value (managed Valkey/Redis) exists if you ever reject the Solid stack:
Free tier is ephemeral (disqualified for durable jobs); Starter ≈ $10/mo (256 MB,
persistent), Starter Plus ≈ $18/mo (512 MB)._

---

## 2. Object storage — Cloudflare R2

**Decision: migrate Active Storage from local disk to Cloudflare R2.** Runner-up:
Backblaze B2. **Do not use Render Persistent Disk** for user uploads — it pins the
app to one instance, has no CDN, and re-couples storage to the app lifecycle (the
exact misconfiguration being fixed).

- **Why R2:** **zero egress fees** is the whole game — survey images are served to
  many respondents on the public `/play/:token` player, and on S3 a single
  image-heavy viral survey can run up egress bills that dwarf storage. R2's edge
  bandwidth is free, it's cheaper per-GB than S3/GCS ($0.015/GB), and Playverto
  sits inside R2's **permanent** free tier (10 GB + generous ops) for a long time —
  realistically **$0/mo**. Fully S3-compatible, so use Rails' built-in `S3Service`
  with just the `aws-sdk-s3` gem.
- **Setup gotcha to bake in:** recent `aws-sdk-s3` sends CRC32 integrity checksums
  that R2 rejects. Set `request_checksum_calculation: "when_required"` (and
  `response_checksum_validation: "when_required"`) on the S3 client. Single most
  common R2+Rails friction point; trivial once known.
- Pricing anchors: S3 egress $0.09/GB, GCS $0.12/GB — both charge per respondent
  view; R2 and (via Cloudflare) B2 do not.

This also unblocks **P1-7** (moving multi-MB base64 images out of DB columns into
Active Storage references — the acknowledged 502/OOM driver).

---

## 3. Transactional email — Postmark (or start on Resend)

**Decision: Postmark for deliverability-critical auth mail.** A password reset in
spam = a locked-out customer.

- **Postmark** — the transactional deliverability benchmark; separate Message
  Streams keep auth mail off any marketing reputation pool; first-class
  `postmark-rails` ActionMailer adapter; guided DKIM; **EU (Germany) data region**
  for GDPR. Free 100/mo for a pilot, then **$15/mo for 10k**.
- **Resend** (runner-up / best free start) — **3,000/mo free**, official Rails SDK,
  clean DX. Caveats vs Postmark: younger transactional track record; **EU residency
  is Pro-plan only**.
- **Brevo** — pick this if **EU-default data residency is a hard requirement**
  (EU-native, 300/day free), accepting a more marketing-oriented platform.
- Avoid as primary: **SES** (you own reputation/warmup — wrong tradeoff early),
  **SendGrid** (no permanent free tier now), **Mailgun** (pricier for less
  transactional focus).

Pairs with **P2-6**: also set `default_url_options` in production and fail loudly if
SMTP/API isn't configured (today mail silently no-ops).

---

## 4. Observability — one Rails-native vendor

**Decision: AppSignal free plan as the single tool for error tracking + APM + host
metrics + uptime + logs** — one gem, one `APPSIGNAL_PUSH_API_KEY`, ~15-min setup,
flat pricing ($0 on 50k req/mo → ~$23/mo at 250k). Minimizes vendor sprawl.

- **Supplement (free, do immediately):** turn on **Render's own** deploy/health
  notifications (email/Slack) — already there, off by default.
- **Supplement (free, optional):** **Better Stack** free tier for a customer-facing
  status page + an independent external uptime vantage point.
- **512 MB caveat:** AppSignal runs a small standalone agent process alongside Ruby
  — confirm memory headroom after enabling on the tuned instance.

**Choose Sentry instead if GDPR/EU data-residency for error payloads is a priority.**
Sentry has a documented **EU region (Frankfurt)** and mature **PII scrubbing**
(`send_default_pii` off + server-side scrubbing) — important because respondent birth
dates/locations can otherwise leak into stack traces. Trade-off: Sentry is
error+performance only (no host metrics), so you'd add uptime separately. Sentry Team
is ~$26/mo; its free Developer tier is thinner than AppSignal's.
_Other alternates:_ **Honeybadger** (free errors+uptime+cron; APM at $26/mo),
**New Relic** (most generous free tier — 100 GB/mo — but heavy and a hard cutoff).

> Note: AppSignal's plans page blocked automated fetch, so its free-tier numbers are
> corroborated from third-party reviews — verify on appsignal.com/plans. Given the
> EU/PII-scrubbing story, **Sentry (EU region) is the safer default if EU respondents
> are in scope**; AppSignal wins purely on all-in-one value if residency isn't a driver.

**Log management:** not worth a paid vendor yet. Use AppSignal's bundled 1 GB, or
wire a Render log stream to **Better Stack Logs** (3 GB free) / **Papertrail**
(50 MB free). Add **cron/job liveness** checks (AppSignal check-ins or
Healthchecks.io free) once background jobs land.

---

## 5. Billing — Paddle (Merchant of Record) via the `pay` gem

**Decision: use a Merchant of Record, specifically Paddle, integrated through the
`pay` gem.** For a small team selling digital subscriptions into the EU, **an MoR is
worth the ~1.5–2 point fee premium over Stripe** because it makes EU VAT / global
tax registration, remittance, and invoicing *disappear* — non-differentiating work
you shouldn't build.

- **Paddle** — MoR, **~5% + $0.50** all-in, no monthly fee; handles VAT/GST/sales
  tax in 200+ territories; first-class **`pay`** gem support (Paddle Billing); usage
  metering adequate for standard cases.
- **Stripe Billing** — more powerful metering (incl. 2026 AI-usage metering: meter
  tokens, auto-markup over model cost) but **you become merchant of record** and own
  EU VAT compliance. Best long-term engine if usage-based becomes the primary
  pricing axis; also first-class in `pay`, so **starting on Paddle and migrating to
  Stripe later is feasible**.
- Skip **Lemon Squeezy** (being absorbed into Stripe Managed Payments — watch that
  emerging MoR) and **Chargebee** ($599/mo tier, no `pay` support, doesn't solve
  tax) for a new early-stage build.

**Metering pattern (ties to P0-4):** model pricing as **subscription tier + metered
AI overage**. Critically — **your own in-app per-org quota is the real cost
guardrail** (it stops runaway Claude spend); the billing processor only *charges*.
So build the usage-counting primitive once and use it for both P0-4 enforcement and
CT-3 overage billing. Note `pay` covers the subscription lifecycle but you report
usage via the processor SDK directly (e.g. Stripe `Billing::MeterEvent`).

---

## 6. GDPR / privacy / consent — minimal viable kit

Playverto collects respondent **location + birth date** — personal data — so this is
a launch requirement (plan P0-6/P0-7), not optional.

**Concrete findings from the codebase that raise the stakes:**

- ✅ **Microsoft Clarity is gone** (removed 2026-10-01). It used to load
  unconditionally on every page, including the public player where respondents
  are (session-recording analytics, tag `wyq1mb82dv`); Clarity sets tracking
  cookies and records sessions, which under GDPR/ePrivacy is **non-essential and
  requires prior consent**. It was first gated behind a cookie-consent banner,
  then removed along with the banner: with no non-essential cookies left there
  was nothing to consent to. **Any future tracker brings the whole requirement
  back** — prior consent, a banner to collect it, and its hosts in the CSP.
- ⚠️ **Google Fonts are loaded from Google's CDN** (`fonts.googleapis.com` /
  `gstatic.com`, same file). German courts have ruled that serving Google Fonts from
  Google's servers (transmitting visitor IPs to Google) violates GDPR.
  **Self-host the fonts** to remove that transfer.

**Toolset:**

- **Policies (Privacy Policy + Terms + cookie policy) — buy it, it's cheap and it's
  legal text you shouldn't hand-roll.** **iubenda** (~$7/mo, EU-focused,
  auto-updating clauses) or **Termly** ($14/mo, bundles a cookie banner). Clear
  "pay for it."
- **Cookie consent — none needed today.** With Clarity gone the site sets only
  strictly necessary cookies, which need no consent. If a tracker is ever added,
  gate it behind **orestbida/cookieconsent** (self-hosted, importmap/Tailwind-
  friendly) with granular consent. **Do not** buy Cookiebot/Osano — a paid CMP
  solves a problem you don't have at this scale. Clear "use free."
- **Data-subject rights (export/erasure) — build in Rails**, optionally scaffolded
  by the **gdpr_admin** gem (async export/erasure + audit trail; you implement
  `#scope`/`#export`/`#erase` per model). Anonymize rather than hard-delete (null
  the birth date, coarsen/drop location, revoke consent); respond within 30 days;
  export as JSON/CSV. Clear "build it."
- **Data residency for every US vendor touching PII** (Render, error tracker, email,
  Paddle): **(1)** sign its DPA, **(2)** rely on EU-US DPF certification + SCCs,
  **(3)** pin the EU region where offered (Render has EU/Frankfurt; Sentry has EU;
  Postmark has EU), **(4)** minimize/scrub PII sent to it, **(5)** list all as
  sub-processors in the Privacy Policy.

---

## Rough monthly cost to get production-ready

| Line | Now (pilot) | At light scale |
|------|-------------|----------------|
| Solid stack (jobs/cache/cable) | $0 | $0 (or +$7 dedicated worker) |
| Cloudflare R2 | $0 (free tier) | a few $ |
| Transactional email | $0 (Resend free) → $15 (Postmark) | $15 |
| Observability | $0 (AppSignal/Sentry free) | ~$23–26 |
| Uptime / status | $0 (Render + Better Stack free) | $0 |
| Legal policies | ~$7–14 | ~$7–14 |
| Cookie consent / DSAR | $0 (OSS + build) | $0 |
| Billing (Paddle) | % of revenue only | ~5% + $0.50/txn |
| **New fixed cost beyond current hosting** | **~$0–29/mo** | **~$45–58/mo** |

Everything infrastructural rides on the Postgres you already pay for. The deliberate
theme: **spend on deliverability, legal text, and tax compliance; use Postgres and
open-source for everything else.**

---

## Suggested procurement order (matches the plan's P0 sequence)

1. **Free, immediate:** enable Render notifications; add AppSignal **or** Sentry
   (pick per EU-residency need). → unblocks P0-2.
2. **Cloudflare R2** account + bucket; wire Active Storage. → unblocks P0-1 (+ P1-7).
3. **Solid gems** on the existing Postgres; move AI to background jobs; set Solid
   Cache. → unblocks P0-3 and P0-5.
4. **Postmark** (or Resend) for email. → supports P0-8.
5. **Compliance:** self-host fonts (done), remove Clarity (done 2026-10-01 —
   no consent banner is needed while nothing non-essential is set), buy
   iubenda/Termly policies, build the Rails DSAR flow. → unblocks P0-6/P0-7.
6. **Billing (Paddle + `pay`)** once pricing/packaging is decided. → Commercial track.
