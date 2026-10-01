require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ERB::Util # mini_preview_html calls the bare `h` escape helper
  # editor_cards_i18n powers the inline #survey-cards-i18n island. It must keep
  # the translatable text the language-tab JS reads, and drop the heavy
  # image/structural fields so base64 data URLs aren't serialised inline.

  test "keeps text, description and options per locale" do
    cards = [ {
      "type" => "multiple_choice",
      "text" => "Favourite sport?",
      "description" => "Pick one",
      "options" => %w[Football Rugby],
      "i18n" => { "fr" => { "text" => "Sport préféré ?", "options" => %w[Foot Rugby] } }
    } ]
    out = editor_cards_i18n(cards)
    assert_equal "Favourite sport?", out.first["text"]
    assert_equal "Pick one", out.first["description"]
    assert_equal %w[Football Rugby], out.first["options"]
    assert_equal "Sport préféré ?", out.first.dig("i18n", "fr", "text")
    assert_equal %w[Foot Rugby], out.first.dig("i18n", "fr", "options")
  end

  test "drops image and option_images (base64) and structural fields" do
    big = "data:image/webp;base64,#{"A" * 5000}"
    cards = [ {
      "type" => "tap_card",
      "text" => "Swipe",
      "image" => big,
      "option_images" => [ big, big ],
      "options" => %w[A B],
      "correct" => { "A" => "right" }
    } ]
    out = editor_cards_i18n(cards)
    refute out.first.key?("image")
    refute out.first.key?("option_images")
    refute out.first.key?("type")
    refute out.first.key?("correct")
    refute_includes out.to_json, "AAAA", "base64 image data must not reach the island"
  end

  # rating_icon themes the rating answer-type icon to the Verto.
  Struct.new("ThemedSurvey", :theme, :title, :key_insight) unless defined?(Struct::ThemedSurvey)
  def themed(theme: nil, title: nil, key_insight: nil)
    Struct::ThemedSurvey.new(theme, title, key_insight)
  end

  test "themed Vertos rate in a matching emoji" do
    assert_equal({ on: "🚀", off: "🚀", kind: "emoji" }, rating_icon(themed(theme: "space")))
    assert_equal "🍔", rating_icon(themed(theme: "Food and nutrition"))[:on]
    assert_equal "⚽", rating_icon(themed(theme: "Football fans"))[:on]
  end

  # The card's own pick beats the theme — "if it auto-generated something
  # completely unrelated to education, I'll be stuck, because I can't actually
  # change that". One emoji for all five points; absent or blank, the theme.
  test "a rating card's own emoji beats the Verto's theme, and a blank one falls back" do
    survey = themed(theme: "Books and reading")
    assert_equal "📚", rating_icon(survey)[:on], "the theme still picks when the card has no say"
    assert_equal({ on: "🎲", off: "🎲", kind: "emoji" }, rating_icon(survey, { "rating_emoji" => "🎲" }))
    assert_equal({ on: "🇪🇺", off: "🇪🇺", kind: "emoji" }, rating_icon(survey, { "rating_emoji" => " 🇪🇺 " }),
                 "a flag is one emoji, and the stored value is trimmed on the way out")
    assert_equal "📚", rating_icon(survey, { "rating_emoji" => "" })[:on]
    assert_equal "📚", rating_icon(survey, {})[:on]
    assert_equal "★", rating_icon(nil, { "rating_emoji" => "" })[:on]
    assert_equal "🎲", rating_icon(nil, { "rating_emoji" => "🎲" })[:on], "no survey at all is still a pick"
  end

  # nps_container_shape themes the NPS liquid-container silhouette per Verto.
  test "nps container shape is a known shape, stable per theme, and varies by theme" do
    %w[Space Food Climate].each do |t|
      assert_includes ApplicationHelper::NPS_CONTAINER_SHAPES, nps_container_shape(themed(theme: t))
    end
    assert_equal nps_container_shape(themed(theme: "Mountains")), nps_container_shape(themed(theme: "Mountains"))
    shapes = %w[Space Food Climate Music Travel Sport Fashion Coffee Gaming Health]
             .map { |t| nps_container_shape(themed(theme: t)) }.uniq
    assert_operator shapes.size, :>, 1, "expected NPS container shapes to vary across themes"
  end

  test "nps container shape picks a fitting vessel for themed subjects" do
    assert_equal "tube",   nps_container_shape(themed(theme: "What under 10s think about space"))
    assert_equal "flask",  nps_container_shape(themed(theme: "Science and research"))
    assert_equal "flask",  nps_container_shape(themed(theme: "Members insights"))
    assert_equal "mug",    nps_container_shape(themed(theme: "Coffee habits"))
    assert_equal "jar",    nps_container_shape(themed(theme: "Food and nutrition"))
    assert_equal "bottle", nps_container_shape(themed(theme: "Climate and the environment"))
    assert_equal "bottle", nps_container_shape(themed(theme: "Renewable energy"))
    assert_equal "can",    nps_container_shape(themed(theme: "Soda and fizzy drinks"))
  end

  test "every mapped shape is a real vessel silhouette (no distorting objects)" do
    ApplicationHelper::NPS_SHAPE_THEMES.each do |_kw, shape|
      assert_includes ApplicationHelper::NPS_CONTAINER_SHAPES, shape
    end
    %w[lightbulb rocket battery].each do |gone|
      refute_includes ApplicationHelper::NPS_CONTAINER_SHAPES, gone
    end
  end

  test "nps container shape falls back for a blank or nil theme" do
    assert_equal ApplicationHelper::NPS_CONTAINER_SHAPES.first, nps_container_shape(themed(theme: ""))
    assert_equal ApplicationHelper::NPS_CONTAINER_SHAPES.first, nps_container_shape(nil)
  end

  test "singularised matching means plurals and variants hit without being listed" do
    # "rockets"/"fans"/"dogs" aren't in the keyword lists; singularising both
    # sides makes them match anyway.
    assert_equal "🚀", rating_icon(themed(theme: "All about rockets"))[:on]
    assert_equal "⚽", rating_icon(themed(theme: "Football fans"))[:on]
    assert_equal "🐾", rating_icon(themed(theme: "Dogs and cats"))[:on]
  end

  test "draws on the title and key_insight, not just the theme" do
    # A terse/unmatched theme still resolves via the descriptive title.
    icon = rating_icon(themed(theme: "Q2 pulse", title: "How fans feel about the football season"))
    assert_equal "⚽", icon[:on]
  end

  test "the dominant subject wins when several themes appear" do
    # "space" appears twice (theme + insight), "food" once — rocket wins.
    icon = rating_icon(themed(theme: "Space exploration",
                              key_insight: "what food astronauts want in space"))
    assert_equal "🚀", icon[:on]
  end

  test "matches whole words, not substrings" do
    # "start" contains "star" but must not trigger the space rocket; it has no
    # themed match, so it falls back to the classic star.
    assert_equal "star", rating_icon(themed(theme: "Startup founders"))[:kind]
  end

  test "untyped or unmatched Vertos keep the classic star" do
    assert_equal({ on: "★", off: "☆", kind: "star" }, rating_icon(themed(theme: "")))
    assert_equal({ on: "★", off: "☆", kind: "star" }, rating_icon(nil))
    assert_equal "star", rating_icon(themed(theme: "Quarterly NPS pulse"))[:kind]
  end

  # card_eyebrows_i18n feeds the #card-eyebrows-i18n island that
  # survey_editor_controller reads when a translation tab is switched (the
  # card_component partial itself can't re-render then — the editor swaps
  # text client-side, no server round-trip).
  test "card_eyebrows_i18n translates each question type's caption per Verto locale" do
    survey = Struct.new(:verto_locales).new(%w[en es])
    out = card_eyebrows_i18n(survey)

    assert_equal %w[en es], out.keys
    assert_equal I18n.t("card.eyebrow.multiple_choice", locale: "en"), out["en"]["multiple_choice"]
    assert_equal I18n.t("card.eyebrow.multiple_choice", locale: "es"), out["es"]["multiple_choice"]
    refute_equal out["en"]["multiple_choice"], out["es"]["multiple_choice"],
                 "es translation must not silently fall back to the English caption"
  end

  test "card_eyebrows_i18n omits non-question types (welcome/checkpoint have no caption)" do
    out = card_eyebrows_i18n(Struct.new(:verto_locales).new(%w[en]))
    refute out["en"].key?("welcome_card")
    refute out["en"].key?("token_checkpoint")
  end

  # mini_preview_html draws the little mockup inside each add-question type
  # tile. Every pickable question type must produce one — a missing case falls
  # through to the empty `else` and the tile renders blank (the nps bug).
  test "every pickable question type renders a non-empty mini preview" do
    CardTypes.pickable.each do |type, _attrs|
      next unless CardTypes.question?(type)
      html = mini_preview_html({ "type" => type, "options" => %w[A B C] })
      assert html.present?, "mini_preview_html renders nothing for #{type}"
    end
  end

  test "mini previews distinguish the look-alike pick types" do
    nps = mini_preview_html({ "type" => "nps" })
    assert_includes nps, "mini-nps-face"
    assert_includes nps, "mini-slider-track"
    many = mini_preview_html({ "type" => "select_many", "options" => %w[A B] })
    assert_includes many, "mini-p-square"
    one = mini_preview_html({ "type" => "multiple_choice", "options" => %w[A B] })
    refute_includes one, "mini-p-square"
  end

  # ── brand_logo_tag ──────────────────────────────────────────────────────
  # Respondents were seeing the browser's broken-image glyph where the
  # publishing organisation's logo should be, on the player's welcome and
  # thank-you cards. Both properties below exist to stop that recurring.

  test "an uploaded logo is served through the proxy, not the expiring redirect" do
    org = Organisation.create!(name: "Logo Co", slug: "logo-co-#{SecureRandom.hex(3)}")
    org.logo.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "l.png", content_type: "image/png")

    html = brand_logo_tag(org)

    # blobs/redirect is a 302 to a SEPARATELY signed disk URL that expires five
    # minutes after the server minted it, while the redirect itself is cached
    # for five minutes from when the BROWSER got it. Replaying a still-fresh
    # redirect whose signature has lapsed yields a 404 — a broken <img>.
    assert_includes html, "/rails/active_storage/blobs/proxy/"
    refute_includes html, "/rails/active_storage/blobs/redirect/"
  end

  test "an uploaded logo carries the hide-on-error hook" do
    org = Organisation.create!(name: "Logo Co", slug: "logo-co-#{SecureRandom.hex(3)}")
    org.logo.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "l.png", content_type: "image/png")

    html = brand_logo_tag(org)

    # A blob whose bytes are genuinely gone can't be recovered by any URL
    # scheme; it must vanish rather than render as a grey "?" box.
    assert_includes html, 'data-controller="brand-logo"'
    # ERB escapes the arrow inside the attribute; the browser decodes it back.
    assert_includes html, "error-&gt;brand-logo#failed"
  end

  test "an organisation with no logo gets no logo, not our wordmark" do
    org = Organisation.create!(name: "Bare Co", slug: "bare-co-#{SecureRandom.hex(3)}")

    html = brand_logo_tag(org)

    # This used to substitute playverto.svg. That put OUR mark in the slot
    # reserved for the customer's — above their deck, and on the thank-you card
    # directly above the "Powered by Playverto" line, so it appeared twice.
    assert_nil html,
               "an org with no logo must render nothing at all — nil rather than an empty " \
               "string, so a caller can skip drawing a wrapper whose padding would otherwise " \
               "hold an empty band open (see .player-brand-header)"
  end

  test "a nil organisation is handled the same way" do
    # The player resolves its org through @survey.organisation, and a caller
    # reaching this helper with nothing at all should get nothing back rather
    # than an exception or a stray wordmark.
    assert_nil brand_logo_tag(nil)
  end
end
