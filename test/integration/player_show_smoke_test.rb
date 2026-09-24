require "test_helper"

class PlayerShowSmokeTest < ActionDispatch::IntegrationTest
  # The player is public — no session needed. It resolves the Verto by the
  # publish token (PlayerController#load_survey_and_share).
  def published_survey
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    survey = org.surveys.create!(
      title: "Sports", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[a b c] }
      ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))
    survey
  end

  test "no top nav bar, and no welcome logo when none is uploaded" do
    survey = published_survey

    get play_survey_path(survey.publish_token)
    assert_response :success

    assert_select ".preview-nav", false
    # No logo uploaded → nothing shown (never the Playverto fallback here).
    assert_select ".split-right-logo", false

    # The cards feed and the thank-you screen still render.
    assert_select ".preview-card[data-card-type='welcome_card']"
    # Child chain, not a descendant match: the message column is the half that
    # went missing on the editor's copy of this card, and a descendant selector
    # would keep passing if the wrappers were dropped and the title reparented.
    # .thankyou-message is the scrim the title is read on now that the card
    # itself has no surface — it is in the chain because it has to be BETWEEN
    # the column and the title, not merely somewhere on the page.
    assert_select "[data-player-target='thankyou'] > .preview-thankyou-card > " \
                  ".thankyou-col-message > .thankyou-message > [data-player-target='thankyouTitle']"
  end

  # The one context with no other guard: a respondent's very first sight of a
  # Range card. Opening on frame 1 would greet them with the "strongly
  # disagree" pose before they've touched the slider.
  test "a range card's reaction animation is served resting on the neutral frame" do
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    survey = org.surveys.create!(
      title: "Sports", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "range", "text" => "How much?",
                 "options" => %w[SD D N A SA], "range_theme" => "football" } ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))

    get play_survey_path(survey.publish_token)
    assert_response :success

    assert_select ".nps-lottie[data-lottie-player-current-value=?]",
                  NpsHelper::NPS_NEUTRAL_FRAME.to_s
    assert_select ".nps-lottie[data-lottie-player-current-value='1']", false,
                  "the character must not open on the most extreme pose"
  end

  # The age card's slider has a stop per age band and its set a frame per stop
  # (NpsHelper::AGE_BAND_THEME), so it is served that set — all seven files,
  # whatever animation it was stamped with before the set existed — resting on
  # ITS middle frame, the fourth, where the thumb parks.
  test "the age card is served its own seven-frame set, resting on its middle frame" do
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    survey = org.surveys.create!(
      title: "Sports", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ DemographicQuestions.cards.first.merge("range_theme" => "football") ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))

    get play_survey_path(survey.publish_token)
    assert_response :success

    assert_select ".nps-lottie[data-lottie-player-current-value='4']", 1
    urls = JSON.parse(css_select(".nps-lottie").first["data-lottie-player-urls-value"])
    assert_equal 7, urls.size
    assert urls.all? { |u| u.include?("/#{NpsHelper::AGE_BAND_THEME}/") },
           "expected the age-band set, got #{urls.inspect}"
  end

  test "welcome card shows the creator's logo, centred, when one is uploaded" do
    survey = published_survey
    survey.organisation.logo.attach(
      io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "logo.png", content_type: "image/png"
    )

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select ".split-right .split-right-logo img", 1
  end

  test "a shared /play link carries OpenGraph tags so it unfurls" do
    survey = published_survey
    survey.update!(description: "Five minutes, fully anonymous.")

    get play_survey_path(survey.publish_token)
    assert_response :success

    assert_select "meta[property='og:title'][content=?]", "Sports · Playverto"
    assert_select "meta[property='og:description'][content=?]", "Five minutes, fully anonymous."
    assert_select "meta[property='og:type'][content='website']"
    assert_select "meta[property='og:site_name'][content='Playverto']"
    assert_select "meta[property='og:url'][content=?]", play_survey_url(survey.publish_token)
    # summary_large_image, not summary: there is now always an og:image worth
    # the room. Survey#share_image_path falls through the Verto's own imagery to
    # a theme-matched picture from the committed library, so this is a
    # guarantee rather than a Verto-by-Verto question — see
    # survey_share_image_test.rb.
    assert_select "meta[name='twitter:card'][content='summary_large_image']"
    assert_select "meta[property='og:image'][content=?]",
                  URI.join(play_survey_url(survey.publish_token), survey.share_image_path).to_s
    assert_select "meta[property='og:image:alt'][content=?]", survey.share_image_alt
  end

  test "OpenGraph tags fall back to the theme when there is no description" do
    survey = published_survey
    assert_predicate survey.description, :blank?

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select "meta[property='og:description'][content='Sports']"
  end

  test "a hostile theme or description cannot break out of the meta tag" do
    survey = published_survey
    survey.update!(theme: %(Sports" onmouseover="alert(1)), description: "<script>alert(1)</script>")

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_no_match "onmouseover=\"alert(1)\"", response.body
    assert_no_match "<script>alert(1)</script>", response.body
    assert_select "meta[property='og:title'][content=?]", %(Sports" onmouseover="alert(1)) + " · Playverto"
  end

  test "the theme colour follows the Verto's brand palette" do
    survey = published_survey
    survey.update!(brand_palette: { "bg" => "#112233" })

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select "meta[name='theme-color'][content='#112233']"
  end

  test "the owner's dashboard preview carries no OpenGraph tags — it is never a shared URL" do
    org  = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(2)}@test.com",
                        password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    survey = org.surveys.create!(
      title: "Draft", theme: "Draft", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: [ { "type" => "welcome_card", "title" => "hi" } ]
    )
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }

    get preview_survey_path(survey)
    assert_response :success
    assert_select "meta[property='og:title']", false
  end

  test "OpenGraph tags are absent from the unavailable page" do
    get play_survey_path("no-such-token")
    assert_response :not_found
    assert_select "meta[property='og:title']", false
  end

  # ── Per-Verto PWA manifest (see PlayerController#manifest) ───────────────

  test "the player page links its own per-Verto manifest, not the studio's" do
    survey = published_survey
    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select "link[rel='manifest'][href=?]", play_manifest_path(survey.publish_token)
  end

  test "Test Mode keeps the studio-wide manifest — /test is outside the service worker's /play/ scope" do
    survey = published_survey
    survey.update!(test_token: SecureRandom.hex(8))

    get test_survey_path(survey.test_token)
    assert_response :success
    assert_select "link[rel='manifest'][href='/manifest']"
  end

  test "the owner's dashboard preview keeps the studio-wide manifest" do
    org  = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(2)}@test.com",
                        password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    survey = org.surveys.create!(
      title: "Draft", theme: "Draft", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: [ { "type" => "welcome_card", "title" => "hi" } ]
    )
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }

    get preview_survey_path(survey)
    assert_response :success
    assert_select "link[rel='manifest'][href='/manifest']"
  end
end
