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

  # The inline width _paintMap writes, which is empty until the controller has
  # loaded its data and decided what is selected. Measuring before that gets
  # the browser's default 1px and compares it against a painted 1.6px — a race
  # the full suite lost and a single-file run won.
  def painted?(code)
    evaluate_script(<<~JS).to_s.present?
      (() => {
        const el = document.querySelector(".world-map ##{code}")
        const path = el.tagName.toLowerCase() === "g" ? el.querySelector("path") : el
        return path.style.strokeWidth
      })()
    JS
  end

  def stroke_px_for(code)
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".world-map ##{code}")
        const path = el.tagName.toLowerCase() === "g" ? el.querySelector("path") : el
        return getComputedStyle(path).strokeWidth
      })()
    JS
  end

  def zoom_factor
    evaluate_script(<<~JS)
      (() => {
        const svg = document.querySelector(".world-map")
        return svg.getBoundingClientRect().width / Number(svg.getAttribute("viewBox").split(/\\s+/)[2])
      })()
    JS
  end

  # Re-fit through the real controller with only one country's worth of data,
  # which is the zoom that exposed the stroke.
  def zoom_to_europe
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".results-map-band")
        const app = window.Stimulus || window.application
        const c = app.getControllerForElementAndIdentifier(el, "results-compare")
        c._mapData = { gb: { segment_ids: ["region_GB"], count: 9, name: "UK" } }
        c._fitHomeView()
      })()
    JS
    sleep 0.3
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

  # Stroke widths are in user units, so they are multiplied by the zoom. That
  # was invisible while the map was always the whole world, and the moment the
  # view was fitted to the data a European audience got a heavy white band
  # around each country. non-scaling-stroke is what holds it; this asserts the
  # property rather than the declaration, so it still fails if the rule is
  # overridden somewhere else rather than deleted.
  test "a country's outline is the same weight however far the map is zoomed" do
    seed_responses("GB", "US", "ZA")
    open_results
    assert_selector ".results-map-band .world-map", wait: 5
    wait_for_stimulus

    wait_until { painted?("gb") }
    wide = stroke_px_for("gb")
    zoom_to_europe
    assert_operator zoom_factor, :>, 2.0, "the test did not actually zoom in"
    assert_equal wide, stroke_px_for("gb"),
      "the outline changed weight when the map zoomed — it is scaling with the viewBox"
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
