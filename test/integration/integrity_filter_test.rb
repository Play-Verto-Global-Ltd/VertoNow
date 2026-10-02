require "test_helper"

# The creator's view of the Verto Integrity Score: the Integrity menu's band
# split, and the admin's switch that leaves Low and unverified responses out
# of the results — the page, its exports, the AI readings, the public results
# link and the partner page — with a notice wherever it has. All of it inert
# until ResponseIntegrity.visible?, which is how shadow mode stays shadow.
class IntegrityFilterTest < ActionDispatch::IntegrationTest
  MIN   = Response::MIN_REGION_SAMPLE_SIZE
  CARDS = [ { "type" => "multiple_choice", "cid" => "c0", "text" => "Colour?", "options" => %w[Blue Green] } ].freeze

  def setup
    @org  = Organisation.create!(name: "O", slug: "if-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "if-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @user.verify_email!
    @membership = @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS,
                                   publish_token: SecureRandom.hex(8), published_at: Time.current)
    # MIN careful Blues, MIN unscored Blues from before scoring, and three
    # Greens that are Low or unverified — the only Greens there are, so
    # whether they count is legible on every surface.
    add(MIN, "Blue", band: "high")
    add(MIN, "Blue", band: "unscored")
    add(2, "Green", band: "low")
    add(1, "Green", band: "unverified")
    @previous = ENV["INTEGRITY_SCORES_VISIBLE"]
    ENV["INTEGRITY_SCORES_VISIBLE"] = "1"
    sign_in
  end

  def teardown
    ENV["INTEGRITY_SCORES_VISIBLE"] = @previous
  end

  def add(count, value, band:)
    count.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                                answers: { "0" => { "value" => value } }, integrity_band: band)
    end
  end

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def exclude!(on = true)
    patch integrity_filter_survey_path(@survey), params: { exclude: on ? "1" : "0" }
    assert_redirected_to survey_results_path(@survey)
    @survey.reload
  end

  test "the menu shows the band split, and the switch counts what it would leave out" do
    get survey_results_path(@survey)
    assert_response :success

    assert_select ".rh-integrity-menu summary", text: /Integrity/
    assert_select ".rh-integrity-band--high .rh-integrity-count", text: MIN.to_s
    assert_select ".rh-integrity-band--unscored .rh-integrity-count", text: MIN.to_s
    assert_select ".rh-integrity-band--low .rh-integrity-count", text: "2"
    assert_select ".rh-integrity-headline", { text: /#{(MIN * 100.0 / (MIN + 3)).round}%.*of #{MIN + 3} scored/m },
                  "unscored responses are not part of the share — there is nothing in them to judge"
    assert_select "form[action=?] button", integrity_filter_survey_path(@survey), text: "Leave out Low responses (3)"
    assert_select ".rc-integrity-notice", 0
  end

  test "leaving Low out narrows every count on the page, and says so" do
    exclude!
    assert @survey.exclude_low_integrity?

    get survey_results_path(@survey)
    assert_select ".rc-integrity-notice", text: /Leaving out 3 Low and unverified responses/
    assert_select ".rh-integrity-menu summary.rh-pill--on"
    assert_select "form[action=?] button", integrity_filter_survey_path(@survey), text: "Put Low responses back"
    assert_no_match(/Green[^<]*<[^>]*>\s*[1-9]/, css_select(".rc-card").to_s, "no Green answer is counted")
    assert_equal ResultsActivity.counts_for(@survey)[:responders], 2 * MIN

    exclude!(false)
    get survey_results_path(@survey)
    assert_select ".rc-integrity-notice", 0
    assert_equal ResultsActivity.counts_for(@survey)[:responders], 2 * MIN + 3
  end

  test "the exports leave them out too, carry the band, and say so in the file's name" do
    get survey_results_export_path(@survey, kind: "responses")
    rows = CSV.parse(response.body.delete_prefix("﻿"))
    assert_equal "Integrity band", rows.first.last
    assert_equal 2 * MIN + 3, rows.size - 1
    assert_equal %w[high low unscored unverified], rows.drop(1).map(&:last).uniq.sort
    assert_no_match(/excluding-low/, response.headers["Content-Disposition"])

    exclude!
    get survey_results_export_path(@survey, kind: "responses")
    rows = CSV.parse(response.body.delete_prefix("﻿"))
    assert_equal 2 * MIN, rows.size - 1
    assert_equal %w[high unscored], rows.drop(1).map(&:last).uniq.sort
    assert_match(/responses-excluding-low/, response.headers["Content-Disposition"])
  end

  test "the public results link counts what the page counts, and says responses were left out" do
    @survey.update!(results_share_token: SecureRandom.urlsafe_base64(18))
    exclude!

    get shared_results_path(@survey.results_share_token)
    assert_response :success
    assert_select ".rc-integrity-notice", text: /leave out responses that were not given with care/
    assert_no_match(/Leaving out 3/, response.body, "the public page says that, not how many")
    assert_select ".rc-answers", text: /#{2 * MIN} answers/
  end

  test "the AI summary is written about the same responses, and re-written when the switch moves" do
    seen = []
    fake = Object.new
    fake.define_singleton_method(:call) { |survey:, aggregated:, total:, &blk| seen << total; blk.call("Summary of #{total}.") }
    stub_method(ResultsSummariser, :new, ->(*) { fake }) do
      get survey_results_summary_path(@survey)
      assert_equal "Summary of #{2 * MIN + 3}.", response.body
      exclude!
      get survey_results_summary_path(@survey)
      assert_equal "Summary of #{2 * MIN}.", response.body, "the cached summary was of different responses"
    end
    assert_equal [ 2 * MIN + 3, 2 * MIN ], seen
  end

  test "the respondent's own comparison is not the creator's filter" do
    exclude!
    payload = Class.new { include AggregatesSurveyResults }.new.send(:survey_results_payload, @survey)
    assert_equal 2 * MIN + 3, payload[:total_responses],
                 "the person who just answered compares with everyone who did"
  end

  test "only an admin can throw the switch" do
    @membership.update!(role: "member")
    patch integrity_filter_survey_path(@survey), params: { exclude: "1" }
    assert_not @survey.reload.exclude_low_integrity?

    get survey_results_path(@survey)
    assert_select "form[action=?]", integrity_filter_survey_path(@survey), 0
    assert_select ".rh-integrity-explain", text: /An admin can leave Low responses out/
  end

  test "in shadow mode there is no menu, no switch, no band column, and a stored switch changes nothing" do
    @survey.update!(exclude_low_integrity: true)
    ENV.delete("INTEGRITY_SCORES_VISIBLE")

    get survey_results_path(@survey)
    assert_select ".rh-integrity-menu", 0
    assert_select ".rc-integrity-notice", 0

    get survey_results_export_path(@survey, kind: "responses")
    rows = CSV.parse(response.body.delete_prefix("﻿"))
    assert_not_includes rows.first, "Integrity band"
    assert_equal 2 * MIN + 3, rows.size - 1

    patch integrity_filter_survey_path(@survey), params: { exclude: "0" }
    assert @survey.reload.exclude_low_integrity?, "the switch cannot be thrown blind"
  end
end
