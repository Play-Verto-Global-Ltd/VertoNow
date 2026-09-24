require "test_helper"

class AssetPopulatorTest < ActiveSupport::TestCase
  def setup
    AssetPopulator.reset_manifest_cache!
    @org = Organisation.create!(name: "O", slug: "ap-#{SecureRandom.hex(3)}")
  end

  def make_survey(theme:, audience_age: "all", cards:)
    @org.surveys.create!(
      title: "T", theme: theme, audience_age: audience_age, key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: cards
    )
  end

  test "populate! sets background_image to a /assets/verto-library path" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?" } ])

    AssetPopulator.new(s).populate!

    assert_match %r{\A/assets/verto-library/backgrounds/.+\.jpg\z}i, s.background_image
    assert Survey.sanitize_background_image(s.background_image),
      "background_image must pass Survey.sanitize_background_image"
  end

  test "populate! gives image-bearing cards an image; tap_card option_images; range stays blank" do
    cards = [
      { "type" => "welcome_card",    "text" => "Welcome" },
      { "type" => "multiple_choice", "text" => "Pick one", "options" => [ "A", "B" ] },
      { "type" => "range",           "text" => "How hard?", "options" => [ "Easy", "Hard" ] },
      { "type" => "rating",          "text" => "Rate it" },
      { "type" => "nps",             "text" => "Recommend?" },
      { "type" => "tap_card",        "text" => "Swipe", "options" => [ "x", "y", "z" ] },
      { "type" => "open_ended",      "text" => "Thoughts?" }
    ]
    s = make_survey(theme: "Sport fans", audience_age: "18-24", cards: cards)

    AssetPopulator.new(s).populate!

    s.reload
    s.cards.each_with_index do |c, i|
      case c["type"]
      when "tap_card"
        assert_equal Array(c["options"]).size, Array(c["option_images"]).size,
          "tap_card #{i} option_images count must match options count"
        c["option_images"].each { |u| assert_includes u, "verto-library/swipe-cards/" }
      when "range"
        # Range shows the reactive Lottie on its left panel — no still image,
        # but it does get a reaction-animation theme (its equivalent asset pick).
        assert_nil c["image"], "range card must not get a left-panel still"
        assert_includes NpsHelper::RANGE_THEMES, c["range_theme"],
          "range card must get a known reaction-animation theme"
      else
        assert c["image"].present?, "card #{i} (#{c['type']}) has no image"
      end
    end
  end

  test "sport theme picks sports-people left-panel art for compatible card types" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?",
                               "options" => [ "Arsenal", "Chelsea" ] } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_includes s.cards[0]["image"], "verto-library/left-panel/sports-people-desktop-",
      "expected Tier-1 themed match, got #{s.cards[0]['image'].inspect}"
  end

  test "non-themed survey: tap_card + range left panels stay blank; select falls through to type-art" do
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [
                      { "type" => "tap_card",        "text" => "Agree?", "options" => %w[a b c] },
                      { "type" => "range",           "text" => "Rate it" },
                      { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] }
                    ])

    AssetPopulator.new(s).populate!

    s.reload
    # tap_card left panel intentionally blank — statement imagery does the work
    assert_nil s.cards[0]["image"], "tap_card left panel must NOT pull from swipe-cards/"
    assert_equal 3, Array(s.cards[0]["option_images"]).size
    s.cards[0]["option_images"].each { |u| assert_includes u, "verto-library/swipe-cards/" }
    # range shows the reactive Lottie, so it carries no still image
    assert_nil s.cards[1]["image"]
    assert_includes s.cards[2]["image"], "verto-library/select-art/"
  end

  test "card with no Tier-1/Tier-2 match gets no image (no SVG fallback)" do
    # open_ended has no type-family bucket, and "Climate action" theme has no
    # themed left-panel art, so the card image must be nil — never an SVG path.
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "Anything to add?" } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_nil s.cards[0]["image"]
  end

  test "food theme expands through cluster to match nature background" do
    s = make_survey(theme: "healthy sustainable food", audience_age: "18-30",
                    cards: [ { "type" => "open_ended", "text" => "Thoughts?" } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_match %r{verto-library/backgrounds/nature(?:-[a-f0-9]+)?\.jpg}i, s.background_image,
      "food theme must pull in nature via the theme_clusters expansion, got #{s.background_image.inspect}"
  end

  test "climate theme picks the nature background, not sport, despite age/mood bonuses" do
    s = make_survey(theme: "Climate", audience_age: "15-20",
                    cards: [ { "type" => "open_ended", "text" => "Thoughts?" } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_match %r{verto-library/backgrounds/nature(?:-[a-f0-9]+)?\.jpg}i, s.background_image,
      "Climate theme must pick nature.jpg over sport.jpg, got #{s.background_image.inspect}"
    refute_match %r{/backgrounds/sport[-.]}i, s.background_image
  end

  test "climate theme skips sports-people Tier-1 art on cards (no thematic connection)" do
    s = make_survey(theme: "Climate", audience_age: "15-20",
                    cards: [ { "type" => "multiple_choice", "text" => "How worried are you?",
                               "options" => %w[Very Somewhat NotAtAll] } ])

    AssetPopulator.new(s).populate!

    s.reload
    img = s.cards[0]["image"].to_s
    refute_includes img, "verto-library/left-panel/sports-people",
      "off-theme sports-people art must not land on a Climate card"
  end

  test "tap_card option_images are unique within a card" do
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [ { "type" => "tap_card", "text" => "Agree?",
                               "options" => %w[a b c d e] } ])

    AssetPopulator.new(s).populate!

    s.reload
    imgs = Array(s.cards[0]["option_images"])
    assert_equal 5, imgs.size
    assert_equal imgs.size, imgs.uniq.size, "option_images must be unique within a card"
  end

  test "same seed produces identical picks" do
    cards = [ { "type" => "tap_card", "text" => "Swipe", "options" => %w[a b c] } ] * 3
    s1 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)

    AssetPopulator.new(s1, seed: "fixed-seed").populate!
    AssetPopulator.new(s2, seed: "fixed-seed").populate!

    assert_equal s1.reload.background_image, s2.reload.background_image
    assert_equal s1.cards.map { |c| c["image"] }, s2.cards.map { |c| c["image"] }
  end

  test "shuffle (different seed) yields a different picture set" do
    cards = (1..6).map { { "type" => "tap_card", "text" => "Swipe", "options" => %w[a b c] } }
    s1 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)

    AssetPopulator.new(s1, seed: "seed-A").populate!
    AssetPopulator.new(s2, seed: "seed-B").populate!

    s1_opts = s1.reload.cards.flat_map { |c| Array(c["option_images"]) }
    s2_opts = s2.reload.cards.flat_map { |c| Array(c["option_images"]) }
    refute_equal s1_opts, s2_opts,
      "two different seeds should usually pick different swipe-card art across 18 statements"
  end

  # ── Range reaction-animation theme (Shuffle re-rolls it, like every asset) ──

  test "populate! gives each range card a theme-matched reaction animation" do
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [ { "type" => "range", "text" => "How worried are you?",
                               "options" => %w[Low Medium High] } ])

    AssetPopulator.new(s).populate!

    pool = NpsHelper.range_themes_for("Climate action")
    assert_includes pool, s.reload.cards[0]["range_theme"],
      "the applied animation must come from the theme-matched pool"
    refute_includes pool, "basketball",
      "an off-theme sport animation must not be eligible for a climate Verto"
  end

  test "populate! never lands a sport animation on a food/sustainability Verto" do
    # Regression: the image-library cluster expansion used to bridge food -> game
    # and shuffle a football onto a food Verto.
    cards = (1..6).map { { "type" => "range", "text" => "How do you feel?", "options" => %w[a b c] } }
    s = make_survey(theme: "Food and Sustainability", audience_age: "Under 35's", cards: cards)

    AssetPopulator.new(s, seed: "shuffle-1").populate!

    s.reload.cards.each do |c|
      refute_includes NpsHelper::RANGE_THEME_GROUPS["Sport"], c["range_theme"],
        "a food/sustainability Verto must never get a sport animation, got #{c['range_theme'].inspect}"
    end
  end

  test "populate! range animation falls back to the General group off-theme" do
    s = make_survey(theme: "Something totally unrelated xyzzy", audience_age: "all",
                    cards: [ { "type" => "range", "text" => "How do you feel?", "options" => %w[Bad Ok Good] } ])

    AssetPopulator.new(s).populate!

    assert_includes NpsHelper::RANGE_THEME_FALLBACK, s.reload.cards[0]["range_theme"]
  end

  test "populate! leaves the age card alone — it plays its own bound set" do
    age = DemographicQuestions.cards.first
    s = make_survey(theme: "Sport fans", audience_age: "all",
                    cards: [ { "type" => "range", "text" => "How much?", "options" => %w[a b c] }, age ])

    AssetPopulator.new(s).populate!

    range, age_card = s.reload.cards
    assert_includes NpsHelper::RANGE_THEMES, range["range_theme"], "an ordinary range card is still picked for"
    assert_nil age_card["range_theme"], "the age card plays NpsHelper::AGE_BAND_THEME, not a pick"

    # The flow path returns cards without saving, so it shows the populator's
    # own restraint rather than the sanitiser's.
    animated = AssetPopulator.new(s).animate_cards!([ age.deep_dup ])
    assert_nil animated.first["range_theme"]
  end

  test "same seed produces the same range animation theme" do
    cards = [ { "type" => "range", "text" => "How hard?", "options" => %w[a b c] } ] * 4
    s1 = make_survey(theme: "Sport fans", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Sport fans", audience_age: "18-24", cards: cards.deep_dup)

    AssetPopulator.new(s1, seed: "fixed-seed").populate!
    AssetPopulator.new(s2, seed: "fixed-seed").populate!

    assert_equal s1.reload.cards.map { |c| c["range_theme"] },
                 s2.reload.cards.map { |c| c["range_theme"] }
  end

  test "shuffle (different seed) re-rolls the range animation" do
    cards = (1..8).map { { "type" => "range", "text" => "How much?", "options" => %w[a b c] } }
    s1 = make_survey(theme: "Sport fans", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Sport fans", audience_age: "18-24", cards: cards.deep_dup)

    AssetPopulator.new(s1, seed: "seed-A").populate!
    AssetPopulator.new(s2, seed: "seed-B").populate!

    themes1 = s1.reload.cards.map { |c| c["range_theme"] }
    themes2 = s2.reload.cards.map { |c| c["range_theme"] }
    # Both stay within the theme's animation pool…
    pool = NpsHelper.range_themes_for("Sport fans")
    (themes1 + themes2).each { |t| assert_includes pool, t }
    # …but two different seeds re-roll the sequence (like the image shuffle test).
    refute_equal themes1, themes2,
      "two different seeds should usually pick a different animation sequence across 8 range cards"
  end

  test "no duplicate left-panel pictures across cards (within Tier 1 pool)" do
    cards = (1..5).map { |i| { "type" => "multiple_choice", "text" => "Q#{i}", "options" => %w[a b] } }
    s = make_survey(theme: "Sport", audience_age: "18-24", cards: cards)

    AssetPopulator.new(s).populate!

    s.reload
    tier1_imgs = s.cards.map { |c| c["image"] }.select { |img| img.include?("/left-panel/") }
    assert_equal tier1_imgs.size, tier1_imgs.uniq.size,
      "Tier-1 picks must be unique: #{tier1_imgs.inspect}"
  end

  # ── Question-aware image query ────────────────────────────────────────────

  test "card query keeps the question's subject and drops survey filler" do
    s = make_survey(theme: "Retail", audience_age: "all",
                    cards: [ { "type" => "multiple_choice",
                               "text" => "Which laptop brand would you prefer?",
                               "options" => %w[Apple Dell] } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    assert_includes q, "laptop"
    assert_includes q, "brand"
    %w[which would you prefer].each { |w| refute_includes q, w, "#{w.inspect} is filler" }
  end

  # Theme-anchoring (post-fix contract): the Verto theme is the BASE of every
  # card query so a card's own copy can't drag the search off-topic; the
  # card's concrete subject is still appended (refinement, not replacement).
  test "card query is anchored to the theme and refined by the question subject" do
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "How was your coffee this morning?" } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    assert_equal "climate", q.first, "the theme anchors (leads) the query"
    assert_includes q, "coffee", "the question's concrete subject is still added"
  end

  test "card query falls back to the theme when the question is all filler" do
    s = make_survey(theme: "Travel", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "Which would you prefer?" } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0])

    assert_includes q, "travel", "an all-filler question should fall back to the theme"
  end

  # ── CardSubjectExtractor's stamp (card["subject"]) ────────────────────────

  test "card query prefers the AI-extracted subject over the keyword heuristic" do
    s = make_survey(theme: "Commuting", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "How was the journey in?",
                               "subject" => "vintage bicycle" } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    assert_includes q, "vintage"
    assert_includes q, "bicycle"
    refute_includes q, "journey", "the subject replaces the keyword heuristic, it doesn't blend with it"
  end

  test "card query falls back to the keyword heuristic when no subject was extracted" do
    s = make_survey(theme: "Commuting", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "How was the journey in?" } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    assert_includes q, "journey", "with no subject stamped, today's keyword heuristic still runs"
  end

  test "an AI-extracted subject still has geography and proper nouns stripped" do
    s = make_survey(theme: "Local schools", audience_age: "11-16",
                    cards: [ { "type" => "multiple_choice", "text" => "Which do you enjoy most?",
                               "subject" => "North London school gates", "options" => %w[Maths Art] } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    %w[london north].each { |w| refute_includes q, w, "#{w.inspect} is geography, not a subject — even from the AI extractor" }
    # Singular or plural: the theme ("Local schools") already contributes
    # "schools", and card_query's own dedup (uniq by singularize) correctly
    # drops the card's singular "school" as the same concept — not a bug.
    assert(q.any? { |w| w.singularize == "school" }, "the subject's own concrete term must survive")
    assert_includes q, "gates"
  end

  test "a demographic card's subject is ignored, same as its own copy" do
    demo_card = GENDER_CARD.merge("subject" => "gender identity")
    s = make_survey(theme: "Secondary School exclusions", audience_age: "11-16", cards: [ demo_card ])

    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split
    refute_includes q, "gender", "a demographic card stays theme-only even when a subject was stamped"
  end

  # ── Pexels source (primary when configured) ──────────────────────────────

  # Shared fixture: the Pexels-primary tests below use the "Mountains" theme,
  # so the alt names that subject — a relevant alt is now required to clear the
  # relevance floor (an uncurated result must actually depict the subject).
  PEXELS_PHOTOS = (1..6).map do |i|
    {
      "id" => i, "photographer" => "Photographer #{i}",
      "photographer_url" => "https://www.pexels.com/@photographer-#{i}",
      "alt" => "Snowy mountain peak and alpine landscape #{i}",
      "src" => {
        "original"  => "https://images.pexels.com/photos/#{i}/p.jpg",
        "landscape" => "https://images.pexels.com/photos/#{i}/p.jpg?w=1200&h=627&fit=crop",
        "portrait"  => "https://images.pexels.com/photos/#{i}/p.jpg?w=800&h=1200&fit=crop",
        "tiny"      => "https://images.pexels.com/photos/#{i}/p.jpg?w=280&h=200&fit=crop"
      }
    }
  end.freeze

  PEXELS_VIDEOS = (1..6).map do |i|
    {
      "id" => 100 + i,
      # The page-URL slug is a video's only relevance signal (no alt text).
      "url" => "https://www.pexels.com/video/mountain-peak-alpine-timelapse-#{100 + i}/",
      "image" => "https://images.pexels.com/videos/#{100 + i}/poster.jpeg",
      "user" => { "name" => "Filmmaker #{i}", "url" => "https://www.pexels.com/@filmmaker-#{i}" },
      "video_files" => [
        { "file_type" => "video/mp4", "width" => 540,  "link" => "https://videos.pexels.com/video-files/#{100 + i}/sd.mp4" },
        { "file_type" => "video/mp4", "width" => 720,  "link" => "https://videos.pexels.com/video-files/#{100 + i}/hd.mp4" },
        { "file_type" => "video/mp4", "width" => 2160, "link" => "https://videos.pexels.com/video-files/#{100 + i}/uhd.mp4" }
      ]
    }
  end.freeze

  def with_pexels(photos = PEXELS_PHOTOS, videos = [])
    fake = Object.new
    fake.define_singleton_method(:search) { |**_kw| photos }
    fake.define_singleton_method(:search_videos) { |**_kw| videos }
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake) { yield }
    end
  end

  test "when Pexels is configured it sources the background and card images" do
    s = make_survey(theme: "Mountains", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite peak?", "options" => %w[Alps Andes] } ])

    with_pexels { AssetPopulator.new(s).populate! }

    s.reload
    assert_match %r{\Ahttps://images\.pexels\.com/.+w=1920&h=1080}, s.background_image
    assert Survey.sanitize_background_image(s.background_image),
      "Pexels background must pass the sanitizer"
    assert_match %r{\Ahttps://images\.pexels\.com/.+w=720&h=1280}, s.cards[0]["image"],
      "card left panel must get a 9:16 portrait crop"
    assert_match %r{\APhotographer \d\z}, s.cards[0]["image_credit"].to_s,
      "card must carry the photographer credit"
    assert_match %r{\Ahttps://www\.pexels\.com/@}, s.cards[0]["image_credit_url"].to_s,
      "card must carry the photographer link"
  end

  test "mixes video into card art as a 1-in-3 accent, never adjacent" do
    cards = (1..6).map { |i| { "type" => "multiple_choice", "text" => "Q#{i}", "options" => %w[a b] } }
    s = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards)

    with_pexels(PEXELS_PHOTOS, PEXELS_VIDEOS) { AssetPopulator.new(s).populate! }

    s.reload
    media = s.cards.map { |c| c["video"].present? ? :video : (c["image"].present? ? :photo : :none) }
    # 6 eligible cards → the 3rd and 6th prefer video: P P V P P V
    assert_equal [ :photo, :photo, :video, :photo, :photo, :video ], media

    vid = s.cards[2]
    assert_match %r{\Ahttps://videos\.pexels\.com/.+\.mp4\z}, vid["video"]
    assert_includes vid["video"], "/hd.mp4", "picks the ~720p file, not the 4K one"
    assert_match %r{\Ahttps://images\.pexels\.com/}, vid["video_poster"]
    assert_nil vid["image"], "a video card carries no still image"
    assert_match %r{\AFilmmaker \d\z}, vid["image_credit"].to_s
    assert_match %r{\Ahttps://www\.pexels\.com/@}, vid["image_credit_url"].to_s

    # No two videos adjacent (the Rules-of-the-Game variety principle).
    s.cards.each_cons(2) do |a, b|
      refute(a["video"].present? && b["video"].present?, "videos must never sit adjacent")
    end
  end

  test "curated fallback picks carry no photographer credit" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[Arsenal Chelsea] } ])

    with_pexels([]) { AssetPopulator.new(s).populate! }

    s.reload
    assert_includes s.cards[0]["image"].to_s, "verto-library/"
    assert_nil s.cards[0]["image_credit"], "curated art has no credit"
  end

  test "Pexels fills card art for themes the curated library doesn't cover" do
    # "Food and Sustainability" has no themed left-panel asset, so without
    # Pexels the welcome + open_ended cards would be blank. With Pexels every
    # non-tap_card gets a portrait, regardless of curated coverage.
    s = make_survey(theme: "Food and Sustainability", audience_age: "under 10's",
                    cards: [
                      { "type" => "welcome_card", "text" => "Hey!" },
                      { "type" => "open_ended",   "text" => "What did you eat today?" }
                    ])
    food = (1..6).map { |i| pexels_photo(i, "Children eat fresh food at a table #{i}") }

    with_pexels(food) { AssetPopulator.new(s).populate! }

    s.reload
    s.cards.each_with_index do |c, i|
      assert_match %r{\Ahttps://images\.pexels\.com/.+w=720&h=1280}, c["image"].to_s,
        "card #{i} (#{c['type']}) should get a Pexels portrait"
    end
  end

  test "tap_card option_images come from Pexels (landscape) and stay unique; left panel blank" do
    s = make_survey(theme: "Mountains", audience_age: "all",
                    cards: [ { "type" => "tap_card", "text" => "Which mountain peak is best?", "options" => %w[a b c d] } ])

    with_pexels { AssetPopulator.new(s).populate! }

    s.reload
    imgs = Array(s.cards[0]["option_images"])
    assert_equal 4, imgs.size
    assert_equal imgs.size, imgs.uniq.size, "option_images must be unique within a card"
    imgs.each { |u| assert_match %r{\Ahttps://images\.pexels\.com/.+w=800&h=800}, u }
    assert_nil s.cards[0]["image"], "tap_card left panel stays blank with Pexels too"
  end

  test "same seed is deterministic with Pexels" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "options" => %w[a b] } ] * 4
    s1 = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards.deep_dup)

    with_pexels { AssetPopulator.new(s1, seed: "fixed").populate! }
    with_pexels { AssetPopulator.new(s2, seed: "fixed").populate! }

    assert_equal s1.reload.background_image, s2.reload.background_image
    assert_equal s1.cards.map { |c| c["image"] }, s2.cards.map { |c| c["image"] }
  end

  test "Pexels images whose description isn't PG are dropped (content safety)" do
    s = make_survey(theme: "Nightlife", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite venue?", "options" => %w[A B] } ])
    unsafe = [ {
      "id" => 99, "photographer" => "P", "photographer_url" => "https://www.pexels.com/@p",
      "alt" => "a topless model posing",
      "src" => {
        "original"  => "https://images.pexels.com/photos/99/p.jpg",
        "portrait"  => "https://images.pexels.com/photos/99/p.jpg?w=800&h=1200&fit=crop",
        "landscape" => "https://images.pexels.com/photos/99/p.jpg?w=1200&h=627&fit=crop",
        "tiny"      => "https://images.pexels.com/photos/99/p.jpg?w=280&h=200&fit=crop"
      }
    } ]

    with_pexels(unsafe) { AssetPopulator.new(s).populate! }

    s.reload
    # The only Pexels result was not PG, so it must never land on the card;
    # the populator falls back to curated art (or blank) instead.
    refute_includes s.cards[0]["image"].to_s, "images.pexels.com",
      "an unsafe Pexels photo must not be used"
  end

  test "falls back to the curated library when Pexels returns nothing" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[Arsenal Chelsea] } ])

    with_pexels([]) { AssetPopulator.new(s).populate! }

    s.reload
    assert_match %r{/assets/verto-library/backgrounds/}, s.background_image
    assert_includes s.cards[0]["image"], "verto-library/"
  end

  # A Pexels stub whose results depend on the exact query string sent — unlike
  # with_pexels above (same fixed list for every query), this is what proves
  # relevant_with_subject_retry's SECOND call actually ran with a different
  # (theme-base) query rather than just re-filtering the same result set.
  def with_pexels_by_query(by_query)
    fake = Object.new
    fake.define_singleton_method(:search) { |**kw| by_query[kw[:query]] || [] }
    fake.define_singleton_method(:search_videos) { |**_kw| [] }
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake) { yield }
    end
  end

  test "an AI subject too specific for Pexels retries once against the theme base" do
    s = make_survey(theme: "Mountains", audience_age: "18-24",
                    cards: [ { "type" => "open_ended", "text" => "Tell us about it",
                               "subject" => "yak herding festival" } ])
    populator     = AssetPopulator.new(s)
    subject_query = populator.send(:card_query, s.cards[0])
    theme_query   = populator.send(:theme_base_query)
    assert_not_equal subject_query, theme_query, "the fixture must actually exercise two different queries"

    # Nothing at all for the (too-specific) subject query; a relevant photo
    # only for the plain theme-base query the retry falls back to.
    relevant_photo = pexels_photo(1, "Snowy mountain peak and alpine landscape")
    with_pexels_by_query(theme_query => [ relevant_photo ]) { AssetPopulator.new(s).populate! }

    s.reload
    assert_includes s.cards[0]["image"].to_s, "/photos/1/",
      "nothing cleared the subject query's relevance floor, so the retry against the theme base must supply the pick"
  end

  test "still falls through to curated art when both the subject and theme-base queries come back empty" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?",
                               "subject" => "team mascot costume", "options" => %w[Arsenal Chelsea] } ])

    with_pexels([]) { AssetPopulator.new(s).populate! }

    s.reload
    assert_includes s.cards[0]["image"], "verto-library/",
      "both the subject query and its theme-base retry came back empty — curated fallback must still run"
  end

  # ── Relevance + neutrality (theme-anchored queries, floor, suppression) ────

  # A Pexels photo hash with a chosen alt (the only relevance signal Pexels
  # gives us) and the full src Survey.sanitize_* expects.
  def pexels_photo(id, alt)
    {
      "id" => id, "photographer" => "P#{id}",
      "photographer_url" => "https://www.pexels.com/@p#{id}",
      "alt" => alt,
      "src" => {
        "original"  => "https://images.pexels.com/photos/#{id}/p.jpg",
        "landscape" => "https://images.pexels.com/photos/#{id}/p.jpg?w=1200&h=627&fit=crop",
        "portrait"  => "https://images.pexels.com/photos/#{id}/p.jpg?w=800&h=1200&fit=crop",
        "tiny"      => "https://images.pexels.com/photos/#{id}/p.jpg?w=280&h=200&fit=crop"
      }
    }
  end

  # The real bug: a welcome card's motivational copy dragged the query into
  # activism stock. Uses the REAL alt strings of the applied series (Polina
  # Tankilevitch, verified on Pexels) so the test reflects production, not a
  # convenient invention.
  PROTEST_ALT_WORD  = "Woman Protesting Through a Megaphone"                       # 'protesting' → suppression fires
  PROTEST_ALT_FLOOR = "A Megaphone, a Chain and Two Cards with Anti-Racism Slogans" # only held-out/excluded words → floor does the work

  test "a welcome card no longer drags the query into activism stock" do
    s = make_survey(theme: "Secondary School exclusions", audience_age: "11-16",
                    cards: [ {
                      "type" => "welcome_card",
                      "text" => "Your voice matters — let's talk about your school experience"
                    } ])

    # (a) the welcome-card query is theme-derived, carrying none of the card's
    #     tone words.
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split
    %w[voice matters talk experience].each do |w|
      refute_includes q, w, "#{w.inspect} is card tone, not a depictable subject"
    end
    assert(q.any? { |t| %w[school schools exclusion exclusions secondary].include?(t) },
      "the query must be anchored to the Verto theme")

    # (b) + (c): with both real protest alts and a clean classroom in the pool,
    #     the protest photos are never applied; the card gets the classroom.
    photos = [
      pexels_photo(1, PROTEST_ALT_WORD),
      pexels_photo(2, PROTEST_ALT_FLOOR),
      pexels_photo(3, "Children in a school classroom")
    ]
    with_pexels(photos) { AssetPopulator.new(s).populate! }

    img = s.reload.cards[0]["image"].to_s
    refute_includes img, "/photos/1/", "the 'protesting' photo must never be applied"
    refute_includes img, "/photos/2/", "the anti-racism-slogan photo must never be applied"
    assert(img.include?("/photos/3/") || img.include?("verto-library/"),
      "the card must get the classroom photo or a clean curated fallback, got #{img.inspect}")
  end

  test "card refinement still appends a concrete subject the theme lacks" do
    s = make_survey(theme: "Coffee culture", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "How often do you visit the gym?" } ])

    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    assert_equal "coffee", q.first, "the theme anchors (leads) the query"
    assert_includes q, "gym", "a concrete card subject the theme lacks is still added"
  end

  test "a bare scaffolding card is protected by the theme floor, not the bypass" do
    s = make_survey(theme: "Secondary School exclusions", audience_age: "11-16",
                    cards: [ { "type" => "welcome_card", "text" => "Your voice matters — be honest" } ])

    # Only off-theme candidates → nothing clears the theme floor → curated fallback.
    off_theme = [ pexels_photo(7, "A plate of pasta on a wooden table"),
                  pexels_photo(8, "A sports car on a race track") ]
    with_pexels(off_theme) { AssetPopulator.new(s).populate! }

    img = s.reload.cards[0]["image"].to_s
    refute_includes img, "images.pexels.com",
      "off-theme Pexels results must not reach a bare welcome card"
  end

  test "suppression drops protest imagery for a neutral theme" do
    s = make_survey(theme: "Hospitals in Manchester", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "How easy is it to book an appointment?", "options" => %w[Easy Hard] } ])
    photos = [ pexels_photo(1, "Nurses rally outside a hospital"),
               pexels_photo(2, "A doctor talks to a patient in a hospital") ]

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    img = s.reload.cards[0]["image"].to_s
    refute_includes img, "/photos/1/", "the rally photo must be suppressed"
  end

  test "suppression is lifted when the theme itself invokes activism" do
    s = make_survey(theme: "Activism and social justice", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "How often do you attend a protest?", "options" => %w[Often Never] } ])
    photos = [ pexels_photo(1, "A crowd at a protest march") ]

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    assert_includes s.reload.cards[0]["image"].to_s, "/photos/1/",
      "an activism Verto is allowed its protest imagery"
  end

  test "a place-only theme still finds a neutral backdrop for its background" do
    s = make_survey(theme: "London life", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite way to spend a weekend?", "options" => %w[Parks Museums] } ])
    photos = [ pexels_photo(1, "London skyline at dusk over the Thames") ]

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    assert_includes s.reload.background_image.to_s, "/photos/1/",
      "a London skyline is a legitimate neutral backdrop for a London Verto"
  end

  test "card query strips geography and proper nouns from the card's own copy" do
    s = make_survey(theme: "Local schools", audience_age: "11-16",
                    cards: [ { "type" => "multiple_choice", "text" => "Which subjects do you enjoy most at school in north London?", "options" => %w[Maths Art] } ])

    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    %w[london north].each { |w| refute_includes q, w, "#{w.inspect} is geography, not a subject" }
    assert_includes q, "subjects"
  end

  # A demographic form field (Gender/birth/location) is boilerplate appended to
  # every Verto; its own copy names a sensitive subject that must not steer the
  # image search (the "Gender" card pulling identity/edgy stock for an 11-16
  # audience). Like scaffolding, it is theme-only.
  GENDER_CARD = {
    "type" => "multiple_choice", "text" => "What gender best describes you?", "demographic" => true,
    "options" => [ "Male", "Female", "Non-binary", "Other", "Prefer not to say" ]
  }.freeze

  test "a demographic card's query ignores its own copy and anchors to the theme" do
    s = make_survey(theme: "Secondary School exclusions", audience_age: "11-16",
                    cards: [ GENDER_CARD.dup ])

    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    %w[gender male female non binary].each do |w|
      refute_includes q, w, "#{w.inspect} is a sensitive demographic term, not a depictable subject"
    end
    assert(q.any? { |t| %w[school schools exclusion exclusions secondary].include?(t) },
      "a demographic card's image query must be anchored to the Verto theme")
  end

  test "a demographic card never takes an edgy identity photo for a young audience" do
    s = make_survey(theme: "Secondary School exclusions", audience_age: "11-16",
                    cards: [ GENDER_CARD.dup ])
    # The edgy alt DELIBERATELY overlaps the card's identity terms — that
    # overlap is exactly why the old code scored and applied it.
    photos = [
      pexels_photo(1, "Non-binary androgynous person in fishnet and harness fashion portrait"),
      pexels_photo(2, "Children in a school classroom")
    ]

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    img = s.reload.cards[0]["image"].to_s
    refute_includes img, "/photos/1/", "the edgy identity photo must never be applied to a demographic card"
    assert(img.include?("/photos/2/") || img.include?("verto-library/"),
      "the demographic card gets a theme photo or a clean curated fallback, got #{img.inspect}")
  end

  # ── Shuffle direction prompt (one shuffle, not stored) ───────────────────
  # The creator's optional steer for what they want out of the content and
  # imagery. A PREFERENCE: it colours every pick without displacing the theme,
  # the card's subject, safety or relevance.

  def steer(survey, direction)
    AssetPopulator.new(survey, direction: direction)
  end

  MOUNTAIN_CARD = { "type" => "multiple_choice", "text" => "Favourite peak?" }.freeze

  test "direction_buckets separates what the creator wants from what they vetoed" do
    assert_equal [ %w[warm light outdoors], %w[offices] ],
      AssetPopulator.direction_buckets("warm light, outdoors, no offices")

    # Within one clause the cue flips only what follows it, so the wanted half
    # of a mixed clause survives and the vetoed half never reaches a query.
    assert_equal [ %w[warm], %w[offices suits] ],
      AssetPopulator.direction_buckets("warm and no offices and suits")

    assert_equal [ [], [] ], AssetPopulator.direction_buckets(nil)
    assert_equal [ [], [] ], AssetPopulator.direction_buckets("   ")
  end

  test "instruction scaffolding never crowds out the instruction" do
    # The shipped bug, verbatim: this reduced to ["make", "verto"] — a generic
    # verb and our own product name — and searched Pexels for THAT while the
    # two words carrying the whole instruction went unused. The pictures came
    # back re-rolled but identical in character, which reads as the feature
    # simply not working.
    wanted, vetoed = AssetPopulator.direction_buckets(
      "We want to make this verto professional and corporate")
    assert_equal %w[professional corporate], wanted
    assert_empty vetoed

    s = make_survey(theme: "Community and belonging", audience_age: "all", cards: [])
    pop = steer(s, "We want to make this verto professional and corporate")
    assert_equal %w[professional corporate], pop.send(:direction_terms),
      "the words that reach Pexels must be the ones the creator actually wrote"
    assert_equal [ "serious" ], pop.send(:direction_moods)
    assert_includes pop.send(:background_query).split, "corporate"
  end

  test "a wordy instruction keeps its subject words, in the order written" do
    wanted, = AssetPopulator.direction_buckets(
      "Please can you make the images feel much more professional for our board")
    assert_equal %w[professional board], wanted,
      "please/can/make/images/feel/much/more are all scaffolding"

    # Filler removal must not reorder: a direction that leads with its subject
    # still leads with its subject.
    wanted, = AssetPopulator.direction_buckets("for a bank client - serious, city, glass buildings")
    assert_equal %w[bank client serious city glass buildings], wanted
  end

  test "less and fewer read as vetoes, and an em dash separates clauses" do
    assert_equal [ %w[warm], %w[corporate] ],
      AssetPopulator.direction_buckets("warm and less corporate")
    assert_equal [ %w[bank client serious city], %w[glass] ],
      AssetPopulator.direction_buckets("for a bank client \u2014 serious, city \u2014 no glass")
  end

  test "direction_reading reports what was actually taken from the prompt" do
    s = make_survey(theme: "Mountains", audience_age: "all", cards: [])

    reading = AssetPopulator.direction_reading(s, "warm natural light, outdoors, no offices")
    assert_equal %w[warm natural light], reading[:toward], "exactly what goes to the search"
    assert_equal %w[offices],            reading[:avoiding]

    blank = AssetPopulator.direction_reading(s, nil)
    assert_empty blank[:toward]
    assert_empty blank[:avoiding]
  end

  test "the direction leads the query, ahead of the theme and the card subject" do
    s   = make_survey(theme: "Mountains", audience_age: "all", cards: [ MOUNTAIN_CARD.dup ])
    pop = steer(s, "golden hour")

    card_q = pop.send(:card_query, s.cards[0]).split
    assert_equal "golden", card_q.first,
      "trailing the query meant a wordy card drowned the instruction in its own copy"
    assert_includes card_q, "mountains", "the theme is still in it"
    assert_includes card_q, "peak",      "so is the card's own subject"
    assert_equal "golden", pop.send(:background_query).split.first
  end

  test "no direction means no change: directed and undirected queries are identical" do
    s   = make_survey(theme: "Mountains", audience_age: "all", cards: [ MOUNTAIN_CARD.dup ])
    pop = AssetPopulator.new(s)

    assert_equal pop.send(:card_query, s.cards[0], directed: false),
                 pop.send(:card_query, s.cards[0])
    assert_equal [ pop.send(:background_query) ], pop.send(:background_queries),
      "with nothing to drop there is only one query, so only one API call"
    # The card's own query leads and the theme relaxes it — no direction-led
    # rung, which is what "as if the feature isn't there" means. The relaxation
    # rung costs nothing unless it is needed; the test below is what holds that.
    assert_equal [ pop.send(:card_query, s.cards[0]), pop.send(:theme_base_query) ],
                 pop.send(:card_queries, s.cards[0], pop.send(:card_query, s.cards[0]))
  end

  test "a card that finds its picture first time still costs one API call" do
    # Every card carries a relaxation rung and a second page below its own
    # query now. They are walked lazily, so a run that finds what it needs on
    # the first rung must never pay for them — this is what keeps the rate
    # limit where it was.
    cards = (1..3).map { |i| { "type" => "multiple_choice", "text" => "Peak #{i}?", "options" => %w[a b] } }
    s = make_survey(theme: "Mountains", audience_age: "all", cards: cards)
    photos = (1..12).map { |i| pexels_photo(i, "Snowy mountain peak and alpine landscape #{i}") }

    queries = []
    fake = Object.new
    fake.define_singleton_method(:search) { |**kw| queries << [ kw[:query], kw[:page] || 1 ]; photos }
    fake.define_singleton_method(:search_videos) { |**_kw| [] }
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake) { AssetPopulator.new(s).populate! }
    end

    assert_equal 3, s.reload.cards.count { |c| c["image"].present? }
    assert_empty queries.select { |_q, page| page > 1 }, "page 2 is only for a pool that ran out"
    assert_equal queries.uniq, queries, "each distinct query-page is asked for once and memoised"
    assert_operator queries.size, :<=, 2,
      "one backdrop query and one card query for the whole deck: #{queries.inspect}"
  end

  test "a deck that outgrows a page asks for the next one before repeating" do
    # Eight cards sharing one query against a five-photo page. Pexels was only
    # ever asked for page 1, so the ninth photograph did not exist as far as the
    # populator was concerned and cards started showing each other's.
    cards = (1..8).map { |i| { "type" => "multiple_choice", "text" => "Peak #{i}?", "options" => %w[a b] } }
    s = make_survey(theme: "Mountains", audience_age: "all", cards: cards)
    pages = {
      1 => (1..5).map  { |i| pexels_photo(i, "Snowy mountain peak and alpine landscape #{i}") },
      2 => (6..15).map { |i| pexels_photo(i, "Snowy mountain peak and alpine landscape #{i}") }
    }

    fake = Object.new
    fake.define_singleton_method(:search) { |**kw| pages[kw[:page] || 1] || [] }
    fake.define_singleton_method(:search_videos) { |**_kw| [] }
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake) { AssetPopulator.new(s).populate! }
    end

    imgs = s.reload.cards.map { |c| c["image"] }.compact
    assert_equal 8, imgs.size
    assert_equal imgs.size, imgs.uniq.size, "a second page is a better answer than a second copy"
    assert imgs.any? { |u| u[%r{/photos/(\d+)/}, 1].to_i > 5 }, "page 2 was actually reached"
  end

  test "a negated clause is vetoed, never searched for" do
    s = make_survey(theme: "Team morale", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "How is the week going?" } ])
    q = steer(s, "warm light, no offices").send(:card_query, s.cards[0]).split

    assert_includes q, "warm", "the wanted half of the direction is in the query"
    refute_includes q, "offices", "searching for the vetoed word would invert the instruction"
    refute_includes q, "office"
  end

  test "a vetoed subject is filtered out of the Pexels results" do
    s = make_survey(theme: "Mountains", audience_age: "all", cards: [ MOUNTAIN_CARD.dup ])

    photos = [ pexels_photo(1, "Snow on a mountain peak in winter"),
               pexels_photo(2, "Green mountain peak in summer") ]
    with_pexels(photos) { AssetPopulator.new(s, direction: "no snow").populate! }

    img = s.reload.cards[0]["image"].to_s
    refute_includes img, "/photos/1/", "the vetoed photo must never be applied"
    assert_includes img, "/photos/2/", "the one that isn't vetoed still is"
  end

  test "the direction narrows the curated library's mood and style" do
    s = make_survey(theme: "Mountains", audience_age: "all", cards: [])

    tags = steer(s, "calm, minimal").send(:survey_query_tags)
    assert_equal [ "calm" ],    tags[:mood],  "a stated mood replaces the default spread"
    assert_equal [ "minimal" ], tags[:style], "a stated style is scored where nothing was before"

    plain = AssetPopulator.new(make_survey(theme: "Mountains", audience_age: "all", cards: []))
                          .send(:survey_query_tags)
    assert_equal AssetPopulator::DEFAULT_MOODS, plain[:mood]
    assert_empty plain[:style]
  end

  test "the direction widens the themes the curated library is scored against" do
    s    = make_survey(theme: "Coffee culture", audience_age: "all", cards: [])
    tags = steer(s, "mountains and hiking").send(:survey_query_tags)

    assert_includes tags[:themes], "hiking", "the direction's own words count as themes"
    assert_includes tags[:themes], "travel", "and expand through the same clusters a theme does"
    assert_includes tags[:themes], "coffee", "without displacing the Verto's own theme"
  end

  test "a veto keeps a matching curated asset out of the pick" do
    cards = [ { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[Arsenal Chelsea] } ]

    plain = make_survey(theme: "Football fans", audience_age: "18-24", cards: cards.map(&:dup))
    AssetPopulator.new(plain, seed: "veto").populate!
    plain.reload
    assert_includes plain.background_image, "backgrounds/sport-"
    assert_includes plain.cards[0]["image"], "left-panel/"

    vetoed = make_survey(theme: "Football fans", audience_age: "18-24", cards: cards.map(&:dup))
    direction = "no sport"
    AssetPopulator.new(vetoed, seed: "veto", direction: direction).populate!
    vetoed.reload
    refute_includes vetoed.background_image, "backgrounds/sport-",
      "the sport backdrop carries the vetoed tag"
    assert vetoed.background_image.present?,
      "but the backdrop is still filled — never-blank outranks a preference"
    refute_includes vetoed.cards[0]["image"], "left-panel/",
      "the sports-people panel art carries it too, so the card falls to type art"
  end

  test "the direction steers a range card's reaction animation" do
    cards = [ { "type" => "range", "text" => "How was it?", "options" => %w[Low High] } ]

    plain = make_survey(theme: "Weekly check-in", audience_age: "all", cards: cards.map(&:dup))
    AssetPopulator.new(plain, seed: "anim").populate!
    assert_includes NpsHelper::RANGE_THEME_FALLBACK, plain.reload.cards[0]["range_theme"],
      "an off-theme Verto still lands in the neutral General group"

    steered = make_survey(theme: "Weekly check-in", audience_age: "all", cards: cards.map(&:dup))
    direction = "recycling"
    AssetPopulator.new(steered, seed: "anim", direction: direction).populate!

    picked = steered.reload.cards[0]["range_theme"]
    refute_includes NpsHelper::RANGE_THEME_FALLBACK, picked, "the direction moved it off the fallback"
    assert_includes NpsHelper.range_themes_for("recycling"), picked
  end

  test "a vetoed animation is not played even when the theme asks for it" do
    s = make_survey(theme: "Football fans", audience_age: "all",
                    cards: [ { "type" => "range", "text" => "How was the match?", "options" => %w[Low High] } ])
    direction = "no football"

    AssetPopulator.new(s, seed: "anim", direction: direction).populate!

    picked = s.reload.cards[0]["range_theme"]
    refute_includes %w[football football_goal], picked
    assert_includes NpsHelper::RANGE_THEMES, picked, "a range card always plays SOMETHING"
  end

  test "a directed query that finds nothing relaxes back to the undirected one" do
    s = make_survey(theme: "Mountains", audience_age: "all", cards: [ MOUNTAIN_CARD.dup ])
    direction = "brutalist concrete"

    pop        = AssetPopulator.new(s, direction: direction)
    directed   = pop.send(:card_query, s.cards[0])
    undirected = pop.send(:card_query, s.cards[0], directed: false)
    assert_not_equal directed, undirected, "the fixture must exercise two different queries"

    # Nothing for the directed query; a relevant photo only for the query with
    # the direction dropped.
    photo = pexels_photo(1, "Snowy mountain peak and alpine landscape")
    with_pexels_by_query(undirected => [ photo ]) do
      AssetPopulator.new(s, direction: direction).populate!
    end

    assert_includes s.reload.cards[0]["image"].to_s, "/photos/1/",
      "a preference that finds nothing must not cost the card its picture"
  end

  test "the direction is content-safety scrubbed for the audience" do
    s = make_survey(theme: "Student life", audience_age: "13-16",
                    cards: [ { "type" => "multiple_choice", "text" => "Best night out?" } ])
    q = steer(s, "beer garden, sunshine").send(:background_query).split

    refute_includes q, "beer", "a term blocked for this audience never reaches the search"
    assert_includes q, "garden", "the rest of the direction still applies"
  end

  test "a populator built without a direction behaves as if the feature isn't there" do
    cards = [ MOUNTAIN_CARD.dup ]
    s = make_survey(theme: "Mountains", audience_age: "all", cards: cards)
    pop = AssetPopulator.new(s)

    # Everything the direction drives is inert, so nothing that populates
    # outside Shuffle — the picker's Recommended rail, the player's mobile
    # backdrop — can pick up a steer it was never given.
    assert_empty pop.send(:direction_terms)
    assert_empty pop.send(:direction_vetoes)
    assert_empty pop.send(:direction_affinity)
    assert_equal AssetPopulator::DEFAULT_MOODS, pop.send(:survey_query_tags)[:mood]
    assert_equal pop.send(:card_query, cards[0], directed: false),
                 pop.send(:card_query, cards[0])
  end

  # ── Prompt-first: a direction that names a subject leads the whole deck ───
  # The reported failure: on a community-sport Verto steered "professional and
  # corporate", ONE card came back corporate and the rest stayed rugby. Two
  # cards with identical queries drew the same Pexels pool, and picking from it
  # at random decided which of them honoured the instruction.

  CORPORATE_ALTS = [
    "Colleagues in a modern office having a meeting",
    "Business people in a glass workplace lobby",
    "A manager presenting to employees in a corporate boardroom",
    "Professional woman working at a desk in an office"
  ].freeze

  SPORT_ALTS = [
    "Rugby players in a scrum on a wet pitch",
    "A football team celebrating a goal",
    "Young athletes training on a running track",
    "Community sports club members after a match"
  ].freeze

  # A pool that is half on-direction and half on-theme, which is what a real
  # search for a directed query comes back with.
  def mixed_pool
    (CORPORATE_ALTS + SPORT_ALTS).each_with_index.map { |alt, i| pexels_photo(i + 1, alt) }
  end

  def corporate?(url)
    (1..CORPORATE_ALTS.size).any? { |i| url.to_s.include?("/photos/#{i}/") }
  end

  test "only a direction that names a subject area takes the lead" do
    s = make_survey(theme: "Community sport", audience_age: "all", cards: [])

    assert steer(s, "professional and corporate").send(:direction_subject?),
      "the work cluster recognises these, so they name a subject"
    assert steer(s, "recycling").send(:direction_subject?)

    refute steer(s, "warm minimal").send(:direction_subject?),
      "no cluster claims an adjective — this is a treatment, not a subject"
    assert_empty steer(s, "warm minimal").send(:direction_affinity),
      "and an empty affinity is what leaves the existing behaviour alone"
  end

  test "a subject direction is followed by every card, not just a lucky one" do
    cards = (1..4).map { { "type" => "open_ended", "text" => "Tell us more" } }
    s = make_survey(theme: "Community sport", audience_age: "all", cards: cards)
    direction = "We want to make this verto professional and corporate"

    with_pexels(mixed_pool) { AssetPopulator.new(s, seed: "led", direction: direction).populate! }

    s.reload
    s.cards.each_with_index do |c, i|
      assert corporate?(c["image"]), "card #{i} ignored the direction: #{c['image'].inspect}"
    end
    assert corporate?(s.background_image), "the backdrop follows the direction too"
  end

  test "a treatment-only direction leaves the deck's own subject alone" do
    cards = (1..4).map { { "type" => "open_ended", "text" => "Tell us more" } }
    s = make_survey(theme: "Community sport", audience_age: "all", cards: cards)
    direction = "warm minimal"

    with_pexels(mixed_pool) { AssetPopulator.new(s, seed: "led", direction: direction).populate! }

    s.reload.cards.each_with_index do |c, i|
      refute corporate?(c["image"]),
        "card #{i} took an office photo for a direction that never named one"
    end
  end

  test "the prompt-first query leads the ladder only for a subject direction" do
    s = make_survey(theme: "Community sport", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "Tell us more" } ])

    pop = steer(s, "professional and corporate")
    assert_equal "professional corporate community",
                 pop.send(:card_queries, s.cards[0], pop.send(:card_query, s.cards[0])).first,
      "ask for what the creator asked for before asking for anything else"

    treat = steer(s, "warm minimal")
    ladder = treat.send(:card_queries, s.cards[0], treat.send(:card_query, s.cards[0]))
    refute_equal treat.send(:direction_led_query), ladder.first,
      "a treatment must not replace the card's own search"
  end

  test "an on-direction photo clears the relevance floor on its affinity alone" do
    s = make_survey(theme: "Community sport", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "Tell us more" } ])
    pop = steer(s, "professional and corporate")

    # The alt names neither the query's literal words nor the card's subject —
    # only what the direction is ABOUT. Without affinity credit it scores zero,
    # the prompt-first rung returns nothing and the deck never changes.
    score = pop.send(:relevance_score, "Colleagues in a modern office", [], [])
    assert_operator score, :>=, AssetPopulator::CARD_RELEVANCE_FLOOR
  end

  test "a charged word in the direction is stripped, as it is from a theme" do
    s = make_survey(theme: "Student life", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "Best night out?" } ])
    q = steer(s, "protest crowds, banners").send(:background_query).split

    refute_includes q, "protest",
      "the imagery box is not the place a Verto declares a charged topic — its theme is"
  end
  # ── fill_only, and the two writes ─────────────────────────────────────────
  # The product has two callers and they want opposite things. Shuffle is the
  # creator saying "give me DIFFERENT pictures" — overwriting is the feature.
  # Auto-population is the platform saying "you have none yet", and it runs
  # while an import's creator is already in the editor, possibly picking their
  # own. FinishVertoSetupJob's comment claimed since it was written that
  # population "only fills in cards that have no image yet"; until fill_only
  # existed that was simply untrue.

  test "fill_only leaves imagery the creator already has, of every kind" do
    cards = [
      { "type" => "multiple_choice", "cid" => "c_1", "text" => "Mine",  "options" => %w[A B],
        "image" => "/assets/verto-library/mine.jpg" },
      { "type" => "multiple_choice", "cid" => "c_2", "text" => "Video", "options" => %w[A B],
        "video" => "https://videos.example/v.mp4" },
      { "type" => "multiple_choice", "cid" => "c_3", "text" => "Empty", "options" => %w[A B] },
      { "type" => "tap_card",        "cid" => "c_4", "text" => "Swipe", "options" => %w[x y],
        "option_images" => [ "/assets/verto-library/a.jpg", "/assets/verto-library/b.jpg" ] },
      { "type" => "range",           "cid" => "c_5", "text" => "Hard?", "options" => %w[Easy Hard],
        "range_theme" => "recycling" }
    ]
    s = make_survey(theme: "Sport fans", cards: cards)
    s.update!(background_image: "/assets/verto-library/backgrounds/chosen.jpg")

    AssetPopulator.new(s, fill_only: true).populate!

    s.reload
    assert_equal "/assets/verto-library/mine.jpg", s.cards[0]["image"], "a chosen photo is not the platform's to replace"
    assert_equal "https://videos.example/v.mp4",   s.cards[1]["video"]
    assert_nil   s.cards[1]["image"],              "and it must not gain a photo alongside its video"
    assert       s.cards[2]["image"].present?,     "the empty card is the whole point — it must still be filled"
    assert_equal [ "/assets/verto-library/a.jpg", "/assets/verto-library/b.jpg" ], s.cards[3]["option_images"]
    assert_equal "recycling", s.cards[4]["range_theme"]
  end

  test "Shuffle still overwrites, because that is what Shuffle is" do
    cards = [ { "type" => "multiple_choice", "cid" => "c_1", "text" => "Mine", "options" => %w[A B],
                "image" => "/assets/verto-library/mine.jpg" } ]
    s = make_survey(theme: "Sport fans", cards: cards)

    AssetPopulator.new(s, seed: "abc").populate!

    assert_not_equal "/assets/verto-library/mine.jpg", s.reload.cards.first["image"],
                     "a creator clicking Shuffle is asking for a different picture"
  end

  test "populate_merged! applies picks to the deck as it is NOW, not as it was loaded" do
    cards = [
      { "type" => "multiple_choice", "cid" => "c_1", "text" => "One", "options" => %w[A B] },
      { "type" => "multiple_choice", "cid" => "c_2", "text" => "Two", "options" => %w[A B] }
    ]
    s = make_survey(theme: "Sport fans", cards: cards)

    populator = AssetPopulator.new(s, fill_only: true)
    # The creator edits and reorders from the editor while the run is in flight.
    Survey.find(s.id).update!(cards: [
      { "type" => "multiple_choice", "cid" => "c_2", "text" => "Two", "options" => %w[A B] },
      { "type" => "multiple_choice", "cid" => "c_1", "text" => "Renamed by hand", "options" => %w[A B] }
    ])
    populator.populate_merged!

    fresh = Survey.find(s.id).cards
    assert_equal %w[c_2 c_1], fresh.map { |c| c["cid"] }, "the creator's reorder must stand"
    assert_equal "Renamed by hand", fresh.second["text"], "and their edit with it"
    assert fresh.all? { |c| c["image"].present? }, "while both cards still get their imagery"
  end

  # ── A blank theme ─────────────────────────────────────────────────────────
  # import_pdf posts with formnovalidate and, unlike #generate, validates
  # neither theme nor audience — so an imported Verto routinely has none. With
  # nothing to anchor on, card_query fell through to "abstract" and the
  # relevance floor then rejected nearly every photo that came back: a run that
  # COMPLETED and still yielded almost nothing, which to the creator looks
  # exactly like one that never ran.

  test "a blank theme falls back to what the Verto does say about itself" do
    s = make_survey(theme: "", cards: [ { "type" => "multiple_choice", "text" => "Q", "options" => %w[A B] } ])
    s.update!(title: "Grassroots football in Leeds", key_insight: "why players stay")

    terms = AssetPopulator.new(s).send(:theme_source_text)
    assert_includes terms, "football"
    assert_includes terms, "players", "the key insight counts too — it is the creator's own words"
  end

  test "a title the app minted is not something to anchor a photo search on" do
    s = make_survey(theme: "", cards: [
      { "type" => "multiple_choice", "text" => "Which sport do you play most?", "options" => [ "Football", "Netball" ] }
    ])
    s.update!(title: "Imported Verto", key_insight: nil, description: nil)

    source = AssetPopulator.new(s).send(:theme_source_text)
    assert_not_includes source, "imported", "every query would have been anchored on the word 'imported'"
    assert source.present?, "it has to fall through to the deck's own vocabulary rather than give up"
    assert_match(/sport|play|football|netball/, source)
  end

  test "a derived theme does not unlock the charged-term allowance" do
    s = make_survey(theme: "", cards: [ { "type" => "multiple_choice", "text" => "Q", "options" => %w[A B] } ])
    s.update!(title: "Protest and dissent")

    populator = AssetPopulator.new(s)
    assert_includes populator.send(:theme_source_text).downcase, "protest"
    assert_not populator.send(:charged_theme?),
               "the allowance exists because the creator STATED the topic — a phrase we " \
               "derived from a title is not a statement, and letting a derivation flip a " \
               "safety switch would be a regression"
  end

  # ── One piece of content, one place ───────────────────────────────────────
  # Reported as "multiple pieces of content are being used when a verto is
  # generated" — a generated deck showing the same photograph on three cards
  # and the same animation on three sliders. Each source used to repeat as soon
  # as its OWN pool ran dry, while the other sources sat unasked, so "we ran
  # out" and "we didn't look" were indistinguishable from the outside. Every
  # test below is the same rule from a different angle: spend everything before
  # repeating anything.

  test "a deck longer than one pool takes from the next pool rather than repeating" do
    # Eight select cards against a five-asset themed left-panel pool. Cards
    # six to eight used to be handed a second copy of a left-panel photo with
    # the eight-asset select-art pool untouched next to them.
    cards = (1..8).map { |i| { "type" => "multiple_choice", "text" => "Q#{i}", "options" => %w[a b] } }
    s = make_survey(theme: "Sport", audience_age: "18-24", cards: cards)

    AssetPopulator.new(s).populate!

    imgs = s.reload.cards.map { |c| c["image"] }.compact
    assert_equal 8, imgs.size, "every card should still be illustrated"
    assert_equal imgs.size, imgs.uniq.size, "a picture is spent once: #{imgs.map { |u| u[/[^\/]+\z/] }.inspect}"
  end

  test "two cards never share a Pexels photograph" do
    cards = (1..6).map { |i| { "type" => "multiple_choice", "text" => "Peak #{i}?", "options" => %w[a b] } }
    s = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards)
    photos = (1..12).map { |i| pexels_photo(i, "Snowy mountain peak and alpine landscape #{i}") }

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    imgs = s.reload.cards.map { |c| c["image"] }.compact
    assert_equal 6, imgs.size
    assert_equal imgs.size, imgs.uniq.size, "each card gets its own photograph"
  end

  test "a card would rather take curated art than a second copy of a photograph" do
    # One relevant photo, four cards. The first card takes it; the rest must
    # reach the curated library instead of being handed the same photo again.
    cards = (1..4).map { |i| { "type" => "multiple_choice", "text" => "Favourite team #{i}?", "options" => %w[a b] } }
    s = make_survey(theme: "Football fans", audience_age: "18-24", cards: cards)

    with_pexels([ pexels_photo(1, "A football team celebrating a goal on the pitch") ]) do
      AssetPopulator.new(s).populate!
    end

    imgs = s.reload.cards.map { |c| c["image"] }.compact
    assert_equal 4, imgs.size
    assert_equal imgs.size, imgs.uniq.size, "no card repeats another's picture: #{imgs.inspect}"
    assert_equal 1, imgs.count { |u| u.include?("images.pexels.com") },
      "the one relevant photo is spent once, not four times"
    assert_equal 3, imgs.count { |u| u.include?("verto-library/") },
      "the other three come from the curated library"
  end

  test "a card panel is not the backdrop the respondent is already looking at" do
    cards = (1..3).map { |i| { "type" => "multiple_choice", "text" => "Peak #{i}?", "options" => %w[a b] } }
    s = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards)
    photos = (1..8).map { |i| pexels_photo(i, "Snowy mountain peak and alpine landscape #{i}") }

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    s.reload
    backdrop = s.background_image[%r{/photos/(\d+)/}, 1]
    assert backdrop.present?, "the backdrop should be a Pexels photo here"
    s.cards.each_with_index do |c, i|
      refute_equal backdrop, c["image"].to_s[%r{/photos/(\d+)/}, 1],
        "card #{i} is showing the same photograph as the backdrop behind it"
    end
  end

  test "the backdrop is only demoted, never made unavailable" do
    # The one photo that clears relevance IS the backdrop's. Preferring not to
    # reuse it must not cost the card its picture — a soft avoid, not a ban.
    s = make_survey(theme: "Mountains", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "Which peak?", "options" => %w[a b] } ])

    with_pexels([ pexels_photo(1, "Snowy mountain peak and alpine landscape") ]) do
      AssetPopulator.new(s).populate!
    end

    assert_includes s.reload.cards[0]["image"].to_s, "/photos/1/",
      "with nothing else on offer the card takes the backdrop's photo rather than going blank"
  end

  test "every statement on a tap_card gets its own picture, Pexels topped up from the library" do
    # Five statements, three relevant photos. The Pexels picks used to be
    # cycled to length — the first two statements' pictures shown twice — with
    # the eleven-asset curated pool sitting unasked.
    s = make_survey(theme: "Mountains", audience_age: "all",
                    cards: [ { "type" => "tap_card", "text" => "Which mountain peak is best?",
                               "options" => %w[a b c d e] } ])
    photos = (1..3).map { |i| pexels_photo(i, "Snowy mountain peak and alpine landscape #{i}") }

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    imgs = Array(s.reload.cards[0]["option_images"])
    assert_equal 5, imgs.size, "the renderer pairs pictures to statements positionally"
    assert_equal imgs.size, imgs.uniq.size, "no statement repeats its neighbour's picture"
    assert imgs.count { |u| u.include?("verto-library/swipe-cards/") } >= 2,
      "the shortfall is topped up from the curated pool: #{imgs.inspect}"
  end

  test "a statement picture and a card panel are not the same photograph" do
    s = make_survey(theme: "Mountains", audience_age: "all", cards: [
      { "type" => "multiple_choice", "text" => "Which peak?", "options" => %w[a b] },
      { "type" => "tap_card", "text" => "Which mountain peak is best?", "options" => %w[a b] }
    ])
    photos = (1..6).map { |i| pexels_photo(i, "Snowy mountain peak and alpine landscape #{i}") }

    with_pexels(photos) { AssetPopulator.new(s).populate! }

    s.reload
    panel = s.cards[0]["image"].to_s[%r{/photos/(\d+)/}, 1]
    ids   = Array(s.cards[1]["option_images"]).map { |u| u[%r{/photos/(\d+)/}, 1] }.compact
    assert panel.present?
    refute_includes ids, panel,
      "the same photograph was cropped for a panel and for a statement — one picture, two slots"
  end

  test "every range card plays a different animation" do
    # "Climate action" matches four animations; a five-slider deck has to reach
    # past them. An independent draw per card used to give this deck two.
    cards = (1..5).map { { "type" => "range", "text" => "How worried are you?", "options" => %w[a b c] } }
    s = make_survey(theme: "Climate action", audience_age: "all", cards: cards)

    AssetPopulator.new(s).populate!

    themes = s.reload.cards.map { |c| c["range_theme"] }
    assert_equal themes.size, themes.uniq.size, "one animation, one slider: #{themes.inspect}"
    on_theme = NpsHelper.range_themes_for("Climate action")
    assert_equal on_theme.to_set, themes.first(on_theme.size).to_set,
      "the on-theme animations are spent BEFORE the deck reaches past them"
    (themes - on_theme).each do |t|
      assert_includes NpsHelper::RANGE_THEME_FALLBACK, t,
        "past the theme, the next animation is a neutral one — never an off-theme subject"
    end
  end

  test "a redraw of an animation already playing is not a different animation" do
    # speech_bubbles and speech_bubbles_colour are one drawing in two colourways:
    # distinct slugs, but to a respondent scrolling past, the same animation
    # twice. A neutral animation nobody has seen is the better answer.
    cards = (1..4).map { { "type" => "range", "text" => "How was it?", "options" => %w[a b c] } }
    s = make_survey(theme: "Customer feedback", audience_age: "all", cards: cards)

    AssetPopulator.new(s).populate!

    themes   = s.reload.cards.map { |c| c["range_theme"] }
    families = themes.map { |t| NpsHelper.range_theme_family(t) }
    assert_equal themes.size, themes.uniq.size
    assert_equal families.size, families.uniq.size,
      "two animations from the same family are playing: #{themes.inspect}"
  end

  test "a veto still holds once the on-theme animations run out" do
    cards = (1..12).map { { "type" => "range", "text" => "How was the match?", "options" => %w[a b c] } }
    s = make_survey(theme: "Football fans", audience_age: "all", cards: cards)

    AssetPopulator.new(s, seed: "anim", direction: "no football").populate!

    themes = s.reload.cards.map { |c| c["range_theme"] }
    assert_equal themes.size, themes.uniq.size, "twelve sliders, twelve animations"
    assert_empty themes & %w[football football_goal],
      "reaching further for variety must not reach past the veto"
    themes.each { |t| assert_includes NpsHelper::RANGE_THEMES, t }
  end

  test "a fill-only top-up does not hand a card what the deck is already showing" do
    # The import path: the creator already has imagery on some cards and this
    # run fills the rest. What they have is content the Verto is showing.
    # Three of the four animations this theme matches are already playing, so
    # the fourth card has exactly one on-theme animation left to it — and a run
    # that read the deck as empty would have all four to choose from and a
    # three-in-four chance of duplicating one.
    kept  = pexels_photo(1, "A recycling bin and climate action 1")
    cards = [
      { "type" => "multiple_choice", "text" => "Q1", "options" => %w[a b],
        "image" => PexelsClient.url_for(kept, :card) },
      { "type" => "multiple_choice", "text" => "Q2", "options" => %w[a b] },
      { "type" => "range", "text" => "Q3", "options" => %w[a b c], "range_theme" => "recycling" },
      { "type" => "range", "text" => "Q4", "options" => %w[a b c], "range_theme" => "sun" },
      { "type" => "range", "text" => "Q5", "options" => %w[a b c], "range_theme" => "flowers" },
      { "type" => "range", "text" => "Q6", "options" => %w[a b c] }
    ]
    s = make_survey(theme: "Climate action", audience_age: "all", cards: cards)

    with_pexels([ kept ]) { AssetPopulator.new(s, fill_only: true).populate! }

    s.reload
    assert_equal PexelsClient.url_for(kept, :card), s.cards[0]["image"],
      "fill-only leaves what the creator already had"
    refute_equal s.cards[0]["image"], s.cards[1]["image"],
      "and does not hand the next card a second crop of the same photograph"
    themes = s.cards.filter_map { |c| c["range_theme"] }
    assert_equal %w[recycling sun flowers], themes.first(3), "the creator's animations are kept"
    assert_equal themes.size, themes.uniq.size,
      "an animation already playing is one this run must not pick again: #{themes.inspect}"
  end
end
