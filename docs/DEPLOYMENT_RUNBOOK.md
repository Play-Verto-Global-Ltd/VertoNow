# Deployment Runbook

Manual procedures the deployment pipeline can't do for you — rolling back a
bad deploy, backing up keys that live only in Render, and two one-time setup
steps (branch protection, Sentry). Companion to `PRODUCTION_READINESS_PLAN.md`
(P1-2, P1-6) and `PRODUCTION_READINESS_CHECKLIST.md`; check the corresponding
item off there once you've done the matching section here.

## 1. Rolling back a bad deploy

Render dashboard → the `survey-poc` service → **Deploys** tab → find the last
known-good deploy → **Rollback to this deploy**.

The service is image-backed (section 7): a rollback re-pulls the earlier
deploy's image from GHCR by digest, so it works only while that `:<sha>`
version still exists there — never prune the package — and it moves what is
live, not the `:main` tag CI maintains.

Two things that make this different from a typical Rails app's rollback:

- **App code and schema roll back independently — code does not roll back the
  schema.** If the bad deploy's pre-deploy migration already ran (see
  `render.yaml`'s `preDeployCommand`), the database is on the new schema.
  Rolling back to the older code only works if that older code still runs
  correctly against the new schema. This is why migrations should stay
  backward-compatible (tracked separately, not yet built — see
  `PRODUCTION_READINESS_PLAN.md` P1-4).
- **If the pre-deploy command itself failed, Render should never have swapped
  traffic to the new instance** — confirm which deploy is actually live in
  the dashboard rather than assuming the bad one made it live. The persistent
  disk (`render.yaml`) pins this service to a single instance, so every
  rollback is a hard cutover, not a gradual one — there's no second instance
  serving traffic during the switch.

If you need to run a migration or one-off command without a full deploy, use
Render's **Shell** tab, not a manual restart — a restart no longer re-runs
`db:prepare` (moved to `preDeployCommand`).

## 2. Running a data import against production

The exports live in the image (`db/seeds/exports/`, ~18MB gzipped), so the
Render **Shell** can run these commands directly. **Prefer not to.** That Shell
runs inside the live web container, which is a 512MB starter instance whose
whole configuration in `render.yaml` — the memory watchdog, `WEB_CONCURRENCY=0`,
capped malloc arenas, hand-tuned GC — exists because it was OOM crash-looping.
Replaying a 126,895-row export next to the serving process is the most likely
way to take the site down.

Run it from a workstation instead, pointed at the production database. Then only
the `INSERT`s cross the network and the parsing happens somewhere with room.

### The minimum environment

A data-only rake task boots in `production` with **throwaway values for
everything except the database**:

```bash
export RAILS_ENV=production
export DATABASE_URL='…'                       # the real one, from the Render dashboard
export SECRET_KEY_BASE=$(openssl rand -hex 32) # throwaway: nothing here signs a cookie
export APP_HOST=example.invalid                # throwaway: satisfies MailConfigCheck
export SMTP_ADDRESS=smtp.invalid
export MAIL_FROM=noreply@example.invalid
export ANTHROPIC_API_KEY='…'                   # needed for verto:enrol_corpus, and drives
                                               # automatic UN SDG tagging during import —
                                               # absent, the import succeeds untagged
                                               # (run sdg:backfill later)
```

**Do not copy the `ACTIVE_RECORD_ENCRYPTION_*` keys.** An import neither reads
nor writes an encrypted attribute, so it does not need them — and those three
are the one secret in this app with no recovery path (see section 3). Copying
them onto a laptop to run a task that never uses them is pure downside.

### The order

```bash
bin/rails verto:preflight        # read-only; exits non-zero if anything should stop you
```

Preflight reports the schema version, what each deck's account already holds —
flagging any response that was collected through the player rather than
imported — the database size, and whether the Anthropic key actually answers.
Fix whatever it flags before going on.

Then, per dataset, **smallest first** so a mistake is cheap:

