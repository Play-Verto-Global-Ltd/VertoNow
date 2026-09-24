# How Vertos get their imagery

*How Playverto picks images and visual content for a Verto — from the Pexels
API and from the built-in Verto library.*

*Reference document · reflects the live behaviour as implemented in the
product. Companion to "Rules of the Game" (which covers question design;
this covers visuals).*

---

## The short version

1. **Pexels is the primary source.** When a Pexels API key is configured, the
   background, card panels and Tap-card statement images are fetched live from
   Pexels, matched to the Verto's theme and each card's subject.
2. **The Verto library is the curated fallback.** When Pexels is not
   configured (or a search returns nothing), a bundled, hand-tagged asset
   library takes over, scored against the Verto's theme, audience age and each
   card's wording.
3. **Creators can override everything.** Every pick can be swapped in the
   editor's media picker — from the library, a fresh Pexels search, or an
   upload (which is AI-moderated before it lands).
4. **Picks are stable, not random.** The same Verto always populates with the
   same imagery. The editor's **Shuffle** button is the only thing that
   re-rolls the picks (and it's disabled once a Verto is live).
5. **A shuffle can be steered.** An optional **direction prompt** beside
   Shuffle lets the creator say what they're after — a mood, a setting, or
   something to keep out — for that one shuffle (see §4a).

---

## 1. What imagery a Verto carries

| Slot | What it is |
|---|---|
| **Background** | One full-bleed backdrop behind the whole Verto. |
| **Card panel** | One photo **or** one short muted video on each card's left panel (never both). Videos autoplay, looped, no sound. |
| **Tap-card statements** | One square image per swipe statement. |
| **Range card** | No stored image — the panel plays a reactive animation that changes with the slider. The animation *set* is a per-card asset in its own right: theme-matched, re-rolled by Shuffle, and overridable by the creator (see §7). The age card plays a fixed set with a frame per band. |
| **Grid / list tiles** | No photos — small subject icons matched to each option's wording (see §7). |
| **Mobile card backdrop** | A soft image behind the card body on phones, chosen per Verto so the mobile view never looks bare. |

A card image from Pexels also carries its **photographer credit**, shown as a
subtle "Photo by …" link on the card (required by the Pexels licence and good
manners besides).

## 2. When imagery is chosen

Imagery is populated **automatically at creation** on every path — AI
generation from a brief, PDF import, and Google Forms import. It happens
immediately, as part of creating the Verto, and it is best-effort: if an image
source hiccups, the Verto is still created (a card just stays blank rather
than the whole thing failing).

After that:

- **Shuffle assets** (editor toolbar) re-rolls every automatic pick with a
  fresh random seed — a one-click "show me a different look". Its caret opens
  an optional **direction prompt** that steers what it re-rolls *toward* (see
  §4a).
- Editing a card never silently changes its imagery; only Shuffle or the
  media picker do.
- **Live Vertos are locked** — Shuffle is blocked once a Verto is published,
  protecting what respondents see.

## 3. How each pick is chosen

### Background

1. **Pexels first** — a landscape search built from the Verto's theme words
   (cropped to 1920×1080).
2. **Library fallback** — curated backgrounds, but only those that genuinely
   match the theme are considered, then scored (see §4).
3. **Never blank** — if nothing scores, a deterministic rotation through the
   background pool guarantees the editor never opens on an empty backdrop.

### Card panels (photo or video)

- **Tap and Range cards are skipped** — Tap cards put their imagery on the
  statements themselves; Range shows the reactive animation.
- **Pexels first** — a portrait search (cropped 720×1280). The search is
  **anchored to the Verto's theme** (its subject), then refined with a card's
  own concrete terms; a card's motivational or scaffolding copy never leads
  the search. **Welcome/checkpoint cards are theme-only** — they have no
  subject of their own, so their imagery follows the Verto theme. (This
  prevents a welcome card's "your voice matters…" copy pulling neutral Vertos
  into activism stock.) **Demographic form fields** (Gender / birth / location
  — the standard tail on every Verto) are theme-only for the same reason:
  their copy names a sensitive subject that must not steer a stock-photo
  search, so their image follows the Verto theme.
- **Video cadence** — every third card that receives media prefers a **video**
  instead of a photo. This is the variety principle applied to media: videos
  never sit on adjacent cards, and photo runs are capped at two.
- **Library fallback, two tiers:**
  - *Tier 1 — themed art.* An asset must fit the card type **and** share a
    genuine thematic connection, and score above a minimum bar. Close enough
    isn't enough — an off-theme asset can't win on general appeal alone.
  - *Tier 2 — card-type art.* If nothing themed qualifies: choice-style art
    for pick-one/pick-many/yes-no/prioritise cards, scale-style art for
    range/rating/NPS cards.
  - *Deliberately blank* if neither tier fits — a clean panel beats a wrong
    image.

### Tap-card statement images

- **Pexels first** — one square image (800×800) per statement, no repeats
  within the card, and statements on *different* Tap cards get different
  images too.
- **Library fallback** — a dedicated swipe-card pool; unused assets are
  preferred, and the pool cycles gracefully if a card has more statements
  than the pool has assets.

### Videos (when the cadence picks one)

Only mp4s in a sensible band are used — at least 700px wide (sharp on a
card), never above 1920px (no 4K files on a phone connection). Each video
gets a poster frame so the card looks right before playback starts.

## 4. How matching and scoring work (the library brain)

When the library is choosing, every candidate asset is scored against the
Verto and the specific card:

| Signal | Weight | Notes |
|---|---|---|
| Asset keyword found in the card's own text/options | **+4 each** | The heaviest — subject-specific pictures win. |
| Theme keyword match | +3 each | From the Verto's stated theme. |
| Audience age match | +2 (+1 if asset is tagged "all ages") | Age buckets: kids / teen / young-adult / adult / senior. |
| Mood match | +2 | playful, energetic, calm, serious, warm… |
| Style match | +1 | photo, illustrated, vibrant, minimal… |

Two guard rails keep the scores honest:

- **The theme gate.** An asset must share at least one theme or subject
  keyword with the Verto before its age/mood/style bonuses count at all —
  so a great sports photo can't win a climate Verto just because the
  audience age matches.
- **Theme clusters.** Related topics are grouped (food ↔ nutrition ↔
  sustainability ↔ nature; work ↔ career ↔ office ↔ leadership; etc.), so a
  "healthy eating" Verto still finds assets tagged "nature". Every cluster
  anchors to at least one canonical visual family, so the matcher can always
  resolve *something* sensible.

**Determinism.** All "random" choices are seeded from the Verto's identity,
slot by slot. The same Verto populates identically every time; two different
Vertos with the same theme still get different-feeling picks. Shuffle swaps
the seed — that's all it does.

**No visual déjà vu.** An asset already used on one card is avoided on the
next; repeats are allowed only once a pool is exhausted.

## 4a. The direction prompt (steering a shuffle)

Beside the editor's **Shuffle** button is an optional free-text box — the
**direction prompt** — where a creator says what they want out of the Verto's
content and imagery: *"warm natural light, outdoors, small groups, no
offices."*

**It belongs to one shuffle and is not stored.** The box starts empty every
time; a steer applies to the click it was typed for and nothing else. It first
shipped saved on the Verto so the box would stay filled in, which turned it
into invisible state — a sentence typed once went on quietly deciding every
later shuffle, under a panel headed "Steer *this* shuffle". Nothing outside a
shuffle reads a direction, so the picker's Recommended rail, its first search
and the player's mobile backdrop are all theme-only.

After a shuffle the panel reports what the prompt reduced to — *"Last shuffle
searched for: professional, corporate"* — carried in the flash, so it describes
the run that just happened and is gone by the next page view.

It is a **preference layered over** everything above, never a replacement for
it. The theme still anchors the search, a card still names its own subject,
and safety and relevance still decide what may actually be applied.

| Where it lands | What it does |
|---|---|
| Pexels queries | Up to three of its words **lead** every query, ahead of the theme and the card's subject. If the narrowed query finds nothing relevant, the direction is the first thing dropped and the query is re-run without it. |
| Which result is applied | Candidates that visibly answer the direction are taken first. This is what makes a direction stick across a whole deck rather than landing on whichever card the seed happened to favour. |
| Library scoring | Its words count as theme keywords (and expand through the same clusters), so an asset the creator asked for can clear the theme gate. A mood or style it names (*calm, minimal*) replaces the default spread instead of adding to it. |
| Range animations | Its words join the theme's when matching the reaction-animation set, so a Verto steered toward "recycling" reacts with recycling. |
| Mobile backdrop | Widens the themes that backdrop is matched on. |

**Vetoes.** A negated clause — *"no offices", "avoid corporate stock"* — is
never searched for; it is filtered *out* of both the Pexels results and the
curated pool. Getting this backwards would be worse than ignoring it, so the
parser splits on clauses and flips only what follows the negation word: *"warm
and no offices"* wants warmth and vetoes offices. A veto that would leave a
slot with nothing gives way only where the slot cannot be empty — the
background and the range animation (which falls back to the neutral General
set rather than playing the vetoed one). A card panel is allowed to come back
blank: a clean panel is a better answer to "no offices" than an office.

**What it takes from your words.** A direction is prose aimed at us, so the
scaffolding people wrap it in — *make, keep, look, give, a bit, the images,
this verto* — is stripped along with ordinary filler, and only the words that
name something visual survive. What's left keeps the order it was written in,
and the first two ride along on the search. The editor prints the result under
the box (*"Searching for: professional, corporate"*), because a prompt that
parses to something you didn't mean is otherwise invisible until the pictures
come back looking untouched. That is exactly how this shipped broken the first
time: *"We want to make this verto professional and corporate"* reduced to
`make verto` and searched for that.

**A direction that names a subject leads; one that names a treatment shades.**
The two are told apart by whether the theme clusters recognise any of its words
— "professional and corporate" reaches the work cluster, "warm minimal" reaches
nothing, because no cluster claims an adjective.

- **Names a subject** → the direction goes first. A prompt-first query (the
  direction plus one theme word) is tried *before* each card's own search, its
  vocabulary counts toward the relevance floor, and on-direction results are
  applied ahead of the rest. A community-sport Verto told "professional and
  corporate" comes back corporate — background and every card.
- **Names only a treatment** → nothing above applies, and the direction does
  what it always did: rides along on the query and narrows the library's
  mood/style. It biases *among* pictures of the Verto's own subject rather
  than replacing them.

If a direction isn't moving things far enough, name a subject in it: *"offices,
meeting rooms, city skyline"* moves a deck much further than *"more formal"*.

**Safety is not negotiable by it.** The direction goes through the same
age-aware content-safety scrub as every other search term, and a charged
protest-visual word in it is stripped exactly as it would be in a theme — the
imagery box is not where a Verto declares a charged topic; its theme is.

## 5. The Verto library

The bundled library lives at `app/assets/images/verto-library/`, indexed by a
`manifest.yml` that the matcher reads live (no rebuild needed — drop a file
in, add its entry, and it's immediately eligible).

Categories:

| Category | Used for |
|---|---|
| `backgrounds` | Full-bleed Verto backdrops |
| `left_panel` | Tier-1 themed card panels |
| `select_art` | Tier-2 art for choice-type cards |
| `range_art` | Tier-2 art for scale-type cards (range/rating/NPS) |
| `swipe_cards` | Tap-card statement images |
| `mobile_backgrounds` | The soft mobile card backdrop |

Each entry carries `file` plus optional tags: `themes`, `age`, `mood`,
`style`, `card_types`, and `keywords` (the heavyweight, subject-specific
matches). **To add an asset:** drop the file in the right folder, add a
manifest entry, and tag it with the themes/keywords you want it found by —
the more specific the keywords, the more precisely it will be picked.

## 6. The Pexels integration

- **What's searched.** Photo and video search on the official Pexels API,
  with slot-appropriate orientation (landscape for backgrounds, portrait for
  cards, square for swipe statements) and exact crops per slot so images fit
  their frame precisely.
- **Configuration.** One environment variable (`PEXELS_API_KEY`, or legacy
  `PEXELS`). No key → the feature is simply off and the library takes over;
  development, CI and tests never touch the network.
- **Resilience.** Pexels calls never break Verto creation. Any API problem
  quietly returns "no results" and the library fallback engages.
- **Efficiency.** During a single population run, each distinct search query
  hits the API at most once, however many cards share it.
- **Relevance floor.** An uncurated source gets *more* scrutiny, not less: a
  returned photo is only auto-applied if its description actually shares
  subject vocabulary with the card and theme (function words don't count). A
  photo that clears nothing is discarded and the library fallback engages —
  so a loosely-matched or off-topic stock photo never lands on a card. Known
  limitation: a **lowercase minor place name** in card copy ("schools in
  peckham") can still slip into a query; the relevance floor is the backstop.
- **Credit.** Every applied Pexels photo/video stores the photographer's name
  and profile link, rendered as the on-card credit. Applying a library image
  or upload clears the credit (nothing to credit).

## 7. What is *not* photo-driven

- **Range cards** play a reactive animated character that responds to the
  slider position. The animation *set* is treated **like any other asset** —
  theme-matched, re-rolled by Shuffle, and swappable by the creator:
  - *Picked at creation and on every Shuffle.* The populator chooses a
    **theme-matched** set — a Climate Verto reacts with recycling/flowers/sun,
    a Sport Verto with a ball or stopwatch, a Food Verto with pizza — seeded so
    the same seed is stable and Shuffle's new seed re-rolls it, exactly like an
    image. When nothing is on-theme it falls back to a neutral **General** set
    (never an arbitrary sport animation on an unrelated Verto).
  - *Matched on the theme's OWN words, not the image cluster expansion.* The
    picker matches `NpsHelper::RANGE_THEME_KEYWORDS` against the Verto theme's
    literal words (singularised). It deliberately does **not** use
    `AssetPopulator.theme_keywords` — the image-library `theme_clusters` bridge
    topics for stock-photo breadth (food ↔ lifestyle ↔ "game"), which used to
    leak generic words and land a football on a food Verto.
  - *Swapped by the creator, like other assets.* A **Change animation** CTA
    (`animation-picker` modal) sits on the range card's left panel — the
    animation counterpart of the media picker — showing every set as a grouped,
    live-preview grid. Picking one applies it live and persists as the card's
    `range_theme`; it stays the source of truth until the next Shuffle.
  - The sets, their groups and theme keywords live in `NpsHelper`
    (`RANGE_THEME_GROUPS` / `RANGE_THEME_KEYWORDS` / `range_themes_for`); each
    slug is a folder of five Lottie frames under `app/assets/lottie/<slug>/`.
  - *The age card is the exception.* Its slider has a stop per age band, and
    it plays a set bound to it alone — `NpsHelper::AGE_BAND_THEME`, seven
    frames in band order (online music, wireless headphones, an MP3 player, a
    CD, a cassette, vinyl, a gramophone) — so every answer plays its own file
    rather than sampling five poses across seven stops. The set is not in the
    picker and the populator never draws it; the card plays it whatever
    `range_theme` it was stamped with before the set existed, and the
    sanitiser drops that stamp on the next save.
- **NPS cards** render a procedurally drawn "vessel" that fills as the score
  rises — generated on the fly and tinted with the Verto's brand colour, not
  an image file.
- **Grid and list options** get small subject icons via an exact-keyword
  lookup against a bundled icon set. It's deliberately conservative: if an
  option's wording doesn't clearly match an icon, the tile shows a clean
  colour gradient instead of guessing.
- **Brand palette** doesn't choose imagery, but tints the backdrop scrim,
  overlays and the NPS vessel so photos and UI read as one design.

## 8. Creator overrides in the editor

The media picker (the "Add design" / "Change media" button on any card or the
background) offers:

- **Your brand library** — the *account's own* uploaded brand assets, shown
  first (only when the organisation has any). Admins manage this set on the
  branding page (Members → Brand asset library); it's scoped to the one
  organisation and stored via Active Storage. See §11.
- **Verto Library** — the curated tiles, always available.
- **Recommended** — the same scoring engine's top suggestions for *this*
  card, shown only when something genuinely scores.
- **Pexels search** — live photo/video search (queries are safety-scrubbed;
  results carry their credit automatically).
- **Upload** — the creator's own image. Big files are downscaled and
  recompressed in the browser first, then **AI-moderated** before they're
  applied (see §9).

New Tap-card statements added in the editor self-serve an image from the
swipe pool, preferring ones the deck isn't already using — the same
no-repeats rule the automatic pass follows.

### Reframing what's already there

Every card's media, and every Tap-card statement's picture, carries a
**Reposition** control beside its Change-media CTA. Two different jobs sit
behind it:

- **Reposition** (always available) records *where the media sits* inside the
  frame that crops it — `focal_x` / `focal_y` on a card, one entry of the
  positional `option_focals` array on a statement, all 0–100 percentages fed
  straight to `background-position` (a photo) or `object-position` (a video).
  Nothing is re-encoded, so the whole picture is kept and the choice can be
  changed for ever. Each axis only bites where the frame actually crops that
  way: vertical in the mobile header strip and the device frames, horizontal
  in the ordinary desktop panel.
- **Crop & zoom** (a button inside the same stage) is the destructive path:
  it redraws the image on a canvas at the slot's fixed ratio. That only works
  on a **same-origin still** — a Pexels URL taints the canvas and the encode
  throws, and a video has no canvas path at all — so the button is simply
  absent for a stock photo or a clip. Where the pre-crop original was kept
  (`image_source` + `image_crop`, stamped by an upload's own crop) the stage
  reopens seeded from it and can zoom back **out**; where it wasn't, it says so
  and offers reposition-and-zoom-in only.

That split is why repositioning, not cropping, is what every image can have.
Swapping the picture — by hand or by a Shuffle — clears the framing with it:
a focal point describes one photograph's subject, and on the next picture it
would be a shove rather than a setting.

**Range cards** have no photo to swap, so they get their own peer of the media
picker: a **Change animation** CTA on the card's left panel opens the
`animation-picker` modal — a grouped, live-preview grid of every reaction set
(Sport / Climate / Wellbeing / General). Picking one swaps the panel animation
live and persists as the card's `range_theme`, exactly as the media picker does
for images. The age card has no such CTA: its set is bound to it (§7).

## 9. Safety gates

Four independent layers keep imagery appropriate:

1. **Search-word filtering (Pexels).** Queries are scrubbed of blocked terms
   before they're sent, and any result whose description matches a blocked
   term is dropped. Vertos aimed at younger audiences apply a stricter
   additional list (alcohol, smoking, gambling and similar are filtered out
   on top of the general list).
2. **Brand-neutrality suppression (Pexels, auto-population only).** A *separate*
   layer from PG safety: protest/activism imagery (marches, rallies, placards,
   named protest movements) is dropped from auto-applied results, so a neutral
   Verto never picks up charged stock — **unless the Verto's own theme invokes
   that subject** (an "activism" Verto is allowed its protest imagery). This is
   a deliberately narrow, protest-*visual* list; the broader political
   vocabulary is intentionally left out (suppressing it would itself be an
   editorial stance). It applies only to unsupervised auto-population — the
   creator's own manual Pexels searches in the editor are untouched.
3. **AI moderation (uploads).** Creator uploads are reviewed by an AI vision
   check against the Verto's audience age before being applied — PG standards
   for everyone, stricter for young audiences. If moderation can't verify an
   image, the upload is blocked rather than waved through.
4. **Storage rules.** A Verto can only persist imagery from trusted shapes:
   bundled library assets, Pexels CDN URLs, or small inline uploads — and
   video only from the Pexels video CDN. The player's security policy
   likewise only allows images and media from those sources, so nothing
   off-list can render even if it somehow got stored.

**Known limitation (young audiences).** The Pexels safety and neutrality
layers read a photo's *description* (alt text), not its pixels — auto-picked
Pexels images are not vision-moderated (only creator *uploads* are). So a
visually mature image with clean alt text can still pass on an auto-pick. The
theme-anchoring, relevance floor and (for the known cases) theme-only
demographic cards remove the queries that surfaced such images, but the
general gap remains. Proposed follow-up: vision-moderate auto-picks for
kids/teen Vertos, or a curated-library-only mode for young audiences.

## 10. The per-account brand asset library

Separate from the shared, code-bundled Verto Library, each **organisation has
its own brand asset library** — images the account uploads once and can then
drop onto any card or background from the editor's media picker.

- **Storage.** `Organisation has_many_attached :assets` (Active Storage), same
  image allow-list as the logo, capped at 5 MB/file and `MAX_ASSETS` in total.
- **Management.** Admins upload / remove assets on the branding page (Members →
  *Brand asset library*), via `OrganisationAssetsController` (`create` /
  `destroy`, admin-gated). Removal purges the blob synchronously, like the logo.
- **Where they appear.** The media picker's Library tab shows a **"Your brand
  library"** section first (only when the org has assets), each tile a normal
  `media-library-item` so selection flows through the existing `pickLibraryItem`
  path unchanged.
- **Security.** Asset URLs are same-origin Active Storage blob paths
  (`/rails/active_storage/…`). They're already allowed by the CSP (`img-src
  :self`) and pass storage sanitisation via `Survey::ACTIVE_STORAGE_IMAGE_URL`
  (anchored to the app's own mount + an image extension; no cross-origin, no
  `url('…')` breakout).
- **Production persistence.** Active Storage runs on the local Disk service
  (`Rails.root/storage`), backed in production by a **Render persistent disk**
  mounted at `/rails/storage` (`render.yaml` → `disk:`), so uploaded assets and
  logos now survive deploys. Two consequences of attaching a disk: the service
  is pinned to a single instance and each deploy is a brief stop/start rather
  than zero-downtime (fine here — already one `starter` instance). The disk can
  land root-owned on a freshly mounted volume, which the non-root app user
  can't write; `bin/docker-entrypoint` self-heals when run as root and
  otherwise logs a loud, non-fatal warning if `/rails/storage` isn't writable,
  so a mount-permission misconfig surfaces in the logs rather than as silent
  upload failures. (A move to S3/GCS in `storage.yml` + `production.rb` remains
  the alternative if object storage is ever preferred.)

## 11. Quick reference

| Slot | Primary | Fallback | Creator override |
|---|---|---|---|
| Background | Pexels landscape (theme query) | Library `backgrounds` (theme-gated, never blank) | Brand library / Library / Pexels / upload |
| Card panel | Pexels portrait (theme-anchored query, must clear the relevance floor) — every 3rd media card a video | Tier 1 themed → Tier 2 type art → blank | Brand library / Library / Recommended / Pexels / upload |
| Tap statements | Pexels square, unique per statement | `swipe_cards` pool, no repeats in a card | Per-statement pick in editor |
| Range panel | Reactive animation, theme-matched set (Shuffle re-rolls it); the age card's own seven-frame set | General animation set | Per-card **Change animation** picker (not on the age card) |
| NPS control | Procedural vessel (always) | — | — |
| Grid/list tiles | Keyword icon or gradient (always) | — | — |
| Mobile backdrop | Library `mobile_backgrounds`, theme-matched | Random from the pool (never empty) | — |

### Pointers into the code

- `app/services/asset_populator.rb` — the population flow, scoring, tiers,
  seeding and de-duplication; `app/assets/images/verto-library/manifest.yml`
  — the library index and tagging vocabulary.
- `app/services/pexels_client.rb` — Pexels API, orientations, crops, video
  band; `app/services/content_safety.rb` — the search-word filter.
- `app/services/image_moderator.rb` + `SurveysController#moderate_image` —
  upload moderation; `Survey.sanitize_cards_images!` — the storage rules.
- `app/javascript/controllers/media_picker_controller.js` — the editor's
  picker; `SurveysController#pexels_search` / `#shuffle_assets` — its
  endpoints.
- The direction prompt (§4a): passed per-shuffle as
  `AssetPopulator.new(survey, direction:)` and never persisted, parsed by
  `AssetPopulator.direction_buckets` (wants vs. vetoes) and applied through the
  populator's `direction_*` helpers — `direction_subject?` decides whether it
  leads or only shades. `AssetPopulator.direction_reading` is what the editor
  reports back after a run; `app/javascript/controllers/shuffle_controller.js`
  opens the panel.
- `Organisation#assets` + `OrganisationAssetsController` — the per-account brand
  asset library; surfaced in `surveys/_media_modal` ("Your brand library") and
  managed on `memberships/index`; `Survey::ACTIVE_STORAGE_IMAGE_URL` allows its
  blob URLs to be stored (see §10).
- `app/helpers/nps_helper.rb` + `lottie_player_controller.js` — the range
  animation and NPS vessel; `NpsHelper.range_themes_for` picks the theme-matched
  animation set the populator/Shuffle applies as a card's `range_theme`.
  `animation_picker_controller.js` (+ `surveys/_animation_modal`) is the
  creator's **Change animation** picker; it drives
  `survey_editor_controller.js#setRangeTheme` to apply. `app/lib/option_icon_library.rb`
  — grid/list option icons.
