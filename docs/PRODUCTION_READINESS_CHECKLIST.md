# Playverto — Production & Customer Readiness Checklist

_Flat, actionable version of `PRODUCTION_READINESS_PLAN.md` + `TOOLING_AND_VENDORS.md`.
Check items off as you go. IDs (P0-x / P1-x / P2-x / CT-x) map back to the plan;
CR-x items live in `CUSTOMER_READINESS.md`._

## ✅ Shipped
- [x] **Template gallery** (`/templates`) — CR-2 / CR-7. Six ready-made decks
  (NPS, CSAT, onboarding, employee pulse, event feedback, product-market fit);
  one click instantiates a full editable Verto with no AI call/cost. Entry points
  on the dashboard hero + empty state; localised across all 19 locales. Suite +
  RuboCop + Brakeman + importmap-audit green; on `Main`.

## Requested by clients
- [ ] **Forms mode** — clients are asking for a traditional form-style survey
  (classic multi-question form) as an alternative to the card-based Verto player.
  Scope: a form renderer + an editor toggle; assess reuse of the existing card
  data model so a Verto can render either as the player or as a plain form.

## Decisions to make first (they gate several choices)
- [ ] **Are EU respondents/customers in scope?** → if yes: pick Sentry (EU region) over AppSignal, pin EU regions on Render/Postmark, prioritise the GDPR items.
- [ ] **Pricing & packaging model** (subscription tier vs per-seat vs metered AI) → drives billing + quota design.
- [ ] **Staying on Render?** → confirms the Solid-stack / R2 recommendations hold.

---

## P0 — Launch blockers (do before real customers)

### P0-1 · Files survive deploys (Cloudflare R2)
- [ ] Create Cloudflare R2 account + bucket; generate S3 API credentials
- [ ] Add `aws-sdk-s3` gem; configure `r2` service in `config/storage.yml` (`endpoint`, `region: auto`)
- [ ] Set S3 client `request_checksum_calculation: "when_required"` + `response_checksum_validation: "when_required"` (R2 checksum gotcha)
- [ ] `config.active_storage.service = :r2` in `production.rb`; add R2 secrets to Render env
- [ ] Verify org-logo upload → served from R2 → survives a redeploy

### P0-2 · Stop being blind (error tracking + uptime)
- [ ] Add observability gem — **AppSignal** (all-in-one) or **Sentry** (if EU/PII); set the push/DSN env var on Render
- [ ] If Sentry: turn **off** `send_default_pii` + enable server-side PII scrubbing
- [ ] Enable **Render notifications** (deploy/health failures → email/Slack) — free, currently off
- [ ] (Optional) Better Stack free: external uptime monitor + public status page
- [ ] Confirm the observability agent's memory footprint fits the 512 MB box

