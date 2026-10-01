# Playverto — Customer Readiness Plan

_Companion to `PRODUCTION_READINESS_PLAN.md`. That plan keeps the platform from
falling over. **This** plan is about whether a real customer can discover it,
understand it, sign up, get value fast, trust it, get help, and stick around._

The technical plan answers "is it safe to run?" This one answers "will anyone
succeed with it and pay for it?" They're different axes — you can be fully
production-hardened and still not customer-ready.

## The gap in one sentence

Playverto today is a capable **logged-in app** with no **product-around-the-app**:
`root` drops straight into `surveys#index` behind auth — there is no landing page,
pricing, onboarding, account settings, help, or support surface. A stranger has no
path in, and a signed-up customer has no way to self-serve.

Items are tagged **CR-x**. Where they overlap the readiness plan/checklist, the
existing ID is noted.

---

## CR-1 · Acquisition & first impression (HIGH — nothing exists)

A self-serve SaaS is sold by its logged-out experience; Playverto has none.

- [ ] **Marketing landing page** at a public `root` — value prop ("describe a survey
  in plain language, get a shareable, multilingual, AI-analyzed Verto"), a live
  demo/GIF, social proof, clear CTA. Today `root` is the auth-gated dashboard.
- [ ] **Pricing page** — tiers, what's included, the free/trial offer. Buyers won't
  sign up without seeing price.
- [ ] **Public demo / sandbox** — a "try it without signing up" or a sample Verto +
  sample results anyone can view. The `DemoSeeder` already builds great demo data;
  expose a read-only slice of it publicly.
- [ ] **SEO basics** — meta tags, OpenGraph/Twitter cards (so a shared `/play` link
  looks good), sitemap, and a deliberate indexing policy (`robots.txt` — P2-9).
- [ ] **A few real example Vertos** as showcase content on the site.

## CR-2 · Onboarding & activation (HIGH — closes the gap between signup and value)

The metric that matters: time-to-first-published-Verto. Reduce it.

- [ ] **Guided first-run** for a brand-new org — the empty state exists
  (`dashboard.empty_*`), but turn it into a guided path: "Create your first Verto"
  with a one-click prompt example. (P2-6)
- [x] **Template gallery** — ✅ **Shipped** (`/templates`). Six ready-made decks
  (NPS, CSAT, onboarding, employee pulse, event feedback, product-market fit);
  picking one instantiates a full editable Verto instantly with no AI call/cost.
  Entry points on the dashboard hero + empty state; chrome localised across all
  19 locales.
- [ ] **One-click "create a sample Verto"** so a new org isn't staring at zero. (P2-6)
- [ ] **Progress/setup checklist** — "create a Verto → customize → publish → share →
  view results" with visible progress.
- [ ] **Loading/expectation UX for slow AI** — generation takes 30–120s; show
  progress, what's happening, and never a spinner-to-nowhere. Especially once jobs
  move to the background (P0-3), the UI needs a "we're building it" state.
- [ ] **Welcome email** + a short activation drip (day 0 welcome, day 3 "here's how
  to share", nudge if no Verto published). (P2-6)

## CR-3 · Trust & credibility (HIGH for B2B — you handle others' PII)

Customers are trusting Playverto with **their respondents' personal data**. That
raises the trust bar well above a typical app.

- [ ] **You are a data _processor_ for your customers** → offer **your own DPA** and
  a **sub-processor list** (Render, Anthropic, R2, email, Paddle…) that customers
  can sign/review. This is distinct from *you* signing vendor DPAs (P0-7) — this is
  what *your* customers will ask for before they'll trust you with respondent PII.
- [ ] **Trust/security page** — how data is stored/encrypted, where it's hosted,
  retention, that Anthropic isn't training on their data, sub-processors. B2B buyers
  ask; have the page ready.
- [ ] **Public status page** — uptime + incident history (Better Stack free tier —
  already in the tooling guide). Signals operational maturity.
- [ ] **Professional, branded error pages** — stock grey Rails 404/500 reads as
  "hobby project." (P2-3)
- [ ] **Respondent-facing trust on the player** — a visible privacy notice + "your
  answers are anonymous / who's collecting this" so *respondents* trust it and
  completion rates hold up. (Ties to P0-6 consent.)
- [ ] **Polished, consistent brand** — the app is branded, but the surrounding
  surfaces (emails, error pages, marketing) must match.

## CR-4 · Self-service account management (HIGH — none exists today)

There are no account/settings/profile/billing pages — only `organisations#edit`.
Customers can't manage their own account, which means every change is a support
ticket.

- [ ] **User profile & account settings** — name, email, password change, language,
  delete-my-account (GDPR-adjacent, P0-7).
- [ ] **Team/seat management UX** — invites and memberships exist as models; give
  them a clear settings home (roles, remove members, pending invites, seat count).
- [ ] **Billing/plan self-service** — current plan, upgrade/downgrade, payment
  method, invoices, **usage vs quota** (from P0-4's metering), cancel. Paddle
  provides a hosted customer portal — wire it. (CT-2)
- [ ] **Usage visibility** — "you've used 40/100 generations this month" so limits
  never surprise them and upgrades feel natural.
- [ ] **Organisation settings home** — branding/logo (already partly there), default
  locale, data-retention preferences.

## CR-5 · Support & customer success (MEDIUM–HIGH — no channel exists)

- [ ] **Help center / docs** — how to create, customize, share, and read results;
  FAQ. Even a small docs site or in-app help.
- [ ] **A contact/support channel** — support email at minimum; in-app "Help/Contact"
  link. Right now a stuck customer has nowhere to go.
- [ ] **In-app contextual help** — tooltips/empty-state hints on the complex bits
  (alliances, common question sets, results comparison).
- [ ] **Changelog / "what's new"** — shows the product is alive and maintained.
- [ ] **Lifecycle & transactional emails beyond auth** — publish confirmations,
  "your Verto got its first responses", weekly results digest. Turns one-time users
  into returning ones. (Email infra: Postmark, P0-8.)

## CR-6 · Customer data control & portability (MEDIUM — partly there)

- [ ] **Customer-facing data export** — let a customer export *their* surveys +
  responses (not just per-respondent GDPR export in P0-7). Google Sheets/Drive
  export exists — add plain CSV/JSON so their data never feels locked in.
- [ ] **Clear data ownership statement** — "your data is yours; export or delete
  anytime." A common procurement question.
- [ ] **Account/org deletion** — self-serve, with the cascade handled cleanly (ties
  to the data-layer FK work, P2-8).

## CR-7 · Product depth that closes deals (MEDIUM — differentiators)

- [x] **Template library** (also in CR-2) — ✅ **Shipped** as the `/templates`
  gallery. Next: grow the set and add a preview before instantiation.
- [ ] **Sharing & collaboration clarity** — make the Verto sharing/permissions model
  (and alliances, which are powerful but non-obvious) legible in the UI.
- [ ] **Integrations beyond Google** — even a webhook-on-response or a Zapier/Make
  hook widens who can adopt it; a public read API for results.
- [ ] **Results depth as a selling point** — the AI summary/report/chat is a real
  differentiator; make sure it's front-and-center and shareable/exportable.

## CR-8 · Feedback & product analytics (MEDIUM — you can't improve what you can't see)

- [ ] **Activation/retention funnel analytics** — instrument signup → first Verto →
  publish → first response → return. (Microsoft Clarity was removed 2026-10-01;
  pick a privacy-respecting product analytics tool for funnel data, and note that
  anything setting non-essential cookies brings back the consent banner from P0-6.)
- [ ] **In-app feedback / feature requests** — a lightweight "give feedback" widget.
- [ ] **NPS or satisfaction pulse** — dogfood your own product on your customers.

## CR-9 · Pricing & packaging strategy (HIGH — a business decision, gates CR-1/CR-4)

Not code — a decision that shapes the landing page, the tiers, and the metering.

- [ ] **Choose the model** — free trial vs freemium; what the free tier allows
  (e.g. N Vertos or N responses); what upgrades unlock (more generations, removing
  Playverto branding on the player, team seats, exports, alliances).
- [ ] **Decide the metered axis** — per-generation, per-response, per-seat, or a
  blend (ties directly to P0-4 quota + CT-3 metering).
- [ ] **Free-tier abuse limits** — since every generation costs real Anthropic money,
  the free tier's cap IS a cost-control decision, not just marketing.

---

## How this maps to the technical plan

Customer-readiness **depends on** several P0/P1 items being done first:

| Customer need | Requires (technical) |
|---------------|----------------------|
| Billing self-service, usage display (CR-4) | P0-4 metering + CT-2 Paddle |
| Trust page / status page (CR-3) | P0-2 monitoring, P0-1 durable storage |
| Respondent trust on player (CR-3) | P0-6 consent + privacy |
| Lifecycle/welcome email (CR-2, CR-5) | P0-8 Postmark |
| Customer DPA (CR-3) | P0-7 GDPR + vendor DPAs |
| Fast, non-blocking generation UX (CR-2) | P0-3 background jobs |

## Suggested priority (customer-facing)

1. **Decide pricing/packaging (CR-9)** — unblocks the landing page, tiers, and quota.
2. **Landing + pricing page (CR-1)** — you currently can't be *found or bought*.
3. **Onboarding + templates (CR-2)** — the biggest lever on activation/retention.
4. **Account/billing self-service (CR-4)** — so growth doesn't equal support load.
5. **Trust surfaces + customer DPA (CR-3)** — unblocks B2B deals.
6. **Support channel + help docs (CR-5)**, then depth/feedback (CR-6–CR-8).

**Rule of thumb:** the readiness plan is what you build so you *can* have customers;
this plan is what you build so customers *choose and keep* you. Do the P0 blockers,
then CR-9 → CR-1 → CR-2 in parallel with P1 hardening.
