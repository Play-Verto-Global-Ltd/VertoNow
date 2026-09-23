require "test_helper"

# The results header's headline numbers, moved out of the header and onto the
# map (2026-09-23, owner's instruction), and the three controls that went with
# the move.
#
# Two things here are worth a test rather than a glance:
#
#   * WHERE the tally is rendered. It hangs in the map band's own stage, and
#     that band only exists on a Verto with region-tagged responses or two
#     waves. A count that silently disappears on every other Verto would be
#     the worst possible outcome of tidying the header, and nothing else on
#     the page would say so.
#   * That completion is a RATE. It used to be a raw count beside a raw count,
#     which left the reader to do the division; the percentage is the number
#     they wanted. The count is still in the title for anyone who wants it.
class ResultsTallyTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "multiple_choice", "text" => "What stops you?", "options" => %w[Cost Time] }
  ].freeze

  def setup
    @org  = Organisation.create!(name: "O", slug: "rt-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "rt-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ],
                                   publish_token: SecureRandom.hex(8), published_at: Time.current,
                                   join_prompt_enabled: true, cards: CARDS)
    sign_in
  end

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def answer(n, country: nil, completed: true)
    n.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                                region_country: country,
                                status: completed ? "completed" : "started",
                                answers: { "0" => { "value" => "Cost" } })
    end
  end

  # A country needs Response::MIN_REGION_SAMPLE_SIZE respondents before it is
  # offered as a segment, and the map band only renders once one is.
  def with_map
    answer(7, country: "GB")
    answer(3, country: "GB", completed: false)
  end

  test "the pills hang in the map's own stage when there is a map" do
    with_map
    get survey_results_path(@survey)
    assert_response :success

    assert_select ".compare-map-stage .rmap-stats", 1,
      "the tally must be inside the map stage, which is the box it is positioned against"
    assert_select ".rmap-stats--inline", 0
  end

  # The band needs a region segment or two waves. Everything else — a Verto
  # answered by people whose country was never recorded — has no map at all,
  # and the count is the one thing this page must never be missing.
  test "with no map band the same pills still render, above the feed" do
    answer(6)
    get survey_results_path(@survey)

    assert_select ".results-map-band", 0, "this fixture must not have a map, or the test proves nothing"
    assert_select ".rmap-stats.rmap-stats--inline", 1
    assert_select ".rmap-pill--count .rh-count-num", text: "6"
  end

  test "completion is a percentage of the people who answered, with the count in the title" do
    answer(7)
    answer(3, completed: false)

    get survey_results_path(@survey)

    assert_select ".rmap-pill--rate .rmap-rate-num", text: "70%"
    assert_select ".rmap-pill--rate[title=?]", "7 of 10 reached the end"
  end

  # 0% of nobody is a fact about the Verto not having started, not about its
  # completion, and a pill saying it would be the first thing a creator sees
  # on a Verto they have just published.
  test "no rate pill before anyone has answered" do
    get survey_results_path(@survey)

    assert_select ".rmap-pill--count .rh-count-num", text: "0"
    assert_select ".rmap-pill--rate", 0
  end

  # A segment's count comes from its own filtered scope; the live tally carries
  # whole-Verto totals and would contradict it.
  test "a segment shows its own count and what it is a slice of, and no rate" do
    answer(7, country: "GB")
    answer(6, country: "ES")

    get survey_results_path(@survey, segment: "region_GB")
    assert_response :success

    assert_select ".rmap-pill--count .rh-count-num", text: "7"
    assert_select ".rmap-of", text: "of 13 overall"
    assert_select ".rmap-pill--rate", 0
    assert_select "#results-live", 0,
      "a segment must not subscribe to a broadcast that would overwrite it with whole-Verto numbers"
  end

  # ── What left the header ───────────────────────────────────────────────────

  test "the header carries no auto-refresh toggle, no play link and no asked-to-hear tile" do
    with_map
    get survey_results_path(@survey)

    assert_select ".rh-toggle", 0
    assert_select "[data-controller~='results-autorefresh']", 0
    assert_no_match(/Auto ↻/, response.body)
    assert_no_match(/Play link/, response.body)
    assert_no_match(/asked to hear/, response.body)
  end

  # The Verto's own address, behind the dashboard's Share panel rather than a
  # link to open and copy out of the address bar.
  test "the share button opens the same panel the dashboard's does" do
    with_map
    get survey_results_path(@survey)

    assert_select ".rh-pill--share[data-panel-url=?]", share_survey_path(@survey)
    assert_select ".rh-pill--share[data-action=?]", "click->share-modal#open"
    assert_select "[data-share-modal-target='modal'] turbo-frame#share-modal", 1,
      "the shell the panel loads into has to be on the page for the button to have anywhere to open"
  end

  # Two controls called "Share", one handing out the play link and the other a
  # read-only view of the answers, is a mistake waiting to be made.
  test "the results-sharing menu names what it shares" do
    with_map
    get survey_results_path(@survey)

    assert_select ".results-export-menu summary", text: /Share results/
  end

  # An unpublished Verto has no address to hand out yet.
  test "no share button before there is a link to share" do
    draft = @org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: CARDS)
    get survey_results_path(draft)

    assert_response :success
    assert_select ".rh-pill--share", 0
  end
end
