require "test_helper"

# Dashboard filtering beyond partner shares and regions: slices by the two set
# demographic questions, and a date window.
class ResultsFiltersTest < ActionDispatch::IntegrationTest
  include ResolvesResultSegments

  MIN = Response::MIN_REGION_SAMPLE_SIZE

  def setup
    @org  = Organisation.create!(name: "O", slug: "flt-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "flt-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ] +
             DemographicQuestions.cards,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def add_responses(count, gender: nil, birth_year: nil, created_at: Time.current)
    count.times do
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed",
        answers: { "0" => { "value" => "Yes" } },
        demographic_gender: gender, demographic_birth_year: birth_year,
        created_at: created_at, updated_at: created_at
      )
    end
  end

  def segment_ids(range: nil)
    _base, segments, = resolve_result_segments(@survey, nil, range)
    segments.map { |s| s[:id] }
  end

  # ── Custom links ──────────────────────────────────────────────────────────
  # One pill per link, in creation order, zero-count links included (a fresh
  # research assistant's link shows as 0, not nothing) and recalled links kept.

  test "every custom link is a segment, in order, counted, even at zero" do
    assert_empty segment_ids.grep(/\Alink_/), "no links, no link pills"

    a = @survey.survey_links.create!(name: "RA Ana", slug: "ra-ana-#{SecureRandom.hex(2)}")
    b = @survey.survey_links.create!(name: "RA Ben", slug: "ra-ben-#{SecureRandom.hex(2)}")
    2.times { @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", survey_link: a, answers: { "0" => { "value" => "Yes" } }) }

    _base, segments, = resolve_result_segments(@survey, nil, nil)
    links = segments.select { |s| s[:id].start_with?("link_") }
    assert_equal [ "link_#{a.id}", "link_#{b.id}" ], links.map { |s| s[:id] }
    assert_equal [ 2, 0 ], links.map { |s| s[:count] }
    assert_equal [ "🔗 RA Ana", "🔗 RA Ben" ], links.map { |s| s[:label] }

    b.update!(active: false)
    assert_includes segment_ids, "link_#{b.id}", "a recalled link keeps its segment — its old responses still point at it"

    get survey_results_path(@survey, segment: "link_#{a.id}")
    assert_response :success
    assert_select "a.seg-pill[aria-current='true']", text: /🔗 RA Ana/
  end

  test "a gender with enough responses becomes a segment" do
    add_responses(MIN, gender: "Female")
    assert_includes segment_ids, "gender_female"
  end

  test "a gender below the small-cell threshold is suppressed" do
    # Same rule the regions use: a slice thin enough to identify someone is
    # worse than no slice.
    add_responses(MIN - 1, gender: "Non-binary")
    assert_not_includes segment_ids, "gender_non-binary"
  end

  test "birth years are grouped into age bands, not exposed per year" do
    year = Date.current.year - 30
    add_responses(MIN, birth_year: year)

    ids = segment_ids
    assert_includes ids, "age_25-34"
    assert_not ids.any? { |id| id.include?(year.to_s) }, "a birth year is close to an identifier"
  end

  test "a date window narrows the results" do
    add_responses(3, created_at: 2.days.ago)
    add_responses(4, created_at: 60.days.ago)

    base_all, = resolve_result_segments(@survey, nil, nil)
    base_7d,  = resolve_result_segments(@survey, nil, "7d")
    assert_equal 7, base_all.count
    assert_equal 3, base_7d.count
  end

  test "the window narrows the segment counts too, not just the charts" do
    # A range that moved the charts while the pills kept whole-Verto totals
    # would be misreporting one of them.
    add_responses(MIN, gender: "Male", created_at: 2.days.ago)
    add_responses(MIN, gender: "Male", created_at: 60.days.ago)

    _b, all_segments, = resolve_result_segments(@survey, nil, nil)
    _b, recent, = resolve_result_segments(@survey, nil, "7d")

    assert_equal MIN * 2, all_segments.find { |s| s[:id] == "gender_male" }[:count]
    assert_equal MIN,     recent.find { |s| s[:id] == "gender_male" }[:count]
  end

  test "an unknown range is ignored rather than emptying the results" do
    add_responses(3)
    base, = resolve_result_segments(@survey, nil, "; DROP TABLE")
    assert_equal 3, base.count
  end

  test "the results page renders the window chips and demographic pills" do
    add_responses(MIN, gender: "Female")

    get survey_results_path(@survey)
    assert_response :success
    assert_match "Last 7 days", response.body
    assert_match "Female", response.body
  end

  test "picking a window keeps it while switching segment" do
    add_responses(MIN, gender: "Female", created_at: 2.days.ago)

    get survey_results_path(@survey, range: "7d")
    assert_response :success
    # The segment pills carry the range forward, so choosing a slice doesn't
    # silently widen the window back out to all time.
    assert_select "a.seg-pill[href*='range=7d']", minimum: 1
  end

  test "the player denormalises gender and the age band from the answers" do
    gender_idx = @survey.cards.find_index { |c| c["demographic"] && c["type"] == "multiple_choice" }
    age_idx    = @survey.cards.find_index { |c| c["demographic"] && c["type"] == "range" }
    token = SecureRandom.uuid

    # The age slider stores the INDEX of the stop, not its label — so "1" is
    # the second band, and the band recorded has to come from that position
    # rather than from any text the respondent saw.
    post submit_survey_path(@survey.publish_token),
         params: { session_token: token,
                   answers: { "0" => { "value" => "Yes" },
                              gender_idx.to_s => { "value" => "Female" },
                              age_idx.to_s    => { "value" => 1 } } }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success

    resp = Response.find_by!(session_token: token)
    assert_equal "Female", resp.demographic_gender
    assert_equal "16_17", resp.demographic_age_band
    # No date of birth is recorded by a Verto carrying the slider.
    assert_nil resp.demographic_birth_year
  end

  test "a Verto still carrying the retired month card denormalises a birth year" do
    # Published Vertos keep the card they were published with, so the year
    # path has to go on working for as long as any of them is collecting.
    legacy = @survey.cards.reject { |c| c["demographic"] && c["type"] == "range" }
    legacy << { "type" => "open_ended", "input" => "month",
                "text" => "When were you born?", "demographic" => true }
    @survey.update_column(:cards, legacy)

    birth_idx = legacy.find_index { |c| c["demographic"] && c["input"] == "month" }
    token = SecureRandom.uuid

    post submit_survey_path(@survey.publish_token),
         params: { session_token: token,
                   answers: { "0" => { "value" => "Yes" },
                              birth_idx.to_s => { "value" => "1990-04" } } }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success

    resp = Response.find_by!(session_token: token)
    assert_equal 1990, resp.demographic_birth_year
    assert_nil resp.demographic_age_band
  end

  test "a gender the Verto never offered is refused" do
    # Otherwise a tampered payload could invent a segment label that then
    # renders in the creator's dashboard.
    gender_idx = @survey.cards.find_index { |c| c["demographic"] && c["type"] == "multiple_choice" }
    token = SecureRandom.uuid

    post submit_survey_path(@survey.publish_token),
         params: { session_token: token,
                   answers: { "0" => { "value" => "Yes" },
                              gender_idx.to_s => { "value" => "<script>alert(1)</script>" } } }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_nil Response.find_by!(session_token: token).demographic_gender
  end

  test "an implausible birth year is refused" do
    birth_idx = @survey.cards.find_index { |c| c["demographic"] && c["input"] == "month" }
    token = SecureRandom.uuid

    post submit_survey_path(@survey.publish_token),
         params: { session_token: token,
                   answers: { "0" => { "value" => "Yes" },
                              birth_idx.to_s => { "value" => "1066-01" } } }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_nil Response.find_by!(session_token: token).demographic_birth_year
  end
end
