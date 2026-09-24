# Pre-populates a Verto's `background_image`, each card's left-panel `image`,
# and (for tap_card cards) each statement's `option_images` from the curated
# verto-library, using a two-tier hierarchy for the left-panel image:
#
#   Tier 1 — Themed match from manifest.left_panel that scores above
#            TIER1_MIN_SCORE against the survey's theme + audience and the
#            card's text + options.
#   Tier 2 — Card-type-family art (select_art for the select/grid family,
#            range_art for range/rating/nps). NOT used for tap_card: those
#            get their imagery on the statement cards themselves via
#            `option_images`, not on the left panel.
#   (No SVG fallback — leave the card image blank rather than reach into
#    the design-system SVGs at app/assets/images/.)
#
# tap_card statement imagery: every tap_card gets a parallel `option_images`
# array drawn from manifest.swipe_cards, one image per entry in `options`,
# no repeats within a card and preferring assets not already used elsewhere
# in the survey.
#
# range cards carry no still image (their left panel plays a reactive Lottie
# character) — instead they get a `range_theme` slug, seeded and theme-matched
# via NpsHelper.range_themes_for, so Shuffle re-rolls the animation the same
# way it re-rolls imagery.
#
# Background uses manifest.backgrounds with the same scoring. If every entry
# scores zero the seed selects one round-robin so the editor never opens
# with a blank backdrop.
#
# Shuffle: pass a different `seed:` and call populate! again.
#
# ── The direction prompt (AssetPopulator.new(survey, direction:)) ──────────
# Optional free text the creator types beside Shuffle saying what they want out
# of the Verto's content and imagery — "warm, outdoors, small groups, no
# offices". It belongs to ONE shuffle: it arrives with the click, steers that
# run, and is not stored. It first shipped saved on the Verto so the box would
# stay filled in, which turned it into invisible state — a steer typed once
# went on quietly deciding every later shuffle, under a panel headed "Steer
# THIS shuffle". A prompt box that comes back pre-filled is answering a
# question nobody asked again.
#
# It is a PREFERENCE laid over every existing signal, never a
# replacement for them: the theme still anchors the search, the card still
# names its subject, safety and relevance still decide what may be applied.
# Concretely it does four things (see the "Direction" section below):
#
#   * leads every Pexels query with up to DIRECTION_QUERY_TERMS of its words,
#     with a one-step relaxation back to the undirected query when the
#     narrowed one finds nothing;
#   * widens the curated library's theme match/scoring with its words, and
#     narrows `mood`/`style` to the ones it names;
#   * feeds the range card's reaction-animation match alongside the theme;
#   * vetoes: a clause the creator negated ("no offices") is never searched
#     for and is filtered OUT of both Pexels results and the curated pool.
#
# And, when it names a subject area rather than a treatment, it leads outright
# — see direction_subject?.
#
# Nothing here reads the survey for it. A populator built without a direction
# behaves exactly as it did before the feature existed, which is what every
# caller other than Shuffle gets.
class AssetPopulator
  MANIFEST_PATH       = Rails.root.join("app/assets/images/verto-library/manifest.yml").freeze
  BACKGROUND_DIR      = "verto-library/backgrounds".freeze
  LEFT_PANEL_DIR      = "verto-library/left-panel".freeze
  SELECT_ART_DIR      = "verto-library/select-art".freeze
  RANGE_ART_DIR       = "verto-library/range-art".freeze
  SWIPE_CARDS_DIR     = "verto-library/swipe-cards".freeze
  MOBILE_BG_DIR       = "verto-library/mobile-backgrounds".freeze

  TIER1_MIN_SCORE     = 5
  SELECT_TYPES        = %w[multiple_choice select_many select_one_grid select_many_grid yes_no prioritise].freeze
  SCALE_TYPES         = %w[range rating nps].freeze
  STOP_WORDS          = %w[
    the a an and or of for in on at to with from your our their this that
    do don't are is be how what when where why
  ].to_set.freeze

  # Filler specific to *question* text — interrogatives, second-person address,
  # auxiliaries and generic survey verbs — that name no visual subject. Removed
  # (on top of STOP_WORDS) when building the image-search query so what's left
  # is what the question is actually about ("which laptop brand would you
  # prefer?" → "laptop brand"), not the survey scaffolding around it.
  QUESTION_FILLER     = %w[
    which would could should will shall can may might must
    was were been being has have had does did done
    you your yours we our ours us they them their i me my mine
    like likes liked love loves want wants need needs prefer prefers
    think thinks feel feels choose chooses choosing select selecting pick picks
    rate rank tell describe say said please
    most least more less much many any some all none every each other else
    favourite favorite best worst good bad better
    often usually generally overall about really very just quite
    agree disagree
  ].to_set.freeze

  # ── Query hygiene (Pexels auto-population only) ───────────────────────────
  # Geography is CONTEXT, not the subject to depict: "schools in north London"
  # must search "school", never the place. Stripped from both theme and card
  # terms before a query is sent. (Editor manual search is untouched — the
  # creator types deliberately.)
  GEO_COMPASS = %w[
    north south east west northern southern eastern western
    northeast northwest southeast southwest central inner outer greater
  ].to_set.freeze

  # Geo nouns + a pragmatic net of major UK place names, so a lowercase theme
  # ("schools in north london") still loses the location. KNOWN v1 LIMITATION:
  # a lowercase MINOR place ("peckham") leaks through — same class of leak as
  # the original bug, far rarer; the relevance floor is the backstop.
  GEO_NOUNS = %w[
    city cities town towns village villages borough boroughs county counties
    district districts region regions area areas neighbourhood neighbourhoods
    suburb suburbs postcode council countryside local nearby
    uk britain british england english scotland scottish wales welsh
    ireland irish europe european
    london manchester birmingham leeds glasgow liverpool bristol sheffield
    edinburgh cardiff belfast newcastle nottingham
  ].to_set.freeze

  # Boilerplate in Pexels video-page slugs that must never contribute to a
  # relevance score.
  SLUG_NOISE = %w[https http www com pexels video videos photo photos].to_set.freeze

  # Card types with no depictable subject of their own — welcome/checkpoint
  # scaffolding. Their imagery is anchored to the Verto theme only; their own
  # copy (tone, not subject) is ignored. Mirrors CardTypes::NON_QUESTION_TYPES.
  SCAFFOLDING_TYPES = CardTypes::NON_QUESTION_TYPES.to_set.freeze

  # Relevance floors for an applied Pexels candidate (scored alt/slug against
  # the sent query, library-parity weights: +4 card subject, +3 theme term).
  CARD_RELEVANCE_FLOOR  = 4  # the photo must depict something the card names
  THEME_RELEVANCE_FLOOR = 3  # backgrounds / cards with no subject of their own

  # ── Direction-prompt vocabulary ───────────────────────────────────────────
  # How many of the direction's words ride along on a Pexels query. Deliberately
  # small: Pexels narrows hard on every extra term, and a direction is a
  # preference — it must not out-shout the theme and the card's own subject in
  # the query it's appended to. The REST of the direction is far from wasted;
  # it still drives library theme/mood/style scoring, the vetoes, and the range
  # card's animation match. This is only the Pexels hint.
  DIRECTION_QUERY_TERMS = 3

  # Words that flip the rest of their clause from "want" to "don't want".
  # Without this a direction reading "no offices" would put `offices` INTO the
  # search — the exact opposite of what was typed. "less"/"fewer" count: in an
  # imagery note "less corporate" is a veto, not a quantity.
  NEGATION_CUES = %w[
    no not never none nothing avoid avoiding without exclude excluding except
    omit omitting skip skipping minus less fewer dont doesnt isnt arent
  ].to_set.freeze

  # Instruction scaffolding — the words people wrap a direction in, plus the
  # nouns they use to refer to the Verto and its pictures. None of them names
  # anything depictable, and leaving them in is not harmless: they are usually
  # at the FRONT of the sentence, so they crowded out the actual instruction in
  # the bounded slice sent to Pexels. "We want to make this verto professional
  # and corporate" reduced to `make verto` — a generic verb and our own product
  # name — and searched for that while "professional corporate" sat unused.
  #
  # STYLE vocabulary is deliberately absent: "photo" is filler in "make the
  # photos warm" but is the whole instruction in "photos, not illustrations",
  # and DIRECTION_STYLES needs to still see it. The near-synonyms that carry no
  # style meaning (picture/image/visual) are filtered instead.
  DIRECTION_FILLER = %w[
    make makes making made keep keeps keeping give gives giving
    look looks looking show shows showing use uses using put puts putting
    try tries trying get gets getting turn turns
    vibe vibes aesthetic feeling feelings mood moods tone
    bit lot lots kind sort type way
    something anything everything
    image images imagery picture pictures visual visuals
    verto vertos deck decks survey surveys questionnaire
    card cards question questions
    theme themes style styles
    thing things stuff
  ].to_set.freeze

  # Direction word → manifest `mood:` value. The manifest vocabulary is small
  # and closed (playful | energetic | festive | calm | serious | warm), so a
  # handful of everyday synonyms per value is the difference between the box
  # working and the creator having to guess our tag names.
  DIRECTION_MOODS = {
    "playful" => "playful", "fun" => "playful", "cheerful" => "playful", "lighthearted" => "playful",
    "energetic" => "energetic", "energy" => "energetic", "dynamic" => "energetic", "lively" => "energetic", "active" => "energetic",
    "festive" => "festive", "celebratory" => "festive", "celebration" => "festive", "party" => "festive",
    "calm" => "calm", "calming" => "calm", "quiet" => "calm", "peaceful" => "calm", "serene" => "calm", "gentle" => "calm",
    "serious" => "serious", "formal" => "serious", "professional" => "serious", "sober" => "serious", "corporate" => "serious",
    "warm" => "warm", "warmth" => "warm", "cosy" => "warm", "cozy" => "warm", "friendly" => "warm", "inviting" => "warm"
  }.freeze

  # Direction word → manifest `style:` value (photo | illustrated | vector |
  # vibrant | minimal | warm). Same reasoning as DIRECTION_MOODS.
  DIRECTION_STYLES = {
    "photo" => "photo", "photos" => "photo", "photography" => "photo", "photographic" => "photo", "realistic" => "photo",
    "illustrated" => "illustrated", "illustration" => "illustrated", "illustrations" => "illustrated", "drawn" => "illustrated", "sketched" => "illustrated",
    "vector" => "vector", "flat" => "vector", "graphic" => "vector", "iconic" => "vector",
    "vibrant" => "vibrant", "colourful" => "vibrant", "colorful" => "vibrant", "bold" => "vibrant", "bright" => "vibrant", "punchy" => "vibrant",
    "minimal" => "minimal", "minimalist" => "minimal", "simple" => "minimal", "clean" => "minimal", "sparse" => "minimal", "understated" => "minimal"
  }.freeze

  # The default mood spread, used when the direction names none of its own.
  DEFAULT_MOODS = %w[playful energetic festive warm calm].freeze

  class << self
    def manifest
      @manifest_mtime ||= nil
      mtime = File.mtime(MANIFEST_PATH) rescue nil
      if @manifest.nil? || @manifest_mtime != mtime
        @manifest = MANIFEST_PATH.exist? ? YAML.safe_load(MANIFEST_PATH.read, permitted_classes: [ Symbol ]) || {} : {}
        @manifest_mtime = mtime
      end
      @manifest
    end

    def reset_manifest_cache!
      @manifest      = nil
      @manifest_mtime = nil
    end

    # Picks a mobile card background URL for a survey by theme matching
    # against manifest.mobile_backgrounds. Used by the player view to
    # tint the card body on mobile with a brand-appropriate image
    # (rendered behind a white scrim so the question text stays readable).
    # Returns nil if no themed match exists — the white card body stays
    # plain in that case.
    def mobile_bg_url_for(survey)
      candidates = Array(manifest["mobile_backgrounds"])
      return nil if candidates.empty?

      # Theme-only. This runs on the PLAYER, long after any shuffle, so there
      # is no direction in scope — a steer belongs to the run it was typed for.
      query  = { themes: theme_keywords(survey.theme), age: age_buckets(survey.audience_age) }
      themed = candidates.select do |a|
        asset_themes = Array(a["themes"]).map { |t| t.to_s.downcase }
        (asset_themes & query[:themes]).any?
      end
      # No themed match? Fall back to a random pick from the whole pool so
      # the card body still gets a mobile background instead of going blank.
      pool = themed.presence || candidates

      # Stable per-survey choice; same Verto always lands on the same
      # picture so re-rendering doesn't flicker.
      chosen = pool[Random.new("mbg-#{survey.id}".hash).rand(pool.size)]
      ActionController::Base.helpers.asset_path("#{MOBILE_BG_DIR}/#{chosen['file']}")
    end

    # The picture a shared /play link unfurls with, for a Verto that has no
    # imagery of its own. Same shape as mobile_bg_url_for above and for the
    # same reasons — theme-only (this runs on a request from a crawler, long
    # after any shuffle), and seeded by survey id so the link a person shared
    # yesterday unfurls with the same picture today.
    #
    # The reason it exists rather than letting og:image be absent: a link with
    # no picture is a grey nothing in WhatsApp, and "most Vertos get one" is not
    # a guarantee anybody can rely on when they paste a link into a group chat.
    # Falling back to the whole pool when no theme matches is what makes this
    # total — it cannot return nil, so Survey#share_image_url cannot either.
    def share_image_url_for(survey)
      candidates = Array(manifest["backgrounds"])
      return nil if candidates.empty?

      query  = { themes: theme_keywords(survey.theme) }
      themed = candidates.select do |a|
        (Array(a["themes"]).map { |t| t.to_s.downcase } & query[:themes]).any?
      end
      pool = themed.presence || candidates
      # Digest, NOT String#hash: Ruby seeds String#hash per PROCESS, so a
      # sibling method's "stable per-survey choice" is only stable until the
      # next deploy. That is survivable for a background nobody bookmarks; it is
      # not survivable here, where the URL goes into og:image and is cached by
      # every chat app that has ever unfurled the link. (mobile_bg_url_for above
      # has the same latent flaw — left alone deliberately, because changing it
      # would repaint live Vertos for a guarantee nothing currently depends on.)
      seed   = Digest::SHA256.hexdigest("share-#{survey.id}")[0, 8].to_i(16)
      chosen = pool[seed % pool.size]
      ActionController::Base.helpers.asset_path("#{BACKGROUND_DIR}/#{chosen['file']}")
    end

    # Helpers below mirror the instance-level versions so callers outside
    # the populator don't need an instance just to compute these.
    def theme_keywords(theme)
      raw = theme.to_s.downcase.scan(/[a-z]+/).reject { |w| STOP_WORDS.include?(w) }
      expand_themes(raw)
    end

    # Expand a list of theme keywords through manifest.theme_clusters so
    # conceptually-related themes pull each other in. A "food" survey
    # picks up `nature` / `sustainability` / `healthy` from the same
    # cluster, so a nature-themed background still scores for a food
    # Verto. Clusters are bidirectional.
    def expand_themes(themes)
      clusters = Array(manifest["theme_clusters"]).map { |c| Array(c).map { |s| s.to_s.downcase } }
      expanded = themes.dup
      clusters.each do |cluster|
        expanded.concat(cluster) if (themes & cluster).any?
      end
      expanded.uniq
    end

    # ── Direction prompt parsing ──────────────────────────────────────────
    # Splits `survey.shuffle_direction` into [wanted, unwanted]: the words the
    # creator is asking for, and the words they've vetoed. Class-level because
    # the player's mobile-backdrop pick reads the same direction without
    # building a populator.
    #
    # A direction is written as a list of clauses ("warm light, outdoors, no
    # offices"), so clauses are the unit. Within one clause the first negation
    # cue flips everything AFTER it into the veto bucket and leaves everything
    # before it in the wanted bucket — which is what makes both "warm and no
    # offices" and "no offices and suits" come out right. Getting this wrong
    # is not a near-miss: it would search for the one thing the creator asked
    # us to keep out.
    def direction_buckets(text)
      wanted, unwanted = [], []
      text.to_s.downcase.split(%r{[,;./\n|•—–]+}).each do |clause|
        words = clause.scan(/[a-z']+/).map { |w| w.delete("'") }
        cue   = words.index { |w| NEGATION_CUES.include?(w) }
        if cue
          wanted.concat(words.first(cue))
          unwanted.concat(words.drop(cue + 1))
        else
          wanted.concat(words)
        end
      end
      [ direction_tokens(wanted), direction_tokens(unwanted) ]
    end

    # Filler removal shared with the instance-level salient_words: what's left
    # is what a word actually depicts.
    def salient_tokens(words)
      words.reject { |w| w.length < 3 || STOP_WORDS.include?(w) || QUESTION_FILLER.include?(w) }
    end

    # The same, plus the instruction scaffolding people wrap a DIRECTION in.
    # A direction is prose aimed at us ("we want to make this verto…"), not
    # question copy, so it carries a layer of filler question text never does.
    def direction_tokens(words)
      salient_tokens(words).reject { |w| DIRECTION_FILLER.include?(w) }.uniq
    end

    # True when a manifest asset is described by any vetoed word — matched
    # against every tag it carries (themes, keywords, mood, style) and
    # singularised on both sides so "no offices" also drops an `office` asset.
    def vetoed_asset?(asset, unwanted)
      return false if unwanted.empty?
      tags = %w[themes keywords mood style].flat_map { |k| Array(asset[k]) }
                                           .map { |t| t.to_s.downcase.singularize }
      (tags & unwanted.map(&:singularize)).any?
    end

    # What a direction prompt reduces to: the terms that will be searched on,
    # and the words that will be kept out. Shuffle reports this back to the
    # editor after a run, because the alternative is what happened the first
    # time this shipped — "We want to make this verto professional and
    # corporate" reduced to `make verto`, searched for THAT, and nothing
    # anywhere said why the pictures came back unchanged in character. A parse
    # the creator can see is a parse they can correct.
    #
    # Needs the survey as well as the text: safety scrubbing is audience-
    # dependent and the charged-term strip reads the theme.
    def direction_reading(survey, direction)
      pop = new(survey, direction: direction)
      { toward: pop.send(:direction_terms), avoiding: pop.send(:direction_vetoes) }
    end

    def age_buckets(audience_age)
      s = audience_age.to_s.downcase
      buckets = []
      buckets << "kids"        if s.match?(/\bkids?\b|\bchildren\b|\b(?:5|6|7|8|9|10|11)\b|primary[- ]school/)
      buckets << "teen"        if s.match?(/\bteen|\b1[2-7]\b|high[- ]school|secondary[- ]school/)
      buckets << "young-adult" if s.match?(/\b(?:18|19|20|21|22|23|24)\b|18.?24|18.?29|young|university|student|gen ?z/)
      buckets << "adult"       if s.match?(/\b(?:25|26|27|28|29|30|31|32|33|34|35|36|37|38|39|40|41|42|43|44|45|46|47|48|49|50|51|52|53|54)\b|25.?34|35.?44|45.?54|adults?|parents?|professionals?|workers?/)
      buckets << "senior"      if s.match?(/\b(?:55|56|57|58|59|60|65|70|75|80)\b|55\+|seniors?|elderly|retired/)
      buckets.empty? ? [ "all" ] : buckets
    end

    # Full list of swipe-card asset URLs (resolved through Sprockets so the
    # paths are fingerprinted). Used by the editor when a user adds a new
    # statement to a tap_card whose option_images were already populated —
    # the client picks an unused URL from this list.
    def swipe_card_urls
      helpers = ActionController::Base.helpers
      Array(manifest["swipe_cards"]).map do |a|
        helpers.asset_path("#{SWIPE_CARDS_DIR}/#{a['file']}")
      end
    end

    # Top-N curated assets for the picker's "Recommended" section, ranked by
    # the same scoring used by populate!. Empty array when nothing scores
    # above zero so the picker can hide the section instead of misleading.
    #
    #   recommended_paths(survey, context: :background)
    #   recommended_paths(survey, context: :card, card: cards_hash)
    def recommended_paths(survey, context:, card: nil, limit: 8)
      pop = new(survey)
      case context
      when :background then pop.send(:background_recommendations, limit)
      when :card       then pop.send(:card_recommendations, card, limit)
      else                  []
      end
    end
  end

  # `direction`: the creator's optional steer for THIS run (see the header).
  # Absent for every caller but Shuffle, and absent means "behave as if the
  # feature isn't there".
  #
  # `fill_only`: skip any card that already holds a photo, a video or an
  # animation. This is the difference between the product's two callers, and it
  # is worth naming rather than inferring. Shuffle is the creator saying "give
  # me DIFFERENT pictures", so it must overwrite — that is the feature. Auto
  # population is the platform saying "you have none yet", so it must not:
  # FinishVertoSetupJob runs while its creator is already in the editor and can
  # have picked their own imagery in the meantime.
  #
  # (The job's comment has claimed since it was written that population "only
  # fills in cards that have no image yet". Until this flag existed that was
  # simply untrue — pick_card_image_path skipped only tap_card, range and
  # `lottie` cards, and apply_card_media overwrote unconditionally.)
  def initialize(survey, seed: nil, direction: nil, fill_only: false)
    @survey    = survey
    @seed      = seed || survey.id
    @fill_only = fill_only
    @direction = Survey.sanitize_shuffle_direction(direction)
    # Memoises Pexels search results per (query, orientation) so a populate!
    # run makes at most one API call per distinct query — keeps us well inside
    # the rate limit even for a long Verto.
    @pexels_cache       = {}
    @pexels_video_cache = {}
  end

  # Compute the picks and save them positionally over this Verto's deck. The
  # caller that owns the deck outright — Shuffle, and the wizard's BuildVertoJob,
  # both of which run when nobody else is writing — uses this.
  def populate!
    compute!
    @survey.save!
  end

  # Compute the same picks, then write them as a MERGE rather than as a deck.
  #
  # For the import path, where the creator is already in the editor and can save
  # the deck from under this run. A whole-deck write there would silently undo
  # whatever they had just done — the same hazard translate_survey!'s digest
  # guard exists for, in the other direction.
  #
  # The picks are computed against the deck as loaded and then applied, under a
  # row lock, to the deck as it is NOW: matched by cid (never by index — the
  # creator can insert, delete or reorder inside this window, and index-matching
  # would paste the right picture onto the wrong card), and only onto cards that
  # still have no media of their own. So the creator's edits and this run's
  # imagery both land, and neither erases the other.
  def populate_merged!
    compute!
    picks      = Array(@survey.cards).map { |c| c.is_a?(Hash) ? c.dup : c }
    background = @survey.background_image
    # compute! left its positional result on the record in memory. Drop it
    # before locking — the merge below is the write, and `with_lock` refuses a
    # record carrying unpersisted changes anyway (it would have nothing sane to
    # do with them).
    @survey.reload

    @survey.with_lock do
      live = Survey.ensure_cids!(Array(@survey.cards))
      @survey.cards = Survey.keep_setup_media(picks, live)
      # Only if the creator hasn't chosen one. Unlike the cards this is a
      # column, so the editor's autosave never sends it and never clears it.
      @survey.background_image = background if @survey.background_image.blank?
      @survey.save!
    end
  end

  # Shared by both writes above: everything except the save.
  def compute!
    # ONE ledger of what this Verto is already showing, spanning every slot:
    # the backdrop, the left panels and the tap_card statement pictures. It
    # used to be two sets (panels here, statement pictures there) keyed on the
    # URL of the crop asked for — which is why one photograph could turn up as
    # the backdrop, as a card panel and as a statement picture all at once and
    # still look, to the code, like three different pictures. Pexels serves the
    # same photograph at whatever size the slot wants, so the ledger keys on
    # the photograph (see content_key), not on the URL of one crop of it.
    used        = Set.new
    used_themes = Set.new  # range cards' reaction animations
    # A fill-only run tops up a deck that already has imagery on it. What is
    # already there is content this Verto is showing, so it goes in the ledger
    # too — otherwise the top-up's idea of "unused" is everything, and it
    # cheerfully hands a card a second copy of the picture two cards up.
    seed_used_from_existing(used, used_themes) if @fill_only

    @survey.background_image = safe_pick { pick_background_path }

    # Per-card rescue: one card's image pick failing (e.g. a transient Pexels
    # hiccup) must not abort the whole run and discard the background + every
    # other card's art. A failed card just keeps whatever it already had.
    #
    # media_idx counts cards that actually receive left-panel media, so we can
    # mix in video as a periodic accent: every 3rd such card prefers a video,
    # which (per the Rules of the Game variety principle) keeps videos from
    # ever sitting adjacent and caps photo runs at two — reducing fatigue.
    media_idx = 0
    cards = Array(@survey.cards).each_with_index.map do |card, idx|
      new_card = card.dup
      begin
        prefer_video = (media_idx % 3 == 2)
        if (picked = pick_card_image_path(card, idx, used, prefer_video: prefer_video))
          apply_card_media(new_card, picked)
          media_idx += 1
        else
          # Nothing was picked, so the card KEEPS the media it arrived with —
          # a fill-only skip, a creator's own animation, a pick that found
          # nothing. Whatever it keeps is a picture this Verto is showing, so
          # it belongs in the ledger even though this run didn't choose it.
          ledger_existing_media(new_card, used)
        end
        # The other two per-card assets, under the same fill-only rule as the
        # left panel: a creator who picked statement images or an animation
        # theme in the seconds after an import keeps them.
        if card["type"].to_s == "tap_card" && !(@fill_only && Array(card["option_images"]).any?(&:present?))
          new_card["option_images"] = pick_tap_card_option_images(card, idx, used)
          # Fresh statement pictures, so the per-statement repositions chosen
          # for the old ones go with them — same reasoning as apply_card_media.
          new_card.delete("option_focals")
        end
        # The age card plays its own bound set (NpsHelper::AGE_BAND_THEME), so
        # there is nothing to pick for it — and a pick would spend one of the
        # deck's on-theme animations on a card that never plays it.
        if card["type"].to_s == "range" && !NpsHelper.age_band_card?(card) &&
           !(@fill_only && card["range_theme"].present?)
          new_card["range_theme"] = pick_range_theme(idx, used_themes)
        end
      rescue => e
        ErrorReporting.report("AssetPopulator", e, card_index: idx, card_type: card["type"])
      end
      new_card
    end

    @survey.cards = cards
  end

  # Reaction animations for a LOOSE array of cards — a generated flow's, before
  # the client splices them into the deck (see GenerateFlowJob). Returns the
  # cards; the survey is read for its theme and its animations, never written.
  #
  # Without this a flow's range cards arrive carrying no `range_theme` at all,
  # and NpsHelper#range_theme_slug then renders the SAME default animation on
  # every one of them — a basketball on each slider of a flow about recycling,
  # ignoring both the deck's animations and each other's. "No pick" is blank for
  # a photo but not for an animation: a range card always plays something, so a
  # missing pick is not an absent animation, it is the same one over and over.
  #
  # Imagery is deliberately NOT touched here. A generated flow has never carried
  # any, and adding some would be a new behaviour rather than a repeat removed.
  def animate_cards!(cards)
    used_themes = Set.new
    Array(@survey.cards).each do |card|
      used_themes << card["range_theme"] if card.is_a?(Hash) && card["range_theme"].present?
    end

    Array(cards).each_with_index.map do |card, idx|
      next card unless card.is_a?(Hash)
      next card unless card["type"].to_s == "range" && card["range_theme"].blank?
      next card if NpsHelper.age_band_card?(card) # plays its own bound set

      card.merge("range_theme" => pick_range_theme("flow-#{idx}", used_themes))
    end
  end

  # Run a pick that may reach Pexels; on any error log and return nil so the
  # caller falls back to "no image" rather than aborting populate!.
  def safe_pick
    yield
  rescue => e
    ErrorReporting.report("AssetPopulator", e)
    nil
  end

  # Apply a media pick hash onto a card. A card holds EITHER a photo (`image`)
  # OR a video (`video` + `video_poster`) in its left panel — set one and clear
  # the other so a re-populate/shuffle can switch a card between the two. The
  # credit fields are shared (the renderer labels them "Photo by"/"Video by").
  def apply_card_media(card, picked)
    # A populate/shuffle puts a DIFFERENT picture on the card, so the editor's
    # re-crop record (the pre-crop original of the old upload, and the crop
    # taken from it) describes pixels that are no longer there. Left behind,
    # "Crop & zoom" would reopen the previous photo underneath the new one.
    card.delete("image_source")
    card.delete("image_crop")
    # And the same for the reposition: a focal point is a statement about one
    # photograph's subject. Carried onto the next picture it is not a setting,
    # it is a shove — the new photo would arrive already off-centre for no
    # reason the creator could see.
    card.delete("focal_x")
    card.delete("focal_y")
    card.delete("focal_zoom")
    if picked["video"].present?
      card["video"]        = picked["video"]
      card["video_poster"] = picked["video_poster"]
      card.delete("image")
    else
      card["image"] = picked["image"]
      card.delete("video")
      card.delete("video_poster")
    end

    if picked["image_credit"].present?
      card["image_credit"]     = picked["image_credit"]
      card["image_credit_url"] = picked["image_credit_url"]
    else
      card.delete("image_credit")
      card.delete("image_credit_url")
    end
  end

  private

  # ── The content ledger ────────────────────────────────────────────────────
  # What a piece of content IS, independent of the crop a slot asks for.
  #
  # Pexels builds every URL from one photograph's `original`, so the backdrop
  # (1920×1080), a left panel (720×1280) and a statement picture (800×800) of
  # the SAME photograph are three different strings. Keyed on the string, the
  # de-dup could not see that they were one picture, and a Verto could open
  # with its backdrop repeated on card three. The id is the photograph; the
  # URL is only one way of asking for it.
  #
  # Curated assets are keyed on their asset path — they live in per-slot
  # directories, so a path already identifies the file uniquely.
  def content_key(photo)
    id = photo["id"].presence
    return "pexels-photo-#{id}" if id
    # No id is not a shape Pexels returns, but a nil in the ledger would make
    # every other keyless candidate look already-used, so there is always a key.
    PexelsClient.url_for(photo, :card).presence || photo["url"].to_s
  end

  def video_content_key(video)
    id = video["id"].presence
    return "pexels-video-#{id}" if id
    PexelsClient.video_file_url(video).presence || video["url"].to_s
  end

  # The ledger key for media already sitting on a card, which we have as a URL
  # rather than as the API hash it came from. A Pexels URL carries the id in
  # its path, so the same photograph is recognised however it was cropped;
  # anything else (a curated asset path, an uploaded blob) is its own key.
  PEXELS_PHOTO_ID = %r{images\.pexels\.com/photos/(\d+)/}
  PEXELS_VIDEO_ID = %r{videos\.pexels\.com/video-files/(\d+)/}

  def content_key_for_url(url)
    v = url.to_s
    return "pexels-photo-#{Regexp.last_match(1)}" if v.match(PEXELS_PHOTO_ID)
    return "pexels-video-#{Regexp.last_match(1)}" if v.match(PEXELS_VIDEO_ID)
    v.presence
  end

  # Everything a fill-only run is KEEPING, entered into the ledger before it
  # picks anything, so a top-up doesn't duplicate what is already on the deck.
  def seed_used_from_existing(used, used_themes)
    # The backdrop it is keeping is a soft avoid here for the same reason a
    # freshly picked one is (see backdrop_last).
    @backdrop_key ||= content_key_for_url(@survey.background_image) if @survey.background_image.present?
    Array(@survey.cards).each do |card|
      next unless card.is_a?(Hash)
      ledger_existing_media(card, used)
      used_themes << card["range_theme"] if card["range_theme"].present?
    end
  end

  # Enter whatever media a card is already carrying into the ledger.
  def ledger_existing_media(card, used)
    return unless card.is_a?(Hash)
    ([ card["image"], card["video"] ] + Array(card["option_images"])).each do |u|
      next if u.blank?
      key = content_key_for_url(u)
      used << key if key
    end
  end

  def pick_background_path
    # Pexels primary: a themed landscape backdrop. Falls back to the curated
    # backgrounds/ assets when Pexels is unconfigured or returns nothing.
    if (url = pexels_background_url)
      return url
    end

    candidates = Array(self.class.manifest["backgrounds"])
    return nil if candidates.empty?

    query  = survey_query_tags
    # Prefer theme-matching backgrounds. Without this filter the age/mood
    # bonuses on sport.jpg ([teen, young-adult] + [playful, energetic])
    # eclipse a clean theme hit on nature.jpg for a Climate Verto.
    themed = candidates.select { |a| theme_match?(a, query) }
    pool   = themed.presence || candidates
    # A vetoed backdrop is dropped — but "never blank" outranks the veto, so an
    # exclusion that would empty the pool falls back to the unfiltered one.
    pool   = allowed_assets(pool).presence || pool

    scored = pool.map { |a| [ score(a, query), a ] }
    top    = scored.max_by { |s, _| s }
    chosen =
      if top && top[0] > 0
        top[1]
      else
        pool[rand_for("bg").rand(pool.size)]
      end
    helpers.asset_path("#{BACKGROUND_DIR}/#{chosen['file']}")
  end

  # Picker for the card's left-panel image. Returns an asset_path/URL string or
  # nil (blank panel — same as Start-from-Blank).
  #
  # tap_card keeps its left panel blank — statement imagery rides on
  # option_images. For every other card type, Pexels (when configured) is the
  # primary source so coverage isn't limited to the themes the curated library
  # happens to hold; the curated two-tier logic is the fallback.
  #
  # Returns a media hash — a photo { "image", "image_credit", "image_credit_url" }
  # or a video { "video", "video_poster", "image_credit", "image_credit_url" } —
  # or nil. Only Pexels picks carry a credit. `prefer_video` asks for a video
  # first (used to mix media); it falls back to a photo when no video is found.
  def pick_card_image_path(card, idx, used, prefer_video: false)
    type = card["type"].to_s
    # tap_card's imagery rides on its statement cards; range shows the reactive
    # Lottie animation on its left panel — neither takes a left-panel still.
    return nil if type == "tap_card" || type == "range"
    # Nor does a card the creator has given their own animation to. Shuffle used
    # to stamp a stock photo onto it: the card then held BOTH `lottie` and
    # `image`, the illegal state Survey.sanitize_cards_images! exists to forbid
    # — and this writes straight to the column without going through it. The
    # editor still drew the animation (it wins the render), but the card now
    # carried a photo the creator never chose, and clearing the image from the
    # media picker wipes `lottie` along with it. A deliberate animation is not
    # Shuffle's to overwrite.
    return nil if card["lottie"].present?
    # Fill-only: this card already has its picture, so don't even ask Pexels for
    # one. Belt to compute!'s braces — and it is this line whose absence made
    # FinishVertoSetupJob's "only fills in cards that have no image yet" untrue.
    return nil if @fill_only && Survey.card_has_media?(card)

    # Two passes down the same ladder — Pexels, then Tier 1, then Tier 2.
    #
    # The first pass will only spend content this Verto is not already showing.
    # The second is reached only when the first found nothing anywhere, and
    # there a repeat is allowed, because a repeated picture still beats a blank
    # panel.
    #
    # It used to be one pass, with each source repeating as soon as its OWN
    # pool ran dry: an eight-card deck put the same left-panel photograph on
    # cards six, seven and eight while the untouched select-art pool sat next
    # to it. Exhausting every source before repeating ANY of them is the whole
    # difference between "we ran out" and "we didn't look".
    [ false, true ].each do |allow_repeat|
      if PexelsClient.configured?
        if prefer_video && (vid = pexels_card_video(card, idx, used, allow_repeat: allow_repeat))
          return vid
        end
        if (photo = pexels_card_photo(card, idx, used, allow_repeat: allow_repeat))
          used << content_key(photo)
          return {
            "image"            => PexelsClient.url_for(photo, :card),
            "image_credit"     => photo["photographer"].to_s.strip.presence,
            "image_credit_url" => photo["photographer_url"].to_s.strip.presence
          }
        end
      end

      if (path = tier1_themed_path(card, idx, used, type, allow_repeat: allow_repeat))
        used << path
        return { "image" => path }
      end

      if (path = tier2_type_art_path(card, idx, used, type, allow_repeat: allow_repeat))
        used << path
        return { "image" => path }
      end
    end

    nil
  end

  def tier1_themed_path(card, idx, used, type, allow_repeat: true)
    query = survey_query_tags.merge(keywords: card_keywords(card))

    # Require BOTH a card-type fit AND a thematic connection (theme keyword
    # OR card-keyword overlap). Without the theme/keyword gate, sports-people
    # art would happily land on a Climate Verto purely on age/mood scoring.
    # A vetoed asset is dropped outright here: unlike the background, a card
    # panel is allowed to come back blank, and a blank panel is a better answer
    # to "no offices" than an office.
    type_matching = allowed_assets(Array(self.class.manifest["left_panel"])).select do |a|
      types = Array(a["card_types"])
      (types.empty? || types.include?(type)) && theme_match?(a, query)
    end
    return nil if type_matching.empty?

    # Unused assets only on the first pass. A repeat is still better than a
    # blank panel, but it is the LAST answer, not the second one: the caller
    # comes back with allow_repeat once Tier 2 and Pexels have been asked too.
    unused = type_matching.reject { |a| used.include?(asset_url(LEFT_PANEL_DIR, a["file"])) }
    pool   = unused.presence || (allow_repeat ? type_matching : nil)
    return nil if pool.nil?

    scored = pool.map { |a| [ score(a, query), a ] }
                 .select { |s, _| s >= TIER1_MIN_SCORE }
    return nil if scored.empty?

    best   = scored.map(&:first).max
    top    = scored.select { |s, _| s == best }.map(&:last)
    chosen = top[rand_for("t1-#{idx}").rand(top.size)]
    asset_url(LEFT_PANEL_DIR, chosen["file"])
  end

  def tier2_type_art_path(_card, idx, used, type, allow_repeat: true)
    bucket, dir =
      if SELECT_TYPES.include?(type)
        [ self.class.manifest["select_art"], SELECT_ART_DIR ]
      elsif SCALE_TYPES.include?(type)
        [ self.class.manifest["range_art"], RANGE_ART_DIR ]
      end
    # tap_card deliberately omitted: swipe-cards/ assets are for the
    # statement cards themselves (populated via option_images), not the
    # tap_card's left panel.
    return nil if bucket.nil?

    pool = allowed_assets(Array(bucket))
    return nil if pool.empty?

    available = pool.reject { |a| used.include?(asset_url(dir, a["file"])) }
    # Pool exhausted. Repeats only on the caller's second pass, once Pexels and
    # Tier 1 have been asked for something this deck isn't already showing.
    if available.empty?
      return nil unless allow_repeat
      available = pool
    end

    chosen = available[rand_for("t2-#{idx}").rand(available.size)]
    asset_url(dir, chosen["file"])
  end

  # One picture per statement on a tap_card. Every statement gets a picture of
  # its own: Pexels first, topped up from the curated swipe-cards/ pool, and
  # only once BOTH are dry does a statement repeat one of its neighbours'.
  #
  # It used to be either/or — Pexels' picks if there were any, the curated pool
  # otherwise — and whichever source it landed on was cycled to length when it
  # was shorter than the statement list. A five-statement card with three
  # relevant photos therefore showed the first two twice, with a whole curated
  # pool of eleven sitting unasked next to it.
  def pick_tap_card_option_images(card, card_idx, used)
    options = Array(card["options"])
    return [] if options.empty?

    picks  = pexels_swipe_urls(card, card_idx, options.size, used)
    picks += curated_swipe_urls(card_idx, options.size - picks.size, used) if picks.size < options.size
    return [] if picks.empty?

    # Both sources dry with statements still unpictured. The renderer pairs the
    # arrays positionally, so a short array would leave statements blank in the
    # middle of a card that is otherwise illustrated: cycle what we have.
    picks *= ((options.size.to_f / picks.size).ceil) if picks.size < options.size
    picks.first(options.size)
  end

  # Up to `want` curated statement pictures the Verto isn't already showing,
  # newest-unused first. Returns fewer (or none) when the pool is spent.
  def curated_swipe_urls(card_idx, want, used)
    return [] if want <= 0

    pool = allowed_assets(Array(self.class.manifest["swipe_cards"]))
    return [] if pool.empty?

    rng   = rand_for("tap-#{card_idx}")
    fresh = pool.reject { |a| used.include?(asset_url(SWIPE_CARDS_DIR, a["file"])) }
    urls  = fresh.shuffle(random: rng).first(want).map { |a| asset_url(SWIPE_CARDS_DIR, a["file"]) }
    urls.each { |u| used << u }
    urls
  end

  # The reaction-animation theme for a range card. Range cards carry no still
  # image — their left panel plays a Lottie character that reacts to the slider
  # — so this is their equivalent asset pick. Prefers an on-theme animation
  # (a Climate Verto reacts with recycling/flowers, not basketball), seeded so
  # the same seed is stable and Shuffle's new seed re-rolls it, exactly like
  # every image pick. Overwrites any prior pick as Shuffle does for imagery; the
  # creator can still re-choose from the card's Animation picker afterwards.
  #
  # Each range card gets a DIFFERENT animation, in the same "spend everything
  # before repeating anything" order the pictures use: the on-theme pool first,
  # then the neutral General group, and only when both are spent does a second
  # slider replay one. This mattered more than it looks: the on-theme pool is
  # often tiny (four animations for "Climate action", three for "Customer
  # feedback"), and an independent draw per card meant a five-slider Verto
  # typically played only two or three distinct animations — the same character
  # reacting on card after card.
  def pick_range_theme(idx, used_themes)
    # Match on the Verto theme's OWN words — NOT self.class.theme_keywords, whose
    # image-library cluster expansion over-bridges (food → lifestyle → "game")
    # and would land a sport animation on a food Verto. NpsHelper owns the
    # animation vocabulary and the fallback.
    #
    # The direction's words join the theme's (range_themes_for takes a list and
    # scores on the union): the animation is this card's asset, so a Verto
    # steered toward "recycling" should react with recycling. Vetoed animations
    # are dropped unless that would empty the pool — a range card always needs
    # SOME animation to play.
    themed = allowed_range_themes(NpsHelper.range_themes_for([ @survey.theme, direction_words.join(" ") ]))
    # The neutral group is where an on-theme pool that has run dry goes next —
    # never the full list. Reaching into that is what would put a football on a
    # food Verto, which is the one thing this pick has always refused to do.
    neutral = NpsHelper::RANGE_THEME_FALLBACK.reject { |slug| range_theme_vetoed?(slug) }

    # Something genuinely different first, from the theme and then from the
    # neutral group; only once nothing different is left anywhere does a variant
    # of an animation already playing become the answer, and only after THAT a
    # second copy of one. A neutral animation nobody has seen beats the colour
    # twin of the one two cards up, even though the twin is the more on-theme of
    # the two — because to a respondent scrolling past, the twin is not a second
    # animation at all.
    pool   = unplayed(themed,  used_themes, families: true)
    pool   = unplayed(neutral, used_themes, families: true) if pool.empty?
    pool   = unplayed(themed,  used_themes)                 if pool.empty?
    pool   = unplayed(neutral, used_themes)                 if pool.empty?
    pool   = themed                                         if pool.empty?

    chosen = pool[rand_for("range-theme-#{idx}").rand(pool.size)]
    used_themes << chosen
    chosen
  end

  # The animations in `pool` this Verto is not already playing. With
  # `families:`, also none that merely RESTATES one it is playing — a second
  # sheet of the same emoji, the colour twin of the same speech bubbles (see
  # NpsHelper::RANGE_THEME_FAMILIES).
  def unplayed(pool, used_themes, families: false)
    fresh = pool.reject { |slug| used_themes.include?(slug) }
    return fresh unless families && fresh.any?

    played = used_themes.map { |slug| NpsHelper.range_theme_family(slug) }.to_set
    fresh.reject { |slug| played.include?(NpsHelper.range_theme_family(slug)) }
  end

  # The vetoed animations removed. When the veto empties the on-theme pool —
  # "no football" on a football Verto — the answer is the neutral General group
  # rather than the animation the creator just asked us not to play; only if
  # THAT is empty too does the veto give way, because a range card has to play
  # something.
  def allowed_range_themes(pool)
    return pool if veto_tokens.empty?
    allowed = pool.reject { |slug| range_theme_vetoed?(slug) }
    return allowed if allowed.any?
    NpsHelper::RANGE_THEME_FALLBACK.reject { |slug| range_theme_vetoed?(slug) }.presence || pool
  end

  # A range animation is vetoed when the veto names its slug or one of the
  # subject words NpsHelper says it depicts ("no football" drops both
  # `football` and `football_goal`).
  def range_theme_vetoed?(slug)
    return false if veto_tokens.empty?
    words = (slug.split("_") + Array(NpsHelper::RANGE_THEME_KEYWORDS[slug])).map(&:singularize)
    (words & veto_tokens).any?
  end

  # ── Pexels source ───────────────────────────────────────────────────────
  # All four picks above try Pexels first via these helpers; each returns nil
  # (or [] for swipe) so the curated fallback runs when Pexels is unconfigured
  # or a query comes back empty.

  # Memoised per (query, orientation, page): at most one API call per distinct
  # query-page for the whole populate! run. Page 2 is only ever asked for when a
  # caller has spent everything page 1 held (see relevant_rungs), so an ordinary
  # run costs exactly what it always did.
  def pexels_photos(query, context, page: 1)
    return [] unless PexelsClient.configured?
    orientation = PexelsClient::ORIENTATION_FOR[context]
    @pexels_cache[[ query, orientation, page ]] ||= begin
      results = PexelsClient.new.search(query: query, orientation: orientation, per_page: 30, page: page)
      fetched = results.size
      # 1. PG / age-appropriate for this Verto.
      results = results.select { |p| ContentSafety.safe?(p["alt"], safety_age_buckets) }
      safe = results.size
      # 2. Brand-neutral, unless the theme itself invokes the charged subject.
      results = results.select { |p| charged_theme? || ContentSafety.neutral?(p["alt"]) }
      neutral = results.size
      # 3. Not something the direction prompt vetoed.
      results = results.select { |p| direction_allows?(p["alt"]) }
      Rails.logger.info("[AssetPopulator] pexels #{context} q=#{query.inspect} p#{page} -> " \
                        "#{fetched} fetched / #{safe} safe / #{neutral} neutral / " \
                        "#{results.size} allowed")
      results
    end
  end

  # The background's backdrop. Tries the directed query first and, if nothing
  # clears the relevance floor, once more without the direction — a preference
  # must not be able to cost the Verto its backdrop.
  def pexels_background_url
    photos = nil
    background_queries.each do |query|
      photos = relevant(pexels_photos(query, :background), [], query_theme_words(query)) { |p| p["alt"] }
      break if photos.any?
    end
    return nil if photos.blank?
    chosen = direction_first(photos, rand_for("bg")) { |p| p["alt"] }.first
    # Remembered as a SOFT avoid rather than spent from the ledger — see
    # backdrop_last. A card panel showing the very photograph behind it is the
    # most visible repeat there is, but the backdrop must not be able to cost a
    # card its picture: it is demoted behind every equal candidate, not removed.
    @backdrop_key = content_key(chosen)
    PexelsClient.url_for(chosen, :background)
  end

  # The chosen Pexels photo for one card's left panel (so the caller can read
  # both its crop URL and photographer credit). Seeded order keeps same-seed
  # runs identical; the shared `used` ledger stops two cards landing on the same
  # photograph (mirrors the curated de-dup).
  #
  # Walks the WHOLE query ladder for a photograph the Verto isn't already
  # showing, rather than stopping at the first rung that returned anything: a
  # rung whose every result is already on another card has found nothing for
  # THIS card, and the looser rung below it is a better answer than a repeat.
  # nil when no rung holds anything new; the caller then tries the curated
  # tiers, and only comes back with allow_repeat once those are spent too.
  def pexels_card_photo(card, idx, used, allow_repeat: false)
    query    = card_query(card)
    fallback = nil
    relevant_rungs(card, query, ->(q, page) { pexels_photos(q, :card, page: page) }, ->(p) { p["alt"] }).each do |photos|
      ordered   = direction_first(photos, rand_for("px-#{idx}")) { |p| p["alt"] }
      fallback ||= ordered.first
      if (fresh = ordered.find { |p| !used.include?(content_key(p)) })
        return fresh
      end
    end
    allow_repeat ? fallback : nil
  end

  # A portrait video for one card's left panel, returned as a media hash. Picks
  # a small streamable mp4 + its poster, and the videographer credit. nil when
  # no usable video is found (caller falls back to a photo). Walks the ladder
  # for an unused video, exactly as the photo pick does.
  def pexels_card_video(card, idx, used, allow_repeat: false)
    query    = card_query(card)
    fallback = nil
    chosen   = nil
    relevant_rungs(card, query, ->(q, page) { pexels_videos(q, page: page) }, ->(v) { v["url"] }).each do |videos|
      ordered   = direction_first(videos, rand_for("pxv-#{idx}")) { |v| v["url"] }
      playable  = ordered.select { |v| PexelsClient.video_file_url(v).present? }
      fallback ||= playable.first
      if (fresh = playable.find { |v| !used.include?(video_content_key(v)) })
        chosen = fresh
        break
      end
    end
    chosen ||= (allow_repeat ? fallback : nil)
    return nil if chosen.nil?

    url = PexelsClient.video_file_url(chosen)
    return nil if url.blank?

    used << video_content_key(chosen)
    credit = PexelsClient.video_credit(chosen)
    {
      "video"            => url,
      "video_poster"     => PexelsClient.video_poster(chosen),
      "image_credit"     => credit["name"],
      "image_credit_url" => credit["url"]
    }
  end

  # Memoised portrait video search (one API call per distinct query-page per
  # run). A video page is 15, half a photo page, so the ceiling bit sooner here.
  def pexels_videos(query, page: 1)
    return [] unless PexelsClient.configured?
    @pexels_video_cache[[ query, page ]] ||= begin
      results = PexelsClient.new.search_videos(query: query, orientation: "portrait", per_page: 15, page: page)
      # Videos carry no alt text; the page-URL slug is the best signal we have.
      results = results.select { |v| ContentSafety.safe?(v["url"], safety_age_buckets) }
      results = results.select { |v| charged_theme? || ContentSafety.neutral?(v["url"]) }
      results = results.select { |v| direction_allows?(v["url"]) }
      Rails.logger.info("[AssetPopulator] pexels video q=#{query.inspect} p#{page} -> #{results.size} result(s)")
      results
    end
  end

  # Up to `count` landscapes for a tap_card's statements — every one a
  # photograph the Verto isn't already showing anywhere else, and never the
  # same photograph twice within the card. Returns fewer than asked (or none)
  # rather than padding with repeats: the caller tops the shortfall up from the
  # curated pool, which is content this deck hasn't spent either.
  def pexels_swipe_urls(card, card_idx, count, used)
    return [] unless PexelsClient.configured?

    picks = []
    query = card_query(card)
    relevant_rungs(card, query, ->(q, page) { pexels_photos(q, :swipe, page: page) }, ->(p) { p["alt"] }).each do |photos|
      # Direction preference is applied to the PHOTOS, before they become URLs —
      # the alt text is the only evidence of what a picture shows, and it doesn't
      # survive the mapping.
      direction_first(photos, rand_for("pxtap-#{card_idx}")) { |p| p["alt"] }.each do |photo|
        key = content_key(photo)
        next if used.include?(key)
        url = PexelsClient.url_for(photo, :swipe)
        next if url.blank?

        used << key
        picks << url
        break if picks.size >= count
      end
      break if picks.size >= count
    end
    picks
  end

  # Search-query builders reuse the same theme/keyword signals the curated
  # scorer uses, so Pexels picks track the survey the same way.
  def theme_query_terms
    theme_source_text.downcase.scan(/[a-z]+/).reject { |w| STOP_WORDS.include?(w) }
  end

  # What every query is anchored on.
  #
  # Normally the creator's stated `theme`. An IMPORT can have none: import_pdf
  # submits with formnovalidate and, unlike #generate, validates neither theme
  # nor audience. With a blank theme clean_theme_terms is [], card_query falls
  # through to "abstract", and CARD_RELEVANCE_FLOOR then rejects nearly every
  # photo that comes back — a populate run that COMPLETES and still yields
  # almost no imagery, which to the creator is indistinguishable from one that
  # never ran. (test/integration/pdf_import_test.rb already fixtures
  # `"theme" => ""`, so this shape was always the expected one for an import.)
  #
  # So a blank theme falls back to whatever else the Verto says about itself,
  # and failing that to the deck's own vocabulary.
  def theme_source_text
    return @theme_source_text if defined?(@theme_source_text)

    @theme_source_text =
      @survey.theme.presence ||
      stated_text.presence ||
      deck_subject_text
  end

  # Title, key insight and description — minus a title the app minted rather
  # than the creator, which would anchor every query on the word "imported".
  PLACEHOLDER_TITLES = [ "imported verto", "untitled", "untitled verto", "new verto" ].freeze

  def stated_text
    title = @survey.title.to_s.strip
    title = "" if PLACEHOLDER_TITLES.include?(title.downcase)
    [ title, @survey.key_insight, @survey.description ].compact_blank.join(" ")
  end

  # The deck describing itself: the most frequent subject words across its real
  # question cards. Scaffolding and demographic cards are excluded for the same
  # reason card_query excludes them — they are about the Verto, not its topic.
  def deck_subject_text
    words = Array(@survey.cards).flat_map do |card|
      next [] unless card.is_a?(Hash)
      next [] unless CardTypes.question?(card["type"])
      next [] if theme_only_card?(card)

      subject = card["subject"].to_s.strip
      subject.present? ? salient_words(subject) : card_keywords(card).first(3)
    end
    words.tally.sort_by { |word, n| [ -n, word ] }.first(4).map(&:first).join(" ")
  end

  # Does this Verto's theme deliberately invoke the protest/activism topic?
  # When it does, the neutrality suppression and charged-term query stripping
  # switch off for the whole run — the creator's stated topic wins. Memoised.
  #
  # Reads @survey.theme, NOT theme_source_text, and that asymmetry is the point:
  # the unlock exists because the creator SAID this is the topic. A phrase we
  # derived from a title or from the deck's own card copy is not a stated topic,
  # and letting a derivation flip a safety switch would be a regression.
  def charged_theme?
    return @charged_theme if defined?(@charged_theme)
    @charged_theme = ContentSafety.charged_theme?(@survey.theme)
  end

  # Downcased tokens judged to be proper nouns in the ORIGINAL text — run
  # BEFORE downcasing destroys the signal. A capitalised token that is NOT the
  # first word of its sentence is a place/brand/name; ALL-CAPS acronyms count
  # anywhere. Applied to CARD copy only (question/description), never the theme
  # (themes are routinely title-cased, so mid-caps carry no signal there).
  def proper_nouns(text)
    names = Set.new
    text.to_s.split(/[.?!:]+/).each do |sentence|
      sentence.scan(/[A-Za-z][A-Za-z']*/).each_with_index do |tok, i|
        names << tok.downcase if tok.match?(/\A[A-Z]{2,}\z/)
        names << tok.downcase if i.positive? && tok.match?(/\A[A-Z][a-z]/)
      end
    end
    names
  end

  # Terms fit to send to Pexels: no geography, no proper nouns, no charged
  # terms (unless the theme itself invokes them). Query = SUBJECT, not CONTEXT.
  def subject_terms(tokens, names = Set.new)
    tokens.reject do |w|
      GEO_COMPASS.include?(w) || GEO_NOUNS.include?(w) || names.include?(w) ||
        (!charged_theme? && ContentSafety::CHARGED.include?(w))
    end
  end

  # The theme's depictable subject terms — geography and charged words removed.
  # The shared base for every card's query (background and cards alike).
  def clean_theme_terms
    @clean_theme_terms ||= subject_terms(theme_query_terms)
  end

  # Age buckets for the Verto's audience, driving the content-safety blocklist
  # (kids/teen get the stricter list). Memoised for the run.
  def safety_age_buckets
    @safety_age_buckets ||= self.class.age_buckets(@survey.audience_age)
  end

  def background_query(directed: true)
    # Backgrounds KEEP geography — a full-bleed skyline/landscape for the
    # Verto's place is neutral and legitimate (a "London life" Verto's
    # backdrop should be able to be London). Only charged terms are stripped
    # (unless the theme invokes them). The screenshot confirmed the theme-only
    # background was already correct; the bug was card copy, not the backdrop.
    terms = theme_query_terms.reject { |w| !charged_theme? && ContentSafety::CHARGED.include?(w) }
                             .first(3)
    terms = with_direction(terms) if directed
    raw   = terms.join(" ").presence || "abstract background"
    ContentSafety.scrub_query(raw, safety_age_buckets).presence || "abstract background"
  end

  # The backdrop queries to try — same prompt-first ladder as the cards: the
  # direction-led query when the direction names a subject area, then the
  # theme+direction query, then the theme alone. One entry (and identical
  # behaviour to before) when there's no direction.
  def background_queries
    [
      (direction_led_query if direction_affinity.any?),
      background_query,
      (background_query(directed: false) if direction_terms.any?)
    ].compact.uniq
  end

  # Theme-anchored: the BASE of every card query is the Verto theme's subject,
  # so a card's own copy can never drag the search off-topic (the real bug —
  # a welcome card's "your voice matters…" landing on protest stock).
  #
  # Scaffolding cards (welcome/checkpoint) have no subject of their own — they
  # are theme-only, no per-word analysis. Ordinary question cards REFINE the
  # theme base with a concrete subject: CardSubjectExtractor's AI-picked
  # phrase when generation stamped one (card["subject"]), or the keyword
  # heuristic otherwise — an older Verto, or one built before the extractor
  # was configured. Either way the refinement only survives the same hygiene
  # strips (geo, proper nouns, charged) as before: the subject is untrusted
  # model output, no less than any other AI generation step, and
  # ContentSafety.scrub_query runs over the final joined query regardless of
  # which branch produced it. Fail-closed throughout: an unknown word is
  # simply not added, never allowed to steer the query on its own.
  #
  # The direction prompt, when set, is appended LAST (see with_direction) —
  # after the theme base and after the card's own subject — so it colours the
  # search without displacing what the card is about. `directed: false` rebuilds
  # the same query without it, for the relaxation ladder in card_queries.
  def card_query(card, directed: true)
    base = clean_theme_terms.first(2)
    refine =
      if theme_only_card?(card)
        []
      elsif card["subject"].to_s.strip.present?
        subject_terms(salient_words(card["subject"]), proper_nouns(card["subject"]))
      else
        subject_terms(card_keywords(card), proper_nouns("#{card['text']} #{card['description']}"))
      end
    terms = (base + refine).uniq { |w| w.singularize }
    terms = with_direction(terms) if directed
    raw   = terms.join(" ").presence || clean_theme_terms.first(3).join(" ").presence || "abstract"
    ContentSafety.scrub_query(raw, safety_age_buckets).presence || "abstract"
  end

  # The query stripped back to just the theme base, no card refinement at all
  # — used by relevant_rungs below when a subject-refined query
  # comes back with nothing Pexels-relevant. A subject can legitimately be
  # more specific than what this theme+audience's Pexels library covers
  # ("vintage bicycle" vs. plain "commute"), and a theme-anchored photo still
  # beats none.
  def theme_base_query
    raw = clean_theme_terms.first(3).join(" ").presence || "abstract"
    ContentSafety.scrub_query(raw, safety_age_buckets).presence || "abstract"
  end

  # Runs `fetch` (->(query, page) { API results }) over progressively looser
  # queries and yields each rung's relevance-filtered results, skipping the
  # rungs that find nothing. See card_queries for the ladder.
  #
  # LAZY, and that is the point: a caller satisfied by the first rung (the
  # common case) never sends the looser queries, so the ladder still costs one
  # API call per card. A caller that finds the first rung already spent by
  # another card pays for the next rung only then — the API call it takes to
  # find a photograph this Verto isn't showing yet.
  #
  # Every rung is walked at page 1 before any is walked at page 2, because a
  # different query is a better source of variety than more of the same one.
  # Paging at all matters because a page is not the supply: Pexels was only ever
  # asked for the first 30 results per query, the relevance floor routinely cut
  # that to a handful, and a deck whose cards share a query then had a handful
  # of photographs to divide between all of them — which is how "we ran out"
  # became a Verto showing one picture three times.
  #
  # `text_for` is a lambda rather than a block because the caller's own block is
  # the loop body.
  MAX_PEXELS_PAGES = 2

  def relevant_rungs(card, query, fetch, text_for)
    queries = card_queries(card, query)
    base    = theme_base_query
    ladder  = (1..MAX_PEXELS_PAGES).flat_map { |page| queries.map { |q| [ q, page ] } }

    ladder.lazy.filter_map do |q, page|
      # The theme-base rung deliberately drops the card's subject, so judging
      # its results against the card's own words measures them on something the
      # query never asked for — the CARD floor (4) applied to a theme search,
      # which rejected the very photographs this rung exists to find.
      words = (q == base ? [] : card_relevance_words(card))
      relevant(fetch.call(q, page), words, query_theme_words(q), &text_for).presence
    end
  end

  # The queries to try for one card, most direction-led first:
  #
  #   0. the prompt-first query — the direction plus one theme word — whenever
  #      the direction names a subject area. The creator said what they want
  #      the Verto to look like; ask for that before asking for anything else.
  #   1. what the caller built — direction + theme base + card subject;
  #   2. the same without the direction. A preference is the first thing to
  #      give up: it is how the creator wants the subject shown, not what the
  #      card is about.
  #   3. the bare theme base. A card's own subject can be more specific than
  #      what this theme's Pexels library covers ("vintage bicycle" vs. plain
  #      "commute"), and a theme-anchored photo still beats none.
  #
  #      This rung used to be offered only to cards an AI subject had narrowed,
  #      which withheld it from exactly the cards most likely to need it: with
  #      no subject stamped, the query is built from the keyword heuristic and
  #      can run to a dozen words, which Pexels narrows on hard. Those cards had
  #      no relaxation rung at all — one query, and a blank panel if it missed.
  #
  # Rung 0 leading is the whole point and also its own risk, so the rungs below
  # it stay exactly as they were: a direction that finds nothing still falls
  # through to the card's own search rather than leaving the panel blank.
  #
  # De-duped, so a step that would re-send an identical query is skipped rather
  # than spending a second API call to re-filter the same results. And LAZY at
  # the point of use (see relevant_rungs) — a rung nobody needs is never sent.
  def card_queries(card, query)
    ladder = []
    ladder << direction_led_query if direction_affinity.any?
    ladder << query
    ladder << card_query(card, directed: false) if direction_terms.any?
    ladder << theme_base_query
    ladder.uniq
  end

  # Cards imaged from the Verto theme ONLY, ignoring their own copy: scaffolding
  # (welcome/checkpoint) which have no subject, AND the demographic form fields
  # (Gender/birth/location) whose copy names a sensitive subject that must not
  # steer a stock-photo search (the "Gender" card pulling identity/edgy imagery).
  def theme_only_card?(card)
    SCAFFOLDING_TYPES.include?(card["type"].to_s) || card["demographic"].present?
  end

  def asset_url(dir, file)
    helpers.asset_path("#{dir}/#{file}")
  end

  # True when an asset has at least one theme keyword or card keyword in
  # common with the query — i.e. there's a real thematic connection rather
  # than an accidental age/mood/style overlap. Used to gate Tier-1 and the
  # background picker so off-theme assets aren't picked on bonuses alone.
  def theme_match?(asset, query)
    asset_themes   = Array(asset["themes"]).map { |t| t.to_s.downcase }
    asset_keywords = Array(asset["keywords"]).map { |k| k.to_s.downcase }
    (asset_themes & Array(query[:themes]).to_a).any? ||
      (asset_keywords & Array(query[:keywords]).to_a).any?
  end

  # Score one manifest asset against a query hash.
  #   +3 per matching theme keyword
  #   +2 per matching age bucket (or +1 if asset is `all`)
  #   +2 per matching mood
  #   +1 per matching style
  #   +4 per asset keyword found in card text+options
  def score(asset, query)
    s = 0
    asset_themes = Array(asset["themes"]).map { |t| t.to_s.downcase }
    s += 3 * (asset_themes & query[:themes].to_a).size

    asset_ages = Array(asset["age"]).map { |a| a.to_s.downcase }
    if asset_ages.include?("all")
      s += 1
    else
      s += 2 * (asset_ages & query[:age].to_a).size
    end

    asset_moods = Array(asset["mood"]).map { |m| m.to_s.downcase }
    s += 2 * (asset_moods & query[:mood].to_a).size

    asset_styles = Array(asset["style"]).map { |st| st.to_s.downcase }
    s += 1 * (asset_styles & query[:style].to_a).size

    if query[:keywords]
      kws = Array(asset["keywords"]).map { |k| k.to_s.downcase }
      s += 4 * (kws & query[:keywords].to_a).size
    end

    s
  end

  # The curated library's query hash. The direction widens `themes` (so an
  # asset the creator asked for can clear the Tier-1 thematic gate and score
  # like a theme hit) and NARROWS `mood`/`style` to the ones it names — a
  # direction saying "calm, minimal" should stop every playful asset collecting
  # the mood bonus, which is the whole point of saying it.
  def survey_query_tags
    {
      themes: self.class.theme_keywords(theme_source_text) | direction_themes,
      age:    self.class.age_buckets(@survey.audience_age),
      mood:   direction_moods.presence || DEFAULT_MOODS,
      style:  direction_styles
    }
  end

  # ── Direction ─────────────────────────────────────────────────────────────

  def direction_text
    @direction
  end

  # [wanted, vetoed] — parsed once per run.
  def direction_parts
    @direction_parts ||= self.class.direction_buckets(direction_text)
  end

  # The words the creator asked FOR, minus anything the content-safety
  # blocklist forbids for this audience and anything on the brand-neutrality
  # (protest-visual) list. The direction is deliberate creator input, so unlike
  # theme and card copy it keeps geography and proper nouns — "Scandinavian",
  # "coastal", "London rooftops" are exactly the instruction. What it does NOT
  # get is the charged-theme unlock: a charged word here is stripped the same
  # way it is from a theme, because CHARGED contains everyday homographs
  # ("march") and one of them in an imagery note is not the deliberate topic
  # declaration that ContentSafety.charged_theme? is looking for. A creator who
  # genuinely wants protest imagery says so in the Verto's theme, or picks it
  # by hand in the media picker.
  def direction_words
    @direction_words ||= begin
      words = direction_parts[0].reject { |w| !charged_theme? && ContentSafety::CHARGED.include?(w) }
      ContentSafety.scrub_query(words.join(" "), safety_age_buckets).split
    end
  end

  # The words the creator vetoed. Not safety-scrubbed and not charged-stripped:
  # asking for LESS of something is safe whatever the word is.
  def direction_vetoes
    @direction_vetoes ||= direction_parts[1]
  end

  # The slice of the direction that rides along on a Pexels query.
  def direction_terms
    @direction_terms ||= direction_words.first(DIRECTION_QUERY_TERMS)
  end

  def direction_themes
    @direction_themes ||= self.class.expand_themes(direction_words)
  end

  # ── Direction affinity: does the direction name a SUBJECT AREA? ───────────
  # The direction's words expanded through the theme clusters, minus the
  # Verto's own theme words. What's left is the vocabulary that counts as
  # evidence a candidate followed the direction — and only the direction, which
  # is why the theme words go: on a "community sport" Verto, a photo of a
  # community sports day must not read as proof we found something "corporate"
  # just because the work cluster happens to list "community" too.
  #
  # Subtracting the theme's LITERAL words, not its cluster expansion. The
  # expansion is bidirectional and bridges hard on words like "community", so a
  # community-sport theme already pulls the entire work vocabulary in —
  # subtracting that cancelled "professional and corporate" down to nothing and
  # silently disabled every prompt-first path below it. Bridges are why a
  # nature background can win a food Verto; they are far too broad to define
  # "what the theme already asked for".
  #
  # Empty unless the direction names a SUBJECT AREA (see direction_subject?),
  # and that emptiness is load-bearing: everything prompt-first below is gated
  # on it, so a direction that only says how a picture should look leaves the
  # existing behaviour alone, while one that names a subject takes the lead.
  #
  # Alt text almost never repeats the creator's own adjective, so the cluster
  # expansion is also what makes matching work at all: "corporate" is satisfied
  # by an alt that says office, business or colleagues.
  def direction_affinity
    @direction_affinity ||=
      if direction_subject?
        (direction_themes - theme_query_terms).map(&:singularize).uniq
      else
        []
      end
  end

  # Does the direction name a subject area, or only a treatment? The test is
  # whether the theme clusters RECOGNISED any of its words — expand_themes
  # returns what it was given plus whatever the clusters add, so anything left
  # after removing the original words is a cluster saying "I know this topic".
  # "professional and corporate" reaches the work cluster; "warm minimal"
  # reaches nothing, because no cluster claims an adjective.
  #
  # Testing `direction_affinity.any?` directly would NOT work and looked like it
  # would: expand_themes always echoes its input, so every non-empty direction
  # has a non-empty expansion, the gate never closed, and "warm minimal" would
  # have taken the prompt-first rung and flattened every card's own subject.
  def direction_subject?
    return @direction_subject if defined?(@direction_subject)
    @direction_subject = (direction_themes - direction_words).any?
  end

  # True when a candidate's description shows what the direction asked for.
  def direction_preferred?(text)
    return false if direction_affinity.empty?
    (relevance_tokens(text) & direction_affinity).any?
  end

  # Order candidates so the ones answering the direction come first, seeded so
  # a given seed still yields a stable result. THIS is what makes a direction
  # stick across a whole deck: two cards with the same query draw from the same
  # Pexels pool, and picking from it at random meant one card got the office
  # and the next got the rugby match. With no direction — or nothing in the
  # pool that matches one — it is exactly the shuffle it replaces.
  def direction_first(items, rng, &text_for)
    groups =
      if direction_affinity.empty?
        [ items ]
      else
        items.partition { |it| direction_preferred?(text_for.call(it)) }
      end
    groups.flat_map { |group| backdrop_last(group.shuffle(random: rng)) }
  end

  # The backdrop's own photograph sorts to the back of whatever group it lands
  # in. A card panel showing the picture the respondent already has behind them
  # is the most visible repeat in a Verto, so any other candidate of equal
  # standing is the better answer — but it stays ELIGIBLE. Demoting it costs
  # nothing; removing it could cost a card its picture, or (when a direction is
  # running) cost it the direction, which is why it is a preference and not a
  # ledger entry.
  def backdrop_last(items)
    return items if @backdrop_key.nil?
    other, backdrop = items.partition do |it|
      !(it.is_a?(Hash) && it["src"].present? && content_key(it) == @backdrop_key)
    end
    other + backdrop
  end

  def direction_moods
    @direction_moods ||= direction_words.filter_map { |w| DIRECTION_MOODS[w] }.uniq
  end

  def direction_styles
    @direction_styles ||= direction_words.filter_map { |w| DIRECTION_STYLES[w] }.uniq
  end

  # Vetoed words, singularised once, for matching against Pexels alt text and
  # video slugs.
  def veto_tokens
    @veto_tokens ||= direction_vetoes.map(&:singularize)
  end

  # False when a candidate's description names something the creator vetoed.
  def direction_allows?(text)
    return true if veto_tokens.empty?
    (relevance_tokens(text) & veto_tokens).empty?
  end

  # Drop curated assets the direction vetoed. Unlike the Pexels side this can
  # empty a pool, so callers that must not come back blank (the background)
  # fall back to the unfiltered pool themselves.
  def allowed_assets(assets)
    return assets if direction_vetoes.empty?
    assets.reject { |a| self.class.vetoed_asset?(a, direction_vetoes) }
  end

  # Put the direction at the FRONT of a query's terms. It used to trail them,
  # which read well in the code and badly in practice: a prioritise card's copy
  # alone runs to a dozen words, so the instruction arrived as the last two of
  # fifteen and the results came back looking like it was never typed.
  def with_direction(terms)
    (direction_terms + terms).uniq { |w| w.singularize }
  end

  # The prompt-first query: the direction plus just enough theme to keep the
  # Verto recognisable. Tried BEFORE the card's own query whenever the direction
  # names a subject area (see direction_affinity), because "make this verto
  # professional and corporate" is an instruction about the whole deck, not a
  # flavour to sprinkle on each card's separate search. It is one query for the
  # whole run, so it also costs one API call rather than one per card.
  def direction_led_query
    raw = (direction_terms + clean_theme_terms.first(1)).uniq { |w| w.singularize }.join(" ")
    ContentSafety.scrub_query(raw, safety_age_buckets).presence || theme_base_query
  end

  # theme_keywords / age_buckets are class methods now (see top of file);
  # the instance code calls self.class so there's one source of truth.

  # Salient words from a card, question-first: the question text leads (it
  # names the subject), then description and options fill in behind it. Filler
  # (STOP_WORDS + QUESTION_FILLER) and tokens under three letters are dropped,
  # so what survives is what the card is visually about. De-duped, first
  # occurrence wins — which is why the query's first(3) keeps the question's
  # own subject ahead of words that only appear among the options.
  def card_keywords(card)
    question = salient_words(card["text"])
    rest     = salient_words([ card["description"], *Array(card["options"]) ].compact.join(" "))
    (question + rest).uniq
  end

  def salient_words(text)
    self.class.salient_tokens(text.to_s.downcase.scan(/[a-z]+/))
  end

  # ── Pexels relevance floor ────────────────────────────────────────────────
  # An uncurated source needs MORE scrutiny than the curated library, not less:
  # a returned photo is only applied if its alt (or a video's page slug) shares
  # real subject vocabulary with the card and theme. Function words can never
  # score (salient_words drops STOP_WORDS + QUESTION_FILLER), and singularize
  # matches "schools" to "school".
  def relevance_tokens(text)
    (salient_words(text) - SLUG_NOISE.to_a).map(&:singularize).uniq
  end

  # Library-parity weights: +4 per card-subject hit, +3 per theme-term hit,
  # +3 per direction-affinity hit.
  #
  # The direction has to count here or the prompt-first rung is self-defeating:
  # ask Pexels for "professional corporate community", get back a photo of
  # colleagues in an office, and score it against the literal query words it
  # doesn't contain — zero, rejected, fall through to the card's own search and
  # the deck stays exactly as it was. Crediting the affinity is not a loosening
  # either: it is the same "does this picture depict something we asked for?"
  # question, asked about the half of the request the creator typed themselves.
  def relevance_score(text, card_words, theme_words)
    tokens = relevance_tokens(text)
    4 * (tokens & card_words).size +
      3 * (tokens & theme_words).size +
      3 * (tokens & direction_affinity).size
  end

  # The card's own subject words for scoring — empty for theme-only cards
  # (scaffolding + demographic form fields), so they fall to the theme floor
  # rather than scoring a candidate on their own tone/sensitive terms.
  def card_relevance_words(card)
    return [] if theme_only_card?(card)
    relevance_tokens("#{card['text']} #{card['description']} #{Array(card['options']).join(' ')}")
  end

  # Filter Pexels candidates to those clearing the relevance floor. Floor is
  # per-context: a card with subject words must be depicted (4); a background
  # or a scaffolding card is measured on theme terms only (3). Only when BOTH
  # word-sets are empty (nothing to measure) is the floor bypassed — so a bare
  # welcome card on a real theme is still theme-floor protected.
  def relevant(items, card_words, theme_words, &text_for)
    return items if card_words.empty? && theme_words.empty?
    floor = card_words.any? ? CARD_RELEVANCE_FLOOR : THEME_RELEVANCE_FLOOR
    items.select { |it| relevance_score(text_for.call(it), card_words, theme_words) >= floor }
  end

  # Theme-side scoring words = tokens of the query actually SENT (not the raw
  # theme), so a place-only "London life" background — whose query keeps
  # "london" — can be matched by a "London skyline" alt.
  def query_theme_words(query)
    relevance_tokens(query)
  end

  def rand_for(slot)
    Random.new("#{@seed}-#{slot}".hash)
  end

  def helpers
    @helpers ||= ActionController::Base.helpers
  end

  # Top-N background asset_paths for the picker's "Recommended" section.
  def background_recommendations(limit)
    rank_pool(self.class.manifest["backgrounds"], BACKGROUND_DIR, survey_query_tags, limit)
  end

  # Top-N card asset_paths blending theme-matched left-panel art and the
  # card-type-family pool (select/range/swipe), so both Tier-1 themed picks
  # and Tier-2 type-fit picks show up in one ranked list.
  def card_recommendations(card, limit)
    return [] if card.blank?
    type  = card["type"].to_s
    query = survey_query_tags.merge(keywords: card_keywords(card))

    scored = []
    Array(self.class.manifest["left_panel"]).each do |a|
      types = Array(a["card_types"])
      next unless types.empty? || types.include?(type)
      scored << [ score(a, query), asset_url(LEFT_PANEL_DIR, a["file"]) ]
    end

    family_bucket, family_dir = type_family_pool(type)
    Array(family_bucket).each do |a|
      scored << [ score(a, query), asset_url(family_dir, a["file"]) ]
    end

    scored.reject! { |s, _| s <= 0 }
    scored.sort_by! { |s, _| -s }
    scored.first(limit).map(&:last)
  end

  def type_family_pool(type)
    if SELECT_TYPES.include?(type) then [ self.class.manifest["select_art"],  SELECT_ART_DIR ]
    elsif SCALE_TYPES.include?(type) then [ self.class.manifest["range_art"], RANGE_ART_DIR ]
    elsif type == "tap_card"        then [ self.class.manifest["swipe_cards"], SWIPE_CARDS_DIR ]
    else [ nil, nil ]
    end
  end

  def rank_pool(pool, dir, query, limit)
    scored = Array(pool).map { |a| [ score(a, query), asset_url(dir, a["file"]) ] }
    scored.reject! { |s, _| s <= 0 }
    scored.sort_by! { |s, _| -s }
    scored.first(limit).map(&:last)
  end
end
