require "test_helper"

# Live results: the response tally moves as answers land, without re-running the
# aggregation for every viewer on every submission.
class ResultsLiveTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "O", slug: "live-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "live-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def answered_response(status: "completed")
    @survey.responses.create!(session_token: SecureRandom.uuid, status: status,
                              answers: { "0" => { "value" => "Yes" } })
  end

  test "the results page subscribes and renders the live tally" do
    answered_response
    sign_in

    get survey_results_path(@survey)
    assert_response :success
    assert_select "#results-live"
    assert_select "turbo-cable-stream-source"
  end

  test "the tally counts responders and completions" do
    answered_response(status: "completed")
    answered_response(status: "started")

    counts = ResultsActivity.counts_for(@survey)
    assert_equal 2, counts[:responders]
    assert_equal 1, counts[:completed]
  end

  test "an unanswered session is not counted or announced" do
    # Someone who opened the link and left. Not a response, and not news.
    assert_no_changes -> { ResultsActivity.counts_for(@survey)[:responders] } do
      @survey.responses.create!(session_token: SecureRandom.uuid, status: "started", answers: {})
    end
  end

  test "a response broadcasts when it first becomes a responder" do
    resp = @survey.responses.create!(session_token: SecureRandom.uuid, status: "started", answers: {})

    assert_broadcasts_on_results do
      resp.update!(answers: { "0" => { "value" => "Yes" } })
    end
  end

  test "the degrade switch sheds the live tally but not the leaderboard refresh" do
    resp = @survey.responses.create!(session_token: SecureRandom.uuid, status: "started", answers: {})

    ENV["DISABLE_RESULTS_BROADCAST"] = "1"
    assert_no_broadcasts_on_results do
      resp.update!(answers: { "0" => { "value" => "Yes" } })
    end
  ensure
    ENV.delete("DISABLE_RESULTS_BROADCAST")
  end

  test "a response broadcasts when it completes" do
    resp = answered_response(status: "started")

    assert_broadcasts_on_results do
      resp.update!(status: "completed")
    end
  end

  test "mid-survey autosaves do not broadcast" do
    # The point of gating on the answered/status transitions: /progress writes on
    # every card, and broadcasting each one would put a burst of renders on the
    # instance for information that hasn't changed.
    resp = answered_response(status: "started")

    assert_no_broadcasts_on_results do
      resp.update!(answers: { "0" => { "value" => "No" } })
      resp.update!(locale: "fr")
      resp.update!(region_country: "GB")
    end
  end

  test "a broadcast failure cannot break storing a respondent's answers" do
    # A live counter is a nicety; losing an answer is not.
    stub_method(ResultsActivity, :broadcast, ->(*) { raise "cable down" }) do
      resp = nil
      assert_nothing_raised { resp = answered_response }
      assert resp.persisted?
      assert_equal 1, @survey.responses.where(answered: true).count
    end
  end

  test "the broadcast renders a stream that replaces the live tally" do
    # The gating tests above stub the broadcast, so this one runs it for real —
    # otherwise a broken partial or a renamed target would sail through.
    answered_response
    captured = nil
    stub_method(Turbo::StreamsChannel, :broadcast_replace_to, ->(*streamables, **opts) { captured = opts }) do
      ResultsActivity.broadcast(@survey)
    end

    assert_equal "results-live", captured[:target]
    assert_equal 1, captured[:locals][:responders]
    assert captured[:locals][:live], "a broadcast is the 'these just changed' render"

    html = ApplicationController.render(partial: captured[:partial], locals: captured[:locals])
    assert_includes html, "results-live"
    assert_includes html, "Refresh breakdown"
  end

  test "a segmented view keeps its own filtered count" do
    # A broadcast carries whole-Verto totals, which would contradict a filtered
    # view — so the segmented page opts out of the live tally rather than
    # showing a number that doesn't match its charts. Enough responses for GB
    # to clear the small-cell line, so it is a segment to open at all.
    Response::MIN_REGION_SAMPLE_SIZE.times { answered_response }
    @survey.responses.update_all(region_country: "GB", region_label: "London")
    sign_in

    get survey_results_path(@survey, segment: "region_GB")
    assert_response :success
    assert_select "#results-live", false
  end

  private

  # Count calls to the broadcast rather than inspecting Turbo's pubsub keys —
  # what these tests are about is WHICH saves announce themselves, not how
  # turbo-rails names a stream internally.
  def broadcasts_during
    # Only jobs enqueued INSIDE the block count — setup writes queue their own
    # coalesced broadcasts, which are not the saves under test.
    clear_enqueued_jobs
    count = 0
    stub_method(ResultsActivity, :broadcast, ->(*) { count += 1 }) do
      yield
      # The transition enqueues a coalesced BroadcastResultsActivityJob; the
      # broadcast itself happens when the job performs.
      drain_enqueued_jobs
    end
    count
  end

  def assert_broadcasts_on_results(&block)
    assert_operator broadcasts_during(&block), :>=, 1, "expected a results broadcast"
  end

  def assert_no_broadcasts_on_results(&block)
    assert_equal 0, broadcasts_during(&block), "expected no results broadcast"
  end
end