```bash
IMPORT_DECK=<deck> IMPORT_PASSWORD='…' bin/rails "verto:import_csv[db/seeds/exports/<file>.csv.gz]"
IMPORT_DECK=<deck>                      bin/rails "verto:reconcile[db/seeds/exports/<file>.csv.gz]"
IMPORT_DECK=<deck>                      bin/rails verto:enrol_corpus
```

| Order | `IMPORT_DECK` | Export | Rows |
|---|---|---|---|
| 1 | `unyo_sport` (plus `IMPORT_ORG_SLUG=unyo`) | `unyouth_sport_raw_data` | 1,376 |
| 2 | `you_are_nature` — still collecting; re-run the import when a fresher export lands | `you_are_nature_raw_data` | 2,952 |
| 3 | `aaf_valparaiso` | `aaf_valparaiso_final_raw_data__raw_data_general` | 3,477 |
| 4 | `walls_happiness_adult` — **`verto:build_deck` then `verto:append_csv`**, not import | `walls_the_happiness_project_raw_data_adults__master` | 10,754 |
| 5 | `walls_happiness_child` — **`verto:build_deck` then `verto:append_csv`**, not import | `walls_the_happiness_project_raw_data_children__master` | 17,932 |
| 6 | `wll_education_digital` | `wll_transforming_education_raw_data_digital` | 50,835 |
| 7 | `wll_education_paper` — **`verto:append_csv`**, not import | `wll_transforming_education_raw_data_paper` | 3,483 |
| 8 | `big_green_legacy` | `the_big_green_legacy_moe_raw_data` | 126,895 |

Step 7 appends because both WLL halves are one Verto; importing it would rebuild
the account and take the digital half with it.

