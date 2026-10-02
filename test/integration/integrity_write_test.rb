require "test_helper"

# The integrity signals from the save that carries them to the score stored on
# the row, and the nightly job that keeps those scores current. The browser
# side is test/system/player_integrity_signals_test.rb.
class IntegrityWriteTest < ActionDispatch::IntegrationTest
  CHOICE = %w[Never Rarely Sometimes Often Always].freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "iw-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hi" } ] +
             Array.new(4) { |i| { "type" => "range", "cid" => "r#{i}", "text" => "Scale #{i}", "options" => CHOICE } },
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    @token = SecureRandom.uuid
  end

  def answers(values = [ 0, 1, 2, 3 ]) = values.each_with_index.to_h { |v, i| [ (i + 1).to_s, { "value" => v } ] }

  def post_json(path, body)
    post path, params: body.to_json,
         headers: { "Content-Type" => "application/json",
                    "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
                                    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1" }
  end

  def save(kind, answers:, integrity: nil, dwell: nil)
    body = { session_token: @token, answers: answers }
    body[:integrity] = integrity unless integrity.nil?
    body[:dwell] = dwell unless dwell.nil?
    post_json(kind == :submit ? submit_survey_path(@survey.publish_token) : progress_survey_path(@survey.publish_token), body)
    assert_response :success
    Response.find_by!(session_token: @token)
  end

  test "signals ride the save, are bounded, and the response is scored as it is saved" do
    row = save(:submit, answers: answers, dwell: (1..4).to_h { |i| [ i.to_s, 8_000 ] },
               integrity: { v: 1, untouched: [ "2", "0", "99", "x" ], seen: { "1" => 1, "2" => 7 },
                            changes: { "1" => 3, "3" => -1 }, offline: true, junk: "dropped" })

    assert_equal 1, row.integrity["v"]
    assert_equal [ "2" ], row.integrity["untouched"], "only answered range cards the deck has"
    assert_equal({ "1" => 1 }, row.integrity["seen"])
    assert_equal({ "1" => 3 }, row.integrity["changes"])
    assert_equal true, row.integrity["offline"]
    assert_not row.integrity.key?("junk")

    assert_equal ResponseIntegrity::VERSION, row.integrity_version
    assert_equal "high", row.integrity_band, "considered times, varied answers, one slider of four untouched"
    assert_operator row.integrity_score, :>=, ResponseIntegrity::HIGH_FROM
  end

  test "a later save is the truth for the cards it answers, and never un-reaches a list" do
    save(:progress, answers: answers.slice("1", "2"), integrity: { v: 1, untouched: [ "1", "2" ], seen: { "1" => 1 } })
    row = save(:submit, answers: answers, integrity: { v: 1, untouched: [ "4" ], seen: { "1" => 0 } })

    assert_equal [ "4" ], row.integrity["untouched"], "cards 1 and 2 were touched before the submit"
    assert_equal({ "1" => 1 }, row.integrity["seen"])
  end

  test "a player save after launch that sends no signals is unverified, not passed" do
    travel_to ResponseIntegrity::SIGNALS_SINCE + 1.day do
      row = save(:submit, answers: answers)
      assert_equal({}, row.integrity)
      assert_equal "unverified", row.integrity_band
      assert_nil row.integrity_score
    end
  end

  test "an answer flood with every slider untouched and no time taken scores Low" do
    row = save(:submit, answers: answers([ 2, 2, 2, 2 ]), dwell: (1..4).to_h { |i| [ i.to_s, 150 ] },
               integrity: { v: 1, untouched: %w[1 2 3 4] })
    assert_equal "low", row.integrity_band
  end

  test "declining consent clears the signals and the score with everything else" do
    save(:progress, answers: answers.slice("1"), integrity: { v: 1, changes: { "1" => 2 } })
    post_json consent_survey_path(@survey.publish_token), { session_token: @token, agreed: false }
    assert_response :success

    row = Response.find_by!(session_token: @token)
    assert_equal({}, row.integrity)
    assert_nil row.integrity_score
    assert_equal "unscored", row.integrity_band
  end

  test "the subject-access export carries the band, the score and the signals" do
    row = save(:submit, answers: answers, dwell: (1..4).to_h { |i| [ i.to_s, 8_000 ] }, integrity: { v: 1, changes: { "1" => 1 } })
    data = RespondentDataExport.call(survey: @survey, responses: Response.where(id: row.id))
    block = data["responses"].first["integrity"]

    assert_equal row.integrity_band, block["band"]
    assert_equal row.integrity_score, block["score"]
    assert_equal({ "1" => 1 }, block["signals"]["changes"])
  end

  # ── the nightly job ─────────────────────────────────────────────────────────

  test "the job bands responses without signals by SQL, refreshes the baseline, and re-scores against it" do
    travel_to ResponseIntegrity::SIGNALS_SINCE + 2.days do
      imported = @survey.responses.create!(session_token: "imp-1", answers: answers, created_at: 1.day.ago)
      silent   = @survey.responses.create!(session_token: SecureRandom.uuid, answers: answers, device_kind: "phone")
      timed = Array.new(ResponseIntegrity::COHORT_MIN_ANSWERS) do
        @survey.responses.create!(session_token: SecureRandom.uuid, answers: answers, device_kind: "phone",
                                  dwell_ms: (1..4).to_h { |i| [ i.to_s, 20_000 ] }, integrity: { "v" => 1 })
      end
      quick = @survey.responses.create!(session_token: SecureRandom.uuid, answers: answers, device_kind: "phone",
                                        dwell_ms: (1..4).to_h { |i| [ i.to_s, 3_000 ] }, integrity: { "v" => 1 })

      RescoreIntegrityJob.perform_now(@survey.id)

      assert_equal "unscored",   imported.reload.integrity_band
      assert_equal "unverified", silent.reload.integrity_band
      assert_equal 20_000, @survey.reload.integrity_baseline.dig("cards", "1", "median_ms")
      assert_equal "high", timed.first.reload.integrity_band
      assert_equal 0.0, ResponseIntegrity.score(quick.reload, survey: @survey).components[:speed],
                   "3s against a 20s median is under a quarter of it, though over the reading floor"
    end
  end

  test "refresh_all! enqueues only Vertos that collected something in the last day" do
    quiet = @org.surveys.create!(title: "Q", theme: "Q", audience_age: "all", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    quiet.responses.create!(session_token: SecureRandom.uuid, answers: {}, updated_at: 3.days.ago, created_at: 3.days.ago)
    @survey.responses.create!(session_token: SecureRandom.uuid, answers: answers)

    assert_enqueued_with(job: RescoreIntegrityJob, args: [ @survey.id ]) { RescoreIntegrityJob.refresh_all! }
    assert_no_enqueued_jobs(only: RescoreIntegrityJob) { RescoreIntegrityJob.refresh_all!(since: 1.minute.from_now) }
  end
end
