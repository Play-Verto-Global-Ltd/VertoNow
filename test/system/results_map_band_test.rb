require "application_system_test_case"

# The map became a full-bleed band under the filters, and the view it opens on
# is fitted to the countries that have responses rather than fixed to the whole
# world (results_compare_controller#_fitHomeView).
#
# The fit is the part worth a browser: it reads getBBox from the rendered SVG
# and the band's measured width, neither of which exists outside one.
#
# What each test is worth, checked by breaking the code under it rather than
# assumed. "Framed far tighter" fails the moment fitting stops happening — it
# is the test that holds the feature up. "Every country in frame" passes by
# construction today, because the box is clamped to the world and centred on
# the data and preserveAspectRatio="meet" never crops; it earns its place as a
# guard against someone reintroducing a crop (the first cut of this dropped
# South Africa off the bottom of a fixed-height band), not as proof of today's
# code. Said plainly because a test whose value is overstated is worse than no
# test: the next person trusts it.
class ResultsMapBandTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "band-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "band-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Band", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] } ]
    )
  end

  # Responses from countries far apart: a band that frames these badly is one
  # that crops, which is the failure this is here to catch. Counts clear
  # Response::MIN_REGION_SAMPLE_SIZE, or small-cell suppression drops the
  # country before it ever reaches the map.
  def seed_responses(*codes)
    codes.each do |code|
      Response::MIN_REGION_SAMPLE_SIZE.times do
        @survey.responses.create!(session_token: SecureRandom.uuid,
                                  answered: true, status: "completed",
                                  region_country: code,
                                  answers: { "0" => { "value" => "A" } })
      end
    end
  end

  def open_results
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
  end

  def view_box
    evaluate_script("document.querySelector('.world-map').getAttribute('viewBox')").to_s.split(/\s+/).map(&:to_f)
  end

  def country_in_frame?(code)
    evaluate_script(<<~JS)
      (() => {
        const svg = document.querySelector(".world-map")
        const el  = svg.querySelector("##{code}")
        if (!el) return null
        const b = (el.querySelector(".mainland") || el).getBBox()
        const [x, y, w, h] = svg.getAttribute("viewBox").split(/\\s+/).map(Number)
        return b.x >= x && b.y >= y && b.x + b.width <= x + w && b.y + b.height <= y + h
      })()
    JS
  end

  test "every country with responses is inside the frame, however far apart they are" do
    seed_responses("GB", "US", "ZA")
    open_results
    assert_selector ".results-map-band .world-map", wait: 5
    wait_for_stimulus

    %w[gb us za].each do |cc|
      assert_equal true, country_in_frame?(cc),
        "#{cc.upcase} has responses but sits outside the map's opening view"
    end
  end

  # The point of fitting: a local audience gets a local map. Without it every
  # study opens on the whole world and a UK-only Verto is a speck.
  test "a single-country audience is framed far tighter than a global one" do
    seed_responses("GB")
    open_results
    assert_selector ".results-map-band .world-map", wait: 5
    wait_for_stimulus
    local_width = view_box[2]

    assert_equal true, country_in_frame?("gb")
    assert local_width < 500,
      "a UK-only audience still opens on a #{local_width.round}-unit view — the fit is not narrowing to the data"
  end

  test "the band is full-bleed: wider than the reading column beneath it" do
    seed_responses("GB")
    open_results
    assert_selector ".results-map-band", wait: 5

    band   = evaluate_script("document.querySelector('.results-map-band').getBoundingClientRect().width")
    column = evaluate_script("document.querySelector('.results-feed-col').getBoundingClientRect().width")
    assert band > column,
      "the map is #{band.round}px inside a #{column.round}px column — it is not full-bleed"
  end

  # The summary is the lead paragraph and a way to the rest. Anything else is
  # four paragraphs of prose between the map and the first question.
  test "the summary shows its first paragraph, with the rest behind See more" do
    seed_responses("GB")
    @survey.update_columns(
      results_summary: "First paragraph, the one that shows.\n\nSecond paragraph, behind the fold.",
      results_summary_response_count: @survey.responses.where(status: "completed").count
    )
    open_results

    assert_selector "#av-text", text: /First paragraph/, wait: 5
    assert_no_selector "#av-rest", visible: true
    assert_selector ".results-summary-more", text: "See more"

    find(".results-summary-more").click
    assert_selector "#av-rest", visible: true, text: /Second paragraph/
    assert_selector ".results-summary-more", text: "See less"
  end
end