Steps 4–5 must never use `verto:import_csv` for a different reason: the two
Happiness Project flows are **sibling Vertos sharing one org**, and a full
import destroys the whole org — including the other flow. `verto:build_deck`
replaces only its own Verto, and `verto:append_csv` upserts the responses, so
neither touches the sibling. Re-running a pair is idempotent, and each combined
export can be regenerated and re-appended as more country files arrive (the
CSV keeps every row's provenance in its Country column).

`verto:reconcile` must report **zero unaccounted answers**. It is the whole
claim — every answer in the export is either stored or listed as a deliberate
omission — and a production import that does not reconcile should be rolled
back, not investigated in place.

`verto:import_csv` and `verto:build_deck` also tag the Verto with UN SDGs
(one Haiku call reading the deck; the import summary prints the result).
`verto:append_csv` never re-tags — it only runs when the deck is unchanged,
so the tags cannot be stale. Datasets imported before tagging existed get
theirs from `bin/rails sdg:backfill` (`DRY_RUN=1` to preview).

### What is safe about this

Each import is a single transaction (`VertoCsvImporter#call` wraps
destroy → create → insert), so a dropped connection or a killed terminal rolls
back to the previous state. There is no partial-import case to clean up.

Each import also **destroys and rebuilds its own account first** — that is what
makes it repeatable. `IMPORT_DECK=<deck> bin/rails verto:destroy_import` removes
one imported account outright. Both are scoped to the deck's own org slug and
touch nothing else.

### What it costs

`verto:enrol_corpus` is the only step that spends money: it themes every
open-text column in batches through Claude Haiku. Big Green's freeform alone is
59,620 answers, capped at 40 calls by `ASK_VERTO_MAX_THEME_BATCHES`. Across all
the datasets, expect 150–200 calls. Lower that variable for a cheaper first pass;
re-running enrolment later fills the themes in.

One more thing it needs: a **present** `ANTHROPIC_API_KEY`, not just a working
one. Preflight fails a key that answers wrongly but only *warns* when the key
is absent — enrolment then still succeeds, indexing every closed question,
and silently produces **no themes and no quotes** for any open-text question.
That is recoverable (re-run enrolment with a key later), but nothing in the
task's output says the quotes are missing, so don't discover it from the
product.

### The consent path (customer-offered Vertos)

The import above is the VertoNow half — data held under an agreement, where
`verto:enrol_corpus` legitimately turns both consent keys itself. Everything
else enters Ask Verto through two people:

1. **The creator offers.** The "Ask Verto" block in the editor's publish
   panel (admins of the owning org only; visible once the Verto has any
   answered responses) posts the offer, which lands in the review queue as
   `pending`.
2. **Staff approve or decline** at `/ask/review`. The route is gated by the
   same `BLAZER_STAFF_EMAILS` allowlist as `/blazer`, and it is
   **deny-by-default: while that variable is unset in Render, the queue 404s
   for everyone and no offered Verto can ever be approved** — the corpus can
   then only grow through the rake task. Set it (Render dashboard →
   Environment) to the staff sign-in email(s) before expecting the queue to
   exist.

Approval enqueues the indexing job; declining records a reason the creator
reads verbatim. A Verto the automated checks BLOCK (sample floor, no citable
questions) is left `pending` in this queue even by `verto:enrol_corpus` —
blocked Vertos are a human's decision — so the allowlist matters for the
import path too.

## 3. Backing up the Active Record encryption keys

Render dashboard → the `survey-poc` service → **Environment** tab → reveal
and copy each of:

- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

Store all three in a password manager. **Never commit them to this repo**
(including this file) — they're `generateValue: true` in `render.yaml`
specifically so Render, not the repo, holds the live values.

**Why this matters:** these three keys encrypt every stored Google OAuth
token at rest. If the Render service is ever deleted and recreated, or a
value is regenerated without a backup, every encrypted token becomes
**permanently undecryptable** — there is no recovery path. Every connected
user would need to reconnect Google.

**Rotating a key later:** don't hard-swap. Active Record Encryption supports
`previous_keys` — add the old key there before setting a new primary key, so
already-encrypted data keeps decrypting during the transition. See the [Active
Record Encryption guide](https://guides.rubyonrails.org/active_record_encryption.html#key-rotation)
for the exact config shape.

## 4. GitHub branch protection on `Main`

`CLAUDE.md` stands by pushing straight to `Main` with no PR. The textbook
branch-protection setup ("require a pull request before merging," "require
status checks to pass before merging") only gates **PR merges** — it does
nothing for direct pushes, and turning on "require a PR" would break the
current workflow outright. Two options, not one:

**Option A — recommended, keeps the current workflow.** GitHub repo →
Settings → Branches → Add branch protection rule → branch name pattern
`Main`:
- ✅ Do not allow force pushes
- ✅ Do not allow deletions
- Optionally: restrict who can push, to your own account explicitly

This closes the "anyone/anything with write access can force-push over
history or delete the branch outright" gap without changing how work ships.

**Option B — a bigger, separate decision.** Moving to a PR-based workflow
(feature branches, "require a PR," "require status checks before merging")
is what would make branch protection's full feature set meaningful — but
that's a workflow change, not a settings change, and isn't decided here.
Revisit if the direct-to-`Main` convention ever stops fitting how this repo
is worked on.

## 5. Sentry setup (one-time)

Do this **before** setting `SENTRY_DSN` anywhere — the region choice below
can't be changed after the fact.

1. Create a Sentry account/organisation at sentry.io. On the **New
   Organization** screen, set **Data Storage Location: EU**. This is chosen
   once, at the organisation level, and is irreversible — every project and
   every DSN created under this org afterward automatically routes through
   the Frankfurt region. There's no equivalent setting in the SDK
   (`config/initializers/sentry.rb`) or in Render — it only exists here.
2. Create a Rails project inside that org; copy its DSN.
3. Render dashboard → the `survey-poc` service → **Environment** → set
   `SENTRY_DSN` to that value.
4. Deploy (or wait for the next one) and confirm: trigger a harmless error
   and check it lands in the Sentry project, tagged with a `component` (see
   `app/lib/error_reporting.rb`) and with `request.data` empty (the
   `before_send` hook in `config/initializers/sentry.rb` strips it —
   confirm this, since respondent birth date/location must never appear in
   a captured event).

## 6. Editing a live Verto (the owner's override)

A live or answered Verto's deck is frozen for everyone (`Survey#editing_locked?`
— answers are keyed by card position, so a structural edit re-points them),
except for the accounts in `LIVE_EDIT_USER_EMAILS` (`app/lib/live_edit_access.rb`).
Unlike the Blazer allowlist this one has a **default — `nick@playverto.com`** —
so the owner's override works without anything being set in Render. Setting the
variable replaces that default outright: a comma/space-separated list widens or
narrows it, an empty value switches the override off for everyone. The account
must also have a **verified email address** (the same proof publishing needs):
sign-up is open, so on a database without the owner's row the default address
could otherwise be claimed by whoever registered it first. It grants nothing
else: organisation scoping is unchanged, and the primary-language switch stays
locked because the model refuses it itself. An allowed account sees an amber
"editing a live Verto" bar and a warning modal in place of the lock; the risk
it describes is real, so keep the list short.

## 7. Deploying the image CI built (switched 2026-09-13)

The `VertoNowMain` service (the dashboard's name for what `render.yaml` and
section 1 call `survey-poc`) is image-backed: it runs
`ghcr.io/play-verto-global-ltd/vertonow:main`, the image CI's `build_image`
job pushed,
instead of rebuilding from source after every hook (2–3 minutes per deploy;
a pull is about one). How a commit reaches production:

1. Every Main run pushes `ghcr.io/play-verto-global-ltd/vertonow:<sha>`
   (`build_image`, alongside the test jobs).
2. Once every other job is green, the `deploy` job moves `:main` onto that
   sha (`docker buildx imagetools create`, a registry-side retag, no rebuild)
   and POSTs the Deploy Hook with
   `imgURL=ghcr.io/play-verto-global-ltd/vertonow:<sha>`.
   Render pulls that exact image and restarts.

What follows from that:

- **`:main` is always the last green commit** (from this change onward; only
  the deploy job moves it), so the dashboard's **Manual Deploy → Deploy latest
  reference** deploys the last green commit — the recovery when a hook POST
  failed. It is NOT the thing to press after a section 1 rollback: `:main`
  still names the build you rolled back from until a fix-forward lands.
- **Nothing deploys on its own.** An image-backed service ignores the
  repository's pushes and checks, and the dashboard's auto-deploy setting no
  longer applies to it. The hook (what CI uses), Manual Deploy → Deploy latest
  reference, Rollback to this deploy, and the Render API all deploy only when
  asked.
- **Rollback (section 1) re-pulls from GHCR, not from Render.** Render records
  each deploy's image digest and "Rollback to this deploy" pulls it again from
  the package it was deployed from; Render holds no copy of a pulled image (it did
  of the source builds this replaced). So never prune the package: the
  `:<sha>` versions are the rollback history, and the "untagged" versions the
  package UI shows are the per-platform and provenance manifests each tagged
  image points at — deleting them breaks that tag. A dashboard rollback moves
  what is live, not `:main`. To put an exact commit back from CI's side, POST
  the hook yourself with
  `imgURL=ghcr.io/play-verto-global-ltd/vertonow:<known-good sha>`.
- **`imgURL` must name the repository the service is configured with.** The
  hook validates it: an `imgURL` pointing anywhere else is refused with
  **HTTP 400**, and the deploy job then goes red on `curl -f` having deployed
  nothing. Measured on 21 September — the run that landed the namespace move
  POSTed the org image while the dashboard still named `napps9/survey-poc`,
  and got a 400; the same POST succeeded minutes later, unchanged, once the
  service's image reference had been repointed. So the dashboard reference is
  not documentation of what CI does, it is a precondition for CI being allowed
  to do it. Changing the image path in `ci.yml` without changing it in the
  dashboard stops every deploy.
- **Rolling back past 21 September 2026 goes through the dashboard, not the
  hook.** Every `:<sha>` built before the namespace move lives on
  `ghcr.io/napps9/survey-poc` and nowhere else — GHCR packages do not move
  between namespaces, so those images were not carried over. **Rollback to
  this deploy** reaches them: Render replays the digest it recorded, which
  needs no path and does not care which package it came from. A hook POST
  cannot, because that old path is no longer the service's configured
  repository and the bullet above is what happens. If a pre-move image has to
  go back through CI, the service's image reference must be pointed at the old
  package first. Never delete that package: it is the rollback history for
  everything before the move.
- **Why the image is in the org's namespace** (moved 2026-09-21). While the
  repository lived under `napps9`, repo and package shared an owner and
  `build_image`'s `GITHUB_TOKEN` could push with `packages: write` alone —
  which is why ci.yml carries no registry credential. Transferring the
  repository to the org broke that link, and pushes started being refused with
  `denied: permission_denied: The requested installation does not exist`: not
  a code failure, and not one any commit could fix. Run 801 is what it looked
  like — every test job green, the image built, only the push refused, the
  commit left on Main with the deploy job skipped. **Manage Actions access on
  the personal package is not a way out of this**, checked on the day: its
  "Add Repository" picker lists only that account's own repositories, so the
  org repo cannot be added and there is no grant to give. Moving the image to
  a package the repository's own owner holds was the only route, and it is one
  that cannot lapse.
- **The GHCR package is public** (a public repo's image contains nothing the
  repo does not; CI builds it with no secrets), so the service has no registry
  credential. This is a setting, not a default, and on an org it is two:
  GHCR creates a package **private**, and the org's **Settings → Packages →
  Package creation** governs which visibilities exist at all — with `Public`
  unticked there, the package's own Change-visibility dialog greys Public out
  and says "Setting is disabled by organization administrators". Both had to
  be done by hand on 21 September, org policy first, then
  **Package settings → Change visibility → Public**. Checking the result needs
  no credentials — GHCR issues an anonymous pull token for a public package
  and `UNAUTHORIZED` for a private one:

  ```
  curl -s 'https://ghcr.io/token?scope=repository%3Aplay-verto-global-ltd%2Fvertonow%3Apull&service=ghcr.io'
  ```

  If the package is ever made private again, add a classic personal access
  token with `read:packages` as a Render registry credential.
- The switch was made in place (Settings → Build & Deploy → Repository →
  Edit → Existing Image), with environment variables, the persistent disk
  and the pre-deploy command untouched. `render.yaml` mirrors the image
  source, but the service is not blueprint-managed: the dashboard is the
  truth, the file the record.

Undo: Settings → Repository → Edit → pick the GitHub repository again, and
drop the `imgURL` parameter from the deploy job's POST in
`.github/workflows/ci.yml`; Render then rebuilds from source on the next
hook. The `:<sha>` pushes cost nothing either way.

## 8. What visitors see during a deploy — and the branded "deploying" page

Every deploy of the web service is a **stop/start, not zero-downtime**: the
persistent disk (`render.yaml`, `disk:`) pins the service to one instance, so
Render stops the running instance, starts the new one, waits for `/up`, and
only then routes traffic. For that gap — the container start, the
entrypoint's `db:prepare`, Puma's boot, roughly a minute — Render's edge
answers every request itself with its black "502 Bad Gateway / This service
is currently unavailable" page. Nothing in the app can replace that page for
a visitor it has never seen, because the app is the thing being replaced.

`public/deploying.html` is our version: on brand, "We're deploying a new
feature — back in a few minutes", and it polls `/up` and reloads itself the
moment the app answers. Who sees which page today:

| Visitor | During the gap |
|---|---|
| A respondent who has opened a Verto before (the player's service worker is installed) | Their **cached Verto**, if they have one — the deploy looks like a slow network; a submit queues and drains when the app is back. Otherwise the **branded deploying page**. |
| A first-time respondent, anyone in the studio, anyone without the worker | **Render's 502 page**, unchanged. |

The worker (`app/views/pwa/service-worker.js.erb`) treats a 502/503/504 on a
player navigation as "the app isn't there" rather than as an answer — a 410
for an unpublished Verto still goes through — and carries the page inline,
so there is nothing to fetch at the moment nothing is reachable.

### Showing the branded page to everyone

Render's **maintenance mode** (dashboard → the service → Settings →
Maintenance Mode; paid instances only, which `starter` is) serves a page of
your choosing for every request instead of routing to the instance, and
accepts a **custom page URL**. Two constraints Render documents: the URL must
not be on the service itself (it is the thing that is down), and a static
site is the recommended host. So:

1. Host a copy of `public/deploying.html` off the service — a Render static
   site or GitHub Pages for this repository both work; keep it byte-identical
   to the file here, which the tests pin.
2. Paste its URL into the service's maintenance-mode settings.
3. Switch maintenance mode **on before** a Manual Deploy and **off once** the
   deploy is live. It is a manual switch today; the Render API
   (`PATCH /v1/services/{id}` with `maintenanceMode`) would let the `deploy`
   job in `.github/workflows/ci.yml` do it around the hook POST, at the cost
   of a `RENDER_API_KEY` secret and a step that must run `if: always()` so a
   failed job can never leave the site dark.

The trade-off to know before automating it: maintenance mode is on for the
**whole** deploy (image pull, pre-deploy `db:prepare`, boot), not just the
stop/start gap, so everyone sees the page for two or three minutes instead of
a minute of 502s for the few who happened to click then.

### Making the gap smaller, or gone

- Removing `db:prepare` from `bin/docker-entrypoint` once the
  `preDeployCommand` is confirmed in the deploy log (the two-step migration
  `render.yaml` describes) takes the migration check out of the boot path.
- **Zero-downtime deploys come back when the disk goes** — phase 3 of
  `docs/OBJECT_STORAGE_CUTOVER.md`, after `bin/rails object_storage:verify`
  passes on production. With no disk, Render keeps the old instance serving
  until the new one passes `/up`, and there is no gap for any page to fill.

## 9. Google sign-in: the four redirect URIs

`Error 400: redirect_uri_mismatch` on Google's own page is never an app bug —
the app never sees the request. Google is refusing to redirect back to a URL
the OAuth client does not list, so the fix is always in the Cloud Console, on
the client named by `GOOGLE_CLIENT_ID`.

**There are FOUR, because there are two strategies.** Creators sign in as a
`User` through `/auth/google_oauth2`; respondents sign in as a `Player`
through `/auth/google_player`. The same Google client is mounted twice under
different names (`config/initializers/omniauth.rb`) precisely so that which
kind of account a callback may create is decided by the URL Google was sent
to, and not by a flag in a session the other flow could still be carrying.
Two strategies × two environments:

```
http://localhost:3000/auth/google_oauth2/callback    dev, creators
https://<APP_HOST>/auth/google_oauth2/callback       prod, creators
http://localhost:3000/auth/google_player/callback    dev, respondents
https://<APP_HOST>/auth/google_player/callback       prod, respondents
```

The signature of a missing `google_player` pair is that **creator sign-in
keeps working while respondent sign-in fails** — they are different URLs and
only one of them is registered. That is what happened when respondent Google
sign-in first shipped (2026-09-14): the strategy landed with the pair
documented in `.env.example` and nobody had added them to the console yet.

**Check what this environment actually sends** rather than deriving it. In a
shell on the service:

```
bin/rails runner 'puts OmniAuth.config.full_host'
```

Append `/auth/google_oauth2/callback` and `/auth/google_player/callback` to
what it prints, and those two strings must appear in the console **character
for character** — Google matches exactly, including scheme, port and trailing
path, and ignores nothing.

If that command prints something unexpected, the cause is the host resolution
at the foot of the initializer, which is `APP_HOST`, then
`RENDER_EXTERNAL_HOSTNAME`, then nothing:

- prints `https://survey-poc.onrender.com` → `APP_HOST` is unset on the
  service and it has fallen through to Render's own hostname. Either set
  `APP_HOST` (it is `sync: false` in `render.yaml`, so it is set in the
  dashboard, not the repo) or register the onrender URL too.
- prints an empty line → neither is set, and OmniAuth derives the host from
  the request instead. Behind Render's proxy that can arrive as `http://`,
  which mismatches every `https://` URI on the client. Set `APP_HOST`.

A changed redirect URI takes effect in Google within a minute or so; the
console says up to a few hours, and in practice a hard refresh is enough.