### P0-3 · AI work off request threads (Solid Queue)
- [ ] `bundle add solid_queue`; run installer; `queue_adapter = :solid_queue` (prod); point tables at existing `survey-poc-db`
- [ ] Enable Puma plugin in **non-forking / in-process** mode (NOT default forking — OOM risk); keep worker threads 2–3
- [ ] Ensure DB pool ≥ web threads + worker threads
- [ ] Move survey generation, translation, report/summary, PDF & Forms import to `perform_later` jobs; keep 120s timeout
- [ ] Update UI to poll/stream job status instead of blocking
- [ ] Verify `db:prepare` creates Solid tables before Puma starts the plugin (watch solid_queue#617 on Render)

### P0-4 · Spend guardrails (rate limits + quota)
- [ ] Add `rate_limit` to `create`, `generate_card`, `optimise_card`, `import_pdf`, `import_google_form`, `moderate_image`, common-question generation
- [ ] Build a per-org **usage-metering primitive** (count generations/AI calls) — reused later for billing
- [ ] Enforce a per-org daily generation **quota** (the real cost cap)
- [ ] Disable/debounce submit buttons client-side; add a server-side dedupe window (idempotency)

### P0-5 · Durable, shared cache (Solid Cache)
- [ ] `bundle add solid_cache`; `cache_store = :solid_cache_store` (prod); tables on existing Postgres
- [ ] Verify `rate_limit` counters + geocode caches now survive a deploy

### P0-6 · Legal + consent baseline
- [ ] Buy policy generation — **iubenda** (~$7/mo) or **Termly** ($14/mo); add `/terms` + `/privacy` routes/pages
- [ ] Persistent footer with Terms/Privacy links across **app AND player** layouts
- [x] ~~**Gate Microsoft Clarity behind consent** or remove it~~ — **removed** (2026-10-01): Clarity is gone from the platform, and so is the cookie-consent banner that existed to gate it
- [x] ~~Add cookie-consent banner~~ — shipped, then retired with Clarity: only strictly necessary cookies remain, which need no consent. Reinstate (**orestbida/cookieconsent**, free, self-hosted) before any tracker is added
- [ ] **Self-host Google Fonts** (stop loading from `fonts.googleapis.com`/`gstatic.com` — EU GDPR issue)
- [ ] **Enforce** a baseline consent + privacy-link gate on any Verto collecting demographic/PII data (`survey.rb:241` makes it optional today)

### P0-7 · GDPR data-subject rights
- [ ] Build respondent data **export** (JSON/CSV) — by response token/email; optionally scaffold with `gdpr_admin` gem
- [ ] Build per-respondent **deletion/anonymization** (null birth date, coarsen/drop location, revoke consent)
- [ ] Document a data-retention policy; commit to 30-day response SLA
- [ ] Sign DPAs with every US PII vendor (Render, error tracker, email, Paddle); list sub-processors in Privacy Policy

### P0-8 · Signup integrity (email verification + terms)
- [ ] Add transactional email provider — **Postmark** (`postmark-rails`, EU region) or **Resend** (free start)
- [ ] Set `default_url_options` in production; fail loudly if SMTP/API unconfigured
- [ ] Email confirmation on signup (`generates_token_for :email_confirmation` + mailer)
- [ ] Required "I agree to Terms & Privacy" checkbox at signup; persist acceptance

---

## P1 — Reliability & hardening

### Infrastructure
- [ ] **P1-1** ActionCable: switch prod to `solid_cable` (or `async`); delete dead `redis`/`REDIS_URL` config
- [ ] **P1-2** Verify Render Postgres backup retention; add `pg_dump`→bucket if needed; offsite R2 bucket; write RPO/RTO + rollback runbook
- [ ] **P1-3** Health check that verifies the DB (`ActiveRecord::Base.connection.verify!`), returns 503 on failure
- [ ] **P1-4** Move `db:prepare` out of boot into Render `preDeployCommand`; keep migrations backward-compatible; add statement timeouts
- [ ] **P1-5** Add `rack-timeout` to bound thread occupancy
- [ ] **P1-6** Back up the 3 `ACTIVE_RECORD_ENCRYPTION_*` keys to a secret store; add `previous_keys` before any rotation

### Data layer
- [ ] **P1-7** Move multi-MB base64 images out of `surveys.cards`/`background_image` into Active Storage refs (needs P0-1) — the 502/OOM driver
- [ ] **P1-8** Optimize `CommonQuestionAggregator` (`select(:id,:answers).find_each` + grouped counts); fix dashboard index eager-load
- [ ] **P1-9** `add_foreign_key :identities, :users`; add index `responses [survey_id, region_country, region_label]`
- [ ] **P1-10** Downcase email in reset/invite/oauth lookups (case-sensitivity miss)
- [ ] **P1-11** Shared cross-thread Nominatim throttle (cache token bucket) for both clients (1 req/s app-wide)

### Security hardening (no open holes — defense-in-depth)
- [ ] **P1-12** Per-`email_address` login/reset throttle; lower the IP-only limit (needs P0-5 shared store)
- [ ] **P1-13** Point Blazer at a dedicated **read-only** DB role (`BLAZER_DATABASE_URL`)
- [ ] **P1-14** Small-cell suppression (min N) on public `#results` and `#scores` (like `#regions` already has)
- [ ] **P1-15** Delimit untrusted respondent text in AI chat/summary/report prompts
- [ ] **P1-16** Generic client-facing errors (fix signup enumeration + raw `e.message`); add `reset_session` on login

---

## P2 — Polish & scale
- [ ] **P2-1** Rewrite README (still says "POC / Rails 7.2 / nothing persisted / auth out of scope")
- [ ] **P2-2** Move hardcoded English controller flash strings + view placeholders into locale files
- [ ] **P2-3** Branded, localized 404/422/500 error pages
- [ ] **P2-4** Accessibility audit of the player (ARIA/roles on JS controls, focus mgmt, contrast)
- [ ] **P2-5** Add Capybara/system tests for the JS-heavy player + editor (currently zero)
- [~] **P2-6** Welcome email (pending); ~~one-click "create a sample Verto" for new orgs~~ — partly addressed by the template gallery (a new org can spin up a real Verto in one click)
- [ ] **P2-7** Migrate `json` → `jsonb` columns (off-peak table rewrite)
- [ ] **P2-8** DB CHECK constraints on status/role/kind enums; add FK `on_delete:` to mirror `dependent:`
- [ ] **P2-9** Staging env + documented rollback; tighten CSP (drop `unsafe-inline`); set `robots.txt` `Disallow: /play/` if surveys shouldn't be indexed

---

## Commercial track (after pricing decided)
- [ ] **CT-1** Decide pricing/packaging model (drives metering design)
- [ ] **CT-2** Integrate **Paddle** (Merchant of Record) via the **`pay`** gem — subscriptions + webhooks
- [ ] **CT-3** Wire per-org usage metering (from P0-4) to Paddle meter for overage billing

---

## Suggested order
1. **First (free/fast, high-leverage):** P0-2, P0-5, P1-3
2. **Then (durability & spend):** P0-1 → P0-3 → P0-4 (share the metering primitive with CT-3)
3. **Then (compliance, before real PII):** P0-6, P0-7, P0-8
4. **Then:** P1 hardening → P2 polish → Commercial track in parallel once pricing is set
