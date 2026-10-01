require "test_helper"

# Dwell time — how long a respondent spends on each question — from the save
# that carries it to the surfaces that report it: the results page's chip, the
# shared results page, and the CSV. The browser measurement itself is covered
# by test/system/player_dwell_time_test.rb; this is everything after the POST.
class DwellTimeTest < ActionDispatch::IntegrationTest
  MIN = Response::MIN_REGION_SAMPLE_SIZE

  def setup
    @org  = Organisation.create!(name: "O", slug: "dwl-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "dwl-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hi" },
               { "type" => "yes_no", "cid" => "c_a", "text" => "Like it?", "options" => %w[Yes No] },
               { "type" => "open_ended", "cid" => "c_b", "text" => "Why?" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    @token = SecureRandom.uuid
  end

  def post_json(path, body)
    post path, params: body.to_json, headers: { "Content-Type" => "application/json" }
  end

  def progress(answers: { "1" => { "value" => "Yes" } }, dwell: nil, token: @token)
    body = { session_token: token, answers: answers }
    body[:dwell] = dwell unless dwell.nil?
    post_json progress_survey_path(@survey.publish_token), body
  end

  def submit(answers: { "1" => { "value" => "Yes" } }, dwell: nil, token: @token)
    body = { session_token: token, answers: answers }
    body[:dwell] = dwell unless dwell.nil?
    post_json submit_survey_path(@survey.publish_token), body
  end

  def row(token = @token) = Response.find_by!(session_token: token)

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # ── The save ───────────────────────────────────────────────────────────────

  test "progress stores the dwell per card, and submit carries the final totals" do
    progress(dwell: { "1" => 4200 })
    assert_response :success
    assert_equal({ "1" => 4200 }, row.dwell_ms)

    submit(answers: { "1" => { "value" => "Yes" }, "2" => { "value" => "Because" } }, dwell: { "1" => 4200, "2" => 9100 })
    assert_response :success
    assert_equal({ "1" => 4200, "2" => 9100 }, row.dwell_ms)
    assert_equal "completed", row.status
  end

  test "a figure only ever grows: a replay carrying an older total cannot shrink it" do
    progress(dwell: { "1" => 9000 })
    progress(dwell: { "1" => 3000 }) # the offline queue draining an earlier save
    assert_equal({ "1" => 9000 }, row.dwell_ms)

    progress(dwell: { "1" => 12_000 })
    assert_equal({ "1" => 12_000 }, row.dwell_ms)

    progress # a save with no dwell at all leaves it standing
    assert_equal({ "1" => 12_000 }, row.dwell_ms)
  end

  test "the endpoint is public JSON, so dwell is bounded and never coerced" do
    progress(dwell: { "1" => 1e12, "2" => "abc", "7" => 500, "x" => 500, "0" => -1, "2.5" => 9 })
    assert_response :success
    assert_equal({ "1" => Response::DWELL_CAP_MS }, row.dwell_ms)

    progress(dwell: [ 1, 2, 3 ])
    assert_response :success
    assert_equal({ "1" => Response::DWELL_CAP_MS }, row.dwell_ms, "a non-object is ignored, not an error")
  end

  test "dwell on a card is not an answer to it" do
    progress(answers: {}, dwell: { "1" => 8000, "2" => 3000 })
    assert_response :success
    assert_not row.answered
    assert_equal({ "1" => 8000, "2" => 3000 }, row.dwell_ms)
  end

  test "a quiz check saves the dwell too" do
    quiz = @org.surveys.create!(
      title: "Q", theme: "Q", audience_age: "all", key_insight: "k", quiz: true,
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "q1", "text" => "2+2?", "options" => %w[3 4], "correct" => "4" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    post_json grade_survey_path(quiz.publish_token),
              { session_token: @token, card_index: 0, answers: { "0" => { "value" => "4" } }, dwell: { "0" => 6500 } }
    assert_response :success
    assert JSON.parse(response.body)["graded"]
    assert_equal({ "0" => 6500 }, row.dwell_ms)
  end

  test "declining consent purges the dwell with the answers, and a later save cannot put it back" do
    progress(dwell: { "1" => 4200 })
    post_json consent_survey_path(@survey.publish_token), { session_token: @token, agreed: false }
    assert_response :success
    assert_equal({}, row.dwell_ms)

    progress(dwell: { "1" => 4200 })
    assert_response :forbidden
    assert_equal({}, row.dwell_ms)
  end

  # ── The results page ───────────────────────────────────────────────────────

  def seed_answered(count, dwell_ms:)
    count.times do |i|
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed",
        answers: { "1" => { "value" => "Yes" }, "2" => { "value" => "Because" } },
        dwell_ms: { "1" => dwell_ms[i % dwell_ms.size], "2" => 1_500 }
      )
    end
  end

  test "the results page shows each question's median time to answer" do
    seed_answered(MIN, dwell_ms: [ 4000, 12_000, 20_000, 30_000, 120_000 ])
    sign_in
    get survey_results_path(@survey)
    assert_response :success

    assert_select "#rc-card-1 .rc-dwell", text: /20s to answer/
    assert_select "#rc-card-1 .rc-dwell[title*='#{MIN} respondents who answered']"
    assert_select "#rc-card-1 .rc-dwell[title*='mean 37s']"
    assert_select "#rc-card-2 .rc-dwell", text: /2s to answer/
    assert_select "#rc-card-0 .rc-dwell", { count: 0 }, "the welcome card is not a question"
  end

  test "a question nobody was timed on shows no chip rather than a zero" do
    MIN.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                                answers: { "1" => { "value" => "Yes" } })
    end
    sign_in
    get survey_results_path(@survey)
    assert_response :success
    assert_select ".rc-dwell", count: 0
  end

  test "the figure follows the page's segment" do
    seed_answered(MIN, dwell_ms: [ 4000 ])
    link = @survey.survey_links.create!(name: "Slow readers", slug: "slow-#{SecureRandom.hex(2)}")
    MIN.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", survey_link: link,
                                answers: { "1" => { "value" => "No" } }, dwell_ms: { "1" => 60_000 })
    end
    sign_in

    get survey_results_path(@survey, segment: "link_#{link.id}")
    assert_select "#rc-card-1 .rc-dwell", text: /1m 00s to answer/

    # Overall: five at 4s and five at a minute — the median sits between.
    get survey_results_path(@survey)
    assert_select "#rc-card-1 .rc-dwell", text: /32s to answer/
  end

  test "the shared results page carries the same aggregate timing" do
    seed_answered(MIN, dwell_ms: [ 8000 ])
    sign_in
    post results_share_survey_path(@survey)
    token = @survey.reload.results_share_token
    delete session_path

    get shared_results_path(token)
    assert_response :success
    assert_select "#rc-card-1 .rc-dwell", text: /8s to answer/
  end

  # ── The CSV ────────────────────────────────────────────────────────────────

  test "the responses CSV carries a dwell column per question" do
    progress(dwell: { "1" => 4200 })
    submit(answers: { "1" => { "value" => "Yes" }, "2" => { "value" => "Because" } }, dwell: { "1" => 4200, "2" => 9149 })
    sign_in

    get survey_results_export_path(@survey, kind: "responses")
    rows = CSV.parse(response.body.delete_prefix("\xEF\xBB\xBF".b.force_encoding("UTF-8")))
    like = rows.first.index("Dwell time (seconds): Like it?")
    why  = rows.first.index("Dwell time (seconds): Why?")
    assert like && why, "one dwell column per question"
    assert_equal [ "4.2", "9.1" ], [ rows.last[like], rows.last[why] ]

    get survey_results_export_path(@survey, kind: "summary")
    rows = CSV.parse(response.body.delete_prefix("\xEF\xBB\xBF".b.force_encoding("UTF-8")))
    median = rows.find { |r| r[2] == "Like it?" && r[3] == "Time to answer — median (seconds)" }
    assert_equal [ "4.2", nil, "1" ], median[4, 3]
  end
end
