require "test_helper"

class NpsHelperTest < ActionView::TestCase
  test "RANGE_THEMES includes the default and only known asset folders" do
    assert_includes NpsHelper::RANGE_THEMES, NpsHelper::NPS_THEME
    assert_includes NpsHelper::RANGE_THEMES, "football"
  end

  test "nps_lottie_urls builds one asset path per frame for a known theme" do
    urls = nps_lottie_urls("football")
    assert_equal NpsHelper::NPS_FRAMES, urls.size
    assert(urls.all? { |u| u.include?("football/") && u.end_with?(".json") })
  end

  test "nps_lottie_urls falls back to the default theme for an unknown slug" do
    assert_equal nps_lottie_urls(NpsHelper::NPS_THEME), nps_lottie_urls("not_a_theme")
  end

  # ── neutral resting frame ──────────────────────────────────────────────────
  # The reaction character must greet a respondent expressionless: opening on
  # frame 1 reads as "strongly disagree" and leans the answer before they've
  # touched the slider.

  test "NPS_NEUTRAL_FRAME is the middle of the frame set, derived not hardcoded" do
    assert_equal 3, NpsHelper::NPS_NEUTRAL_FRAME
    assert_equal (NpsHelper::NPS_FRAMES + 1) / 2, NpsHelper::NPS_NEUTRAL_FRAME
  end

  test "render_nps_reaction mounts on the neutral middle frame by default" do
    html = render_nps_reaction(theme: "football")
    assert_includes html, %(data-lottie-player-current-value="#{NpsHelper::NPS_NEUTRAL_FRAME}")
    refute_includes html, %(data-lottie-player-current-value="1")
  end

  test "the neutral frame indexes a real asset in every animation set" do
    NpsHelper::LOTTIE_THEMES.each do |slug|
      neutral = NpsHelper.neutral_frame_for(slug)
      url = nps_lottie_urls(slug)[neutral - 1]
      assert url.present?, "#{slug} has no asset at the neutral frame"
      assert Rails.root.join("app/assets/lottie/#{slug}/#{neutral}.json").exist?,
        "#{slug} is missing its neutral frame file"
    end
  end

  # ── The age card's bound set ───────────────────────────────────────────────
  # Seven frames, one per age band, so the slider changes the file per answer.

  test "the age-band set has exactly one frame per age band, in band order" do
    assert_equal DemographicQuestions::AGE_BANDS.length, NpsHelper.frames_for(NpsHelper::AGE_BAND_THEME)
    assert_equal 7, nps_lottie_urls(NpsHelper::AGE_BAND_THEME).size
    assert_equal NpsHelper::NPS_FRAMES, NpsHelper.frames_for("football"), "every pickable set keeps five"
    assert_equal 4, NpsHelper.neutral_frame_for(NpsHelper::AGE_BAND_THEME),
                 "the resting pose is the middle band, where the thumb parks"
    assert_equal NpsHelper::NPS_NEUTRAL_FRAME, NpsHelper.neutral_frame_for("football")
  end

  test "the age card always plays the age-band set, whatever range_theme it stores" do
    age = DemographicQuestions.cards.first
    assert NpsHelper.age_band_card?(age)
    assert_equal NpsHelper::AGE_BAND_THEME, range_theme_slug(age)
    assert_equal NpsHelper::AGE_BAND_THEME, range_theme_slug(age.merge("range_theme" => "pizza")),
                 "a stamp from before the set existed must not win"
    assert_equal NpsHelper::AGE_BAND_THEME,
                 range_theme_slug(DemographicQuestions.core_card("age")), "the keyed generation too"

    seven = { "type" => "range", "text" => "Q", "options" => DemographicQuestions::AGE_BAND_LABELS,
              "range_theme" => "pizza" }
    refute NpsHelper.age_band_card?(seven), "seven stops alone do not make a card the age card"
    assert_equal "pizza", range_theme_slug(seven)
    assert slider_top_down?(age)
    refute slider_top_down?(seven)
  end

  test "the age-band set is bound to its card, never offered or stored" do
    refute_includes NpsHelper::RANGE_THEMES, NpsHelper::AGE_BAND_THEME, "the picker must not offer it"
    refute_includes range_theme_picker_data[:themes].map { |t| t[:slug] }, NpsHelper::AGE_BAND_THEME
    assert_includes NpsHelper::LOTTIE_THEMES, NpsHelper::AGE_BAND_THEME, "but it is playable"
    assert_equal NpsHelper::NPS_THEME, range_theme_slug({ "range_theme" => NpsHelper::AGE_BAND_THEME }),
                 "an ordinary card storing the slug falls back like any unknown slug"
  end

  test "render_nps_reaction opens the age-band set on its own middle frame with all seven urls" do
    html = render_nps_reaction(theme: NpsHelper::AGE_BAND_THEME)
    assert_includes html, %(data-lottie-player-current-value="4")
    urls = JSON.parse(Nokogiri::HTML.fragment(html).at(".nps-lottie")["data-lottie-player-urls-value"])
    assert_equal 7, urls.size
    assert_match %r{/music_eras/1(-\h+)?\.json\z}, urls.first
    assert_match %r{/music_eras/7(-\h+)?\.json\z}, urls.last
  end

  test "range_theme_slug returns a known card theme, default otherwise" do
    assert_equal "football", range_theme_slug({ "range_theme" => "football" })
    assert_equal NpsHelper::NPS_THEME, range_theme_slug({ "range_theme" => "not_a_theme" })
    assert_equal NpsHelper::NPS_THEME, range_theme_slug({})
    assert_equal NpsHelper::NPS_THEME, range_theme_slug(nil)
  end

  test "range_theme_picker_data lists every theme with a label and frame URLs" do
    data = range_theme_picker_data
    assert data[:label].present?
    assert_equal NpsHelper::RANGE_THEMES.size, data[:themes].size
    data[:themes].each do |t|
      assert_includes NpsHelper::RANGE_THEMES, t[:slug]
      assert t[:label].present?
      assert_equal NpsHelper::NPS_FRAMES, t[:urls].size
    end
  end

  test "RANGE_THEMES is exactly the flattened groups (single source of truth)" do
    assert_equal NpsHelper::RANGE_THEME_GROUPS.values.flatten, NpsHelper::RANGE_THEMES
    assert_includes NpsHelper::RANGE_THEME_GROUPS.values.flatten, NpsHelper::NPS_THEME
  end

  test "range_theme_groups covers every theme exactly once, each with a label" do
    slugs = range_theme_groups.flat_map { |_cat, opts| opts.map { |_label, slug| slug } }
    assert_equal NpsHelper::RANGE_THEMES.sort, slugs.sort
    assert_equal slugs, slugs.uniq, "no theme appears in two categories"
    range_theme_groups.each do |cat, opts|
      assert cat.present?
      opts.each { |label, _slug| assert label.present? }
    end
  end

  test "range_theme_picker_data groups cover all themes" do
    slugs = range_theme_picker_data[:groups].flat_map { |g| g[:slugs] }
    assert_equal NpsHelper::RANGE_THEMES.sort, slugs.sort
  end

  test "every registered theme ships exactly the animation frames it declares" do
    NpsHelper::LOTTIE_THEMES.each do |slug|
      frames = NpsHelper.frames_for(slug)
      (1..frames).each do |i|
        path = Rails.root.join("app/assets/lottie", slug, "#{i}.json")
        assert File.exist?(path), "missing #{path}"
        assert JSON.parse(File.read(path)).key?("layers"), "#{path} is not a Lottie animation"
      end
      extra = Rails.root.join("app/assets/lottie", slug, "#{frames + 1}.json")
      refute File.exist?(extra), "#{slug} ships #{extra.basename} but declares #{frames} frames — " \
                                 "register the count in NpsHelper::LOTTIE_FRAMES or the player never reaches it"
    end
  end

  test "range_theme_label overrides titleize where configured" do
    assert_equal "PV Mascots", range_theme_label("pv_mascots")
    assert_equal "Emoji Set A", range_theme_label("emoji_a")
    assert_equal "Basketball", range_theme_label("basketball")
    NpsHelper::RANGE_THEME_LABELS.each_key do |slug|
      assert_includes NpsHelper::RANGE_THEMES, slug, "label override for unknown slug #{slug}"
    end
  end

  # ── range_themes_for (auto-population / Shuffle theme matching) ────────────

  test "RANGE_THEME_KEYWORDS covers every theme slug" do
    assert_equal NpsHelper::RANGE_THEMES.sort, NpsHelper::RANGE_THEME_KEYWORDS.keys.sort
  end

  # The reported bug: a "Food and Sustainability" Verto shuffled to Football.
  # Guard against any sport animation reaching a food/climate theme.
  test "a food/sustainability theme never surfaces a sport animation" do
    pool = NpsHelper.range_themes_for("Food and Sustainability")
    assert (pool & NpsHelper::RANGE_THEME_GROUPS["Sport"]).empty?,
      "no sport animation for a food/sustainability Verto, got #{pool.inspect}"
    assert_includes pool, "pizza"
    assert(pool.any? { |s| NpsHelper::RANGE_THEME_GROUPS["Climate & Sustainability"].include?(s) },
      "a sustainability theme should surface climate animations too")
  end

  test "range_themes_for keeps only on-theme animations, best match first" do
    pool = NpsHelper.range_themes_for("Climate change and recycling")
    assert_includes pool, "recycling"
    assert_includes pool, "sun"
    refute_includes pool, "basketball", "a sport animation must not match a climate theme"
    assert_equal "recycling", pool.first, "the strongest keyword overlap ranks first"
  end

  test "range_themes_for matches a theme string's own words (raw, not cluster-expanded)" do
    assert_equal NpsHelper::RANGE_THEME_GROUPS["Sport"].sort,
                 NpsHelper.range_themes_for("Grassroots sport and fitness").sort
    wellbeing_pool = NpsHelper.range_themes_for("Mental health and wellbeing")
    assert_includes wellbeing_pool, "balance"
    assert (wellbeing_pool & NpsHelper::RANGE_THEME_GROUPS["Sport"]).empty?,
      "no sport animation for a wellbeing Verto, got #{wellbeing_pool.inspect}"
    assert_includes NpsHelper.range_themes_for("Remote work productivity"), "calendar"
    assert_includes NpsHelper.range_themes_for("New technology and AI"), "radar"
  end

  test "range_themes_for singularises so plural themes still match" do
    assert_includes NpsHelper.range_themes_for("Schools and students"), "calendar"
    assert_includes NpsHelper.range_themes_for("Sports fans"), "basketball"
  end

  test "range_themes_for falls back to the General group when nothing is on-theme" do
    assert_equal NpsHelper::RANGE_THEME_FALLBACK, NpsHelper.range_themes_for("Opera and classical composers")
    assert_equal NpsHelper::RANGE_THEME_FALLBACK, NpsHelper.range_themes_for("")
    assert_equal NpsHelper::RANGE_THEME_FALLBACK, NpsHelper.range_themes_for([])
  end

  test "range_themes_for surfaces the coins animation for a money theme" do
    assert_equal "coins", NpsHelper.range_themes_for("Personal finance and money").first
  end

  test "range_themes_for is deterministic for the same theme" do
    assert_equal NpsHelper.range_themes_for("Food and nutrition"),
                 NpsHelper.range_themes_for("Food and nutrition")
  end

  # ── slider_top_down? ─────────────────────────────────────────────────────
  test "slider_top_down? is the age card only, keyed or keyless" do
    assert slider_top_down?(DemographicQuestions.cards.first)
    assert slider_top_down?(DemographicQuestions.core_card("age"))
    refute slider_top_down?({ "type" => "range", "options" => %w[A B C] })
    refute slider_top_down?({ "type" => "open_ended", "input" => "month", "demographic" => true })
    refute slider_top_down?(nil)
  end

  # ── resolved_slider_axis ─────────────────────────────────────────────────

  test "resolved_slider_axis honors an explicit horizontal/vertical override" do
    assert_equal "horizontal", resolved_slider_axis({ "slider_axis" => "horizontal", "options" => %w[A B] })
    assert_equal "vertical", resolved_slider_axis({ "slider_axis" => "vertical", "options" => %w[A B] })
  end

  test "resolved_slider_axis defaults short labels to horizontal" do
    assert_equal "horizontal", resolved_slider_axis({ "options" => %w[Low High] })
    assert_equal "horizontal", resolved_slider_axis({ "options" => [] })
  end

  test "resolved_slider_axis picks vertical for a long label, even unset/auto" do
    long = "This option's text is definitely too long for a horizontal pill"
    assert_equal "vertical", resolved_slider_axis({ "options" => [ "Short", long ] })
    assert_equal "vertical", resolved_slider_axis({ "slider_axis" => "auto", "options" => [ "Short", long ] })
  end

  test "resolved_slider_axis picks vertical for many short options" do
    labels = %w[A B C D E F]
    assert_equal "vertical", resolved_slider_axis({ "options" => labels })
  end

  test "resolved_slider_axis is safe on a blank/malformed card" do
    assert_equal "horizontal", resolved_slider_axis({})
    assert_equal "horizontal", resolved_slider_axis(nil)
  end
end
