require "test_helper"

# The "over time" tab behind every answer row on the results page: one closed
# question's answers counted per period (AnswerTimeline, served by
# SurveyTimelinesController), within the page's segment, for the page's own
# presets or a From/To of the reader's. The endpoint's contract and the two
# pages' halves of it; the tab itself is driven in
# test/system/results_timeline_test.rb.
class ResultsTimelineTest < ActionDispatch::IntegrationTest
  MIN = AnswerTimeline::MIN_PERIOD_ANSWERS

  CARDS = [
    { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green Red] },
    { "type" => "tap_card",        "text" => "Drinks",  "options" => %w[Coffee Tea] },
    { "type" => "open_ended",      "text" => "Why?" },
    { "type" => "prioritise",      "text" => "Rank",    "options" => %w[A B C] },
    { "type" => "nps",             "text" => "How likely?" }
  ].freeze

  def setup
    @org   = Organisation.create!(name: "O", slug: "tl-#{SecureRandom.hex(3)}")
    @admin = make_user("admin")
    @org.memberships.create!(user: @admin, role: "admin")
    @survey = @org.surveys.create!(
      title: "TL", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      publish_token: SecureRandom.hex(8), published_at: Time.current
    )
    @link = @survey.survey_links.create!(name: "Newsletter", slug: "news-#{SecureRandom.hex(2)}")
    @tap_keys = TapScales.keys_for(CARDS[1])

    # Ten days of answers, six a day — three Blue, two Green, one Red — except
    # three days ago, which has two (under the small-cell line). Even days
    # arrive through the named link. Noon, so nothing straddles a day.
    10.times do |d|
      (d == 3 ? 2 : 6).times { |i| add(d.days, i, link: d.even? ? @link : nil) }
    end
    # And a block from two months back, for the weekly view.
    20.times { |i| add(60.days, i) }
  end

  def add(ago, i, link: nil, extra: {})
    colour = %w[Blue Blue Blue Green Green Red][i % 6]
    at     = Time.current.utc.change(hour: 12) - ago
    @survey.responses.create!(
      session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
      created_at: at, updated_at: at, survey_link: link,
      answers: { "0" => { "type" => "multiple_choice", "value" => colour },
                 "1" => { "type" => "tap_card", "value" => { "Coffee" => @tap_keys[0], "Tea" => @tap_keys[-1] } },
                 "3" => { "type" => "prioritise", "value" => %w[A B C] },
                 "4" => { "type" => "nps", "value" => i % 11 } }.merge(extra)
    )
  end

  def make_user(tag)
    User.create!(name: tag.capitalize, email_address: "#{tag}-#{SecureRandom.hex(3)}@test.com",
                 password: "verylongpassword")
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def timeline(card_index: 0, **params)
    get survey_results_timeline_path(@survey, card_index: card_index, **params), as: :json
    assert_response :success
    JSON.parse(response.body)
  end

  # ── Buckets ───────────────────────────────────────────────────────────────

  test "buckets by day inside a month and by week beyond it" do
    sign_in @admin

    week = timeline(range: "7d")
    assert week["ok"]
    assert_equal "day", week["granularity"]
    assert_equal 8, week["periods"].size, "seven days ago through today"
    assert_equal Date.current.iso8601, week["periods"].last["start"]
    assert_equal [ 3, 2, 1 ], week["periods"].last["counts"]
    assert_equal 6, week["periods"].last["n"]

    all = timeline(range: "all")
    assert_equal "week", all["granularity"], "sixty-one days is past the daily span"
    assert all["periods"].first["start"] <= 60.days.ago.to_date.iso8601, "starts at the first response"
    assert_equal Date.current.beginning_of_week.iso8601, all["periods"].last["start"]
    assert_equal 20, all["periods"].first["n"]
  end

  test "a period with fewer answers than the small-cell line is withheld, not shown small" do
    sign_in @admin
    thin = timeline(range: "7d")["periods"].find { |p| p["start"] == 3.days.ago.to_date.iso8601 }

    assert thin["thin"]
    assert_nil thin["n"]
    assert_nil thin["counts"]
    refute timeline(range: "7d")["periods"].last["thin"]
  end

  test "series are the card's rows in the card's order, with the card's own denominator" do
    sign_in @admin
    data = timeline(range: "30d")

    assert_equal %w[Blue Green Red], data["series"].map { |s| s["key"] }, "sorted by count, as the card sorts its rows"
    assert_equal %w[Blue Green Red], data["series"].map { |s| s["label"] }
    data["periods"].reject { |p| p["thin"] }.each do |p|
      assert_equal p["counts"].sum, p["n"], "the share's denominator is the row counts' sum, like the card's percentages"
    end
    assert_equal MIN, data["min_answers"]
  end

  test "a write-in shows as the Other row" do
    5.times { |i| add(0.days, i, extra: { "0" => { "type" => "multiple_choice", "value" => "Other", "other" => "Teal" } }) }
    sign_in @admin
    data = timeline(range: "7d")

    assert_includes data["series"].map { |s| s["key"] }, "Other"
  end

  # ── Windows ───────────────────────────────────────────────────────────────

  test "a custom window picks its own buckets and refuses nonsense" do
    sign_in @admin
    from = 9.days.ago.to_date
    to   = 5.days.ago.to_date

    data = timeline(from: from.iso8601, to: to.iso8601)
    assert_equal "day", data["granularity"]
    assert_equal 5, data["periods"].size
    assert_equal from.iso8601, data["periods"].first["start"]
    assert_equal to.iso8601, data["periods"].last["start"]
    assert_equal from.iso8601, data["from"]
    assert data["periods"].all? { |p| p["n"] == 6 }

    get survey_results_timeline_path(@survey, card_index: 0, from: to.iso8601, to: from.iso8601), as: :json
    assert_response :unprocessable_entity, "an inverted window"
    get survey_results_timeline_path(@survey, card_index: 0, from: "yesterday", to: to.iso8601), as: :json
    assert_response :unprocessable_entity, "a date that isn't one"
    get survey_results_timeline_path(@survey, card_index: 0, from: from.iso8601), as: :json
    assert_response :unprocessable_entity, "half a window is no window"
  end

  test "follows the page's segment" do
    sign_in @admin
    data = timeline(range: "7d", segment: "link_#{@link.id}")

    today     = data["periods"].last
    yesterday = data["periods"][-2]
    assert_equal 6, today["n"], "today's answers came through the link"
    assert yesterday["thin"], "yesterday's did not — nothing to show in this segment"
  end

  # ── Card types ────────────────────────────────────────────────────────────

  test "a tap card reports one statement's scale, and needs to be told which" do
    sign_in @admin
    data = timeline(card_index: 1, statement: "Coffee", range: "7d")

    assert_equal @tap_keys, data["series"].map { |s| s["key"] }
    assert_equal "Coffee", data["statement"]
    today = data["periods"].last
    assert_equal 6, today["counts"].first, "everyone said the first thing about coffee"
    assert_equal 0, today["counts"].last

    tea = timeline(card_index: 1, statement: "Tea", range: "7d")
    assert_equal 6, tea["periods"].last["counts"].last, "and the last thing about tea"

    get survey_results_timeline_path(@survey, card_index: 1, range: "7d"), as: :json
    assert_response :unprocessable_entity
  end

  test "a scale card's rows are its steps, the ones nobody picked included" do
    sign_in @admin
    data = timeline(card_index: 4, range: "7d")

    assert_equal (0..10).map(&:to_s), data["series"].map { |s| s["label"] }
    assert_equal 11, data["periods"].last["counts"].size
    assert_equal 6, data["periods"].last["counts"].sum
  end

  test "refuses cards without counted rows" do
    sign_in @admin

    [ 2, 3, 40, -1 ].each do |idx|
      get survey_results_timeline_path(@survey, card_index: idx, range: "7d"), as: :json
      assert_response :unprocessable_entity, "card #{idx}"
      refute JSON.parse(response.body)["ok"]
    end
  end

  # ── The pages ─────────────────────────────────────────────────────────────

  test "the owner's rows are buttons that open the tab; the shared page's are not" do
    sign_in @admin
    get survey_results_path(@survey, segment: "link_#{@link.id}")
    assert_response :success

    assert_select "#results-timeline[hidden]", 1
    assert_select "[data-controller~='answer-timeline']", 1

    rows = css_select("button.rc-row[data-action='click->answer-timeline#open']")
    assert rows.size >= 3 + 2 * @tap_keys.size + 11, "every countable row is a button"

    blue = rows.find { |r| r["data-answer-timeline-key-param"] == "Blue" }
    assert blue, "the Colour card's Blue row opens the tab on Blue"
    url = blue["data-answer-timeline-url-param"]
    assert_match %r{/surveys/#{@survey.id}/results/timeline\?}, url
    assert_match "card_index=0", url
    assert_match "segment=link_#{@link.id}", url, "the tab must follow the page's segment"
    assert_equal "Colour?", blue["data-answer-timeline-question-param"]
    assert_equal "Blue", blue["data-answer-timeline-label-param"]

    coffee = rows.find { |r| r["data-answer-timeline-url-param"].include?("statement=Coffee") }
    assert coffee, "a tap card's row carries its statement"
    assert_equal @tap_keys.first, coffee["data-answer-timeline-key-param"]

    assert_select "div.rc-row", minimum: 3, message: "prioritise rows stay plain: an average rank is not this tab's measure"
    assert_select "div.rc-row[data-action]", 0

    @survey.update!(results_share_token: SecureRandom.urlsafe_base64(18), results_share_active: true)
    get shared_results_path(@survey.results_share_token)
    assert_response :success
    assert_select "button.rc-row", 0
    assert_select "#results-timeline", 0
  end

  test "is scoped to the signed-in organisation, and any role may read it" do
    other_org  = Organisation.create!(name: "Other", slug: "tl-other-#{SecureRandom.hex(3)}")
    other_user = make_user("other")
    other_org.memberships.create!(user: other_user, role: "admin")
    sign_in other_user
    get survey_results_timeline_path(@survey, card_index: 0, range: "7d"), as: :json
    assert_response :not_found

    viewer = make_user("viewer")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in viewer
    assert timeline(range: "7d")["ok"]

    delete session_path
    get survey_results_timeline_path(@survey, card_index: 0, range: "7d")
    assert_redirected_to new_session_path
  end
end
