require "test_helper"

# Shareable results/report links (3.1): a public, read-only /results/:token
# view of a Verto's aggregated results, and the owner-side ResultsSharesController
# that mints/pauses/resets/revokes the token. The highest-stakes assertions
# here are the PII exclusions and the never-spends-AI guarantees — see
# SharedResultsController's own comment for the full posture.
class SharedResultsTest < ActionDispatch::IntegrationTest
  MIN = Response::MIN_REGION_SAMPLE_SIZE
  MD  = "## Executive summary\n\nMost respondents picked Blue.\n".freeze

  def setup
    @user = User.create!(name: "U", email_address: "sr-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "sr-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Colours", theme: "Colours", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Colour?", "options" => %w[Blue Green] },
        { "type" => "open_ended", "cid" => "c_oe", "text" => "Tell us more" },
        { "type" => "contact_form", "cid" => "c_cf", "text" => "Contact" }
      ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def sign_in(user = @user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # One response carrying every kind of thing the shared page must redact:
  # an "other" free-text on the closed question, an open_ended answer, and a
  # contact_form submission — each with a distinctive, greppable value. The
  # contact card is retired and collects nothing new, but a Verto that ran
  # while it was live still holds its leads, and a share link must still
  # withhold them.
  def add_secret_response
    @survey.responses.create!(
      session_token: SecureRandom.uuid, status: "completed",
      answers: {
        "1" => { "value" => "Blue", "other" => "TOPSECRET_OTHER_TEXT" },
        "2" => { "value" => "TOPSECRET_OPEN_ENDED_TEXT" },
        "3" => { "value" => { "name" => "Jane Secretname", "email" => "jane@secret.example",
                              "company" => "SecretCo", "industry" => "Testing" } }
      }
    )
  end

  # wave: nil reproduces the exact create! this helper always issued (the
  # column then takes its default, nil) — existing callers predate waves and
  # are unaffected. Pass an explicit wave to land responses inside it, same
  # as PlayerController#find_or_init_response would at write time.
  def add_plain_responses(count, value: "Blue", wave: nil)
    count.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                                answers: { "1" => { "value" => value } },
                                survey_wave_id: wave&.id)
    end
  end

  def enable_share!
    sign_in
    post results_share_survey_path(@survey)
    @survey.reload.results_share_token.tap { |t| assert t.present?, "enabling must mint a token" }
  end

  # ── Token resolution & lifecycle ──────────────────────────────────────────

  test "an unknown token 404s" do
    get shared_results_path("nope")
    assert_response :not_found
  end

  test "a survey that never enabled sharing has no reachable token" do
    assert_nil @survey.results_share_token
    get shared_results_path(SecureRandom.urlsafe_base64(18))
    assert_response :not_found
  end

  test "enabling mints a token that resolves, unauthenticated" do
    token = enable_share!
    delete session_path

    get shared_results_path(token)
    assert_response :success
    assert_match "Colours", response.body
  end

  test "pausing takes the page down; resuming brings back the SAME url" do
    token = enable_share!
    patch results_share_survey_path(@survey), params: { active: "0" }
    delete session_path

    get shared_results_path(token)
    assert_response :not_found

    sign_in
    patch results_share_survey_path(@survey), params: { active: "1" }
    delete session_path

    get shared_results_path(token)
    assert_response :success
  end

  test "reset mints a new token and kills the old one immediately" do
    old_token = enable_share!
    post results_share_survey_path(@survey), params: { reset: "1" }
    new_token = @survey.reload.results_share_token

    refute_equal old_token, new_token
    delete session_path

    get shared_results_path(old_token)
    assert_response :not_found
    get shared_results_path(new_token)
    assert_response :success
  end

  test "revoking destroys the token entirely — re-enabling mints a different one" do
    token = enable_share!
    delete results_share_survey_path(@survey)
    assert_nil @survey.reload.results_share_token
    delete session_path

    get shared_results_path(token)
    assert_response :not_found
  end

  test "a deleted survey's share link is 410, not 404" do
    token = enable_share!
    @survey.archive!
    delete session_path

    get shared_results_path(token)
    assert_response :gone
  end

  test "only the owning organisation can mint or change a results share" do
    other = User.create!(name: "O2", email_address: "sr2-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    Organisation.create!(name: "Other", slug: "sr2-#{SecureRandom.hex(3)}")
                .memberships.create!(user: other, role: "admin")
    post session_path, params: { email_address: other.email_address, password: "verylongpassword" }

    post results_share_survey_path(@survey)
    assert_response :not_found
    assert_nil @survey.reload.results_share_token
  end

  test "a non-admin cannot enable results sharing" do
    member = User.create!(name: "M", email_address: "sr3-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: member, role: "member")
    post session_path, params: { email_address: member.email_address, password: "verylongpassword" }

    post results_share_survey_path(@survey)
    assert_nil @survey.reload.results_share_token
  end

  # ── PII posture ────────────────────────────────────────────────────────────

  test "shows closed-question distributions and counts, but hides open text, other-text and contact details" do
    add_secret_response
    token = enable_share!
    delete session_path

    get shared_results_path(token)
    assert_response :success
    # The closed question's own distribution is exactly what a shared link is for.
    assert_match "Colour?", response.body
    assert_match "Blue", response.body

    # None of the three free-text carriers may leak, in any form.
    assert_no_match "TOPSECRET_OTHER_TEXT", response.body
    assert_no_match "TOPSECRET_OPEN_ENDED_TEXT", response.body
    assert_no_match "Jane Secretname", response.body
    assert_no_match "jane@secret.example", response.body
    assert_no_match "SecretCo", response.body
    # Redacted sections still say *something* exists, just not what it says.
    assert_match "hidden on shared links", response.body
  end

  test "the same Verto's OWN results page still shows the free text — only the shared copy redacts it" do
    add_secret_response
    sign_in

    get survey_results_path(@survey)
    assert_response :success
    assert_match "TOPSECRET_OTHER_TEXT", response.body
    assert_match "TOPSECRET_OPEN_ENDED_TEXT", response.body
    assert_match "Jane Secretname", response.body
  end

  test "carries no turbo_stream_from, live-results element, leaderboard, exports, chat or report-edit controls" do
    @survey.update!(leaderboard_enabled: true)
    token = enable_share!
    delete session_path

    get shared_results_path(token)
    assert_response :success
    assert_select "turbo-cable-stream-source", false
    assert_select "#results-live", false
    # Not the bare words "Leaderboard" / "Ask Verto" — window.I18N dumps a
    # leaderboard_title key and the whole ask: namespace on every page
    # regardless of context, so either alone would be a false positive here.
    # The trophy-emoji heading and the chat panel's own controller are what
    # only the actual partials render.
    refute_match "🏆 Leaderboard", response.body
    assert_select "[data-controller='results-chat']", false
    assert_select ".results-export-menu", false
    assert_select "[data-controller='report-export']", false
    refute_match "survey_results_export", response.body
  end

  test "sets the noindex header — the token IS the authorisation" do
    token = enable_share!
    delete session_path

    get shared_results_path(token)
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "a segment below the small-cell threshold falls back to overall, same as the owner's page" do
    add_plain_responses(MIN - 1, value: "Green")
    token = enable_share!
    delete session_path

    # There's no per-gender segment id to link to (suppressed), so asking for
    # one that doesn't exist must land safely on overall rather than erroring.
    get shared_results_path(token, segment: "gender_nonexistent")
    assert_response :success
  end

  # Combinations ride the same seam, so the public page gets them with the same
  # small-cell rule — a stranger with the token can combine slices, and the
  # cell they land on is withheld under the line exactly as it is for the
  # owner (results_combinations_test.rb has the rule itself).
  test "segments combine on the shared page, and a small cell is withheld" do
    seed = ->(n, country, gender) do
      n.times do
        @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                                  region_country: country, demographic_gender: gender,
                                  answers: { "1" => { "value" => "Blue" } })
      end
    end
    seed.call(MIN, "GB", "Female")
    seed.call(MIN, "GB", "Male")
    seed.call(1, "FR", "Male")
    seed.call(MIN - 1, "FR", "Female")
    token = enable_share!
    delete session_path

    get shared_results_path(token, segment: "region_GB,gender_female")
    assert_response :success
    assert_match "#{MIN} responses", response.body
    # The date-window chips are seg-pills too; a selected PART's pill is the
    # one whose href leads to the selection without it.
    assert_select "a.seg-pill[aria-current='true'][href*='segment=']", 2
    # A pill of a third slice ADDS itself; a selected part's pill removes it.
    assert_select "a.seg-pill[href*='segment=region_GB%2Cgender_female%2Cgender_male']"
    assert_select "a.seg-pill[href='#{shared_results_path(token, segment: 'gender_female')}']"

    get shared_results_path(token, segment: "region_FR,gender_male")
    assert_response :success
    assert_select ".rc-suppressed", 1
    assert_select ".rc-card", 1
    assert_match "Fewer than #{MIN} responses", response.body
    assert_no_match(/\b1 response\b/, response.body, "the number itself is what is withheld")
  end

  # Waves ride the exact same ResolvesResultSegments seam as region/demographic
  # segments (see resolves_result_segments.rb) — this is that seam's one
  # cross-feature check, proving a shared-results viewer sees wave pills too,
  # with zero SharedResultsController changes required for it.
  test "wave segments appear on the shared page too, for free" do
    add_plain_responses(2, value: "Blue")
    @survey.start_next_wave!
    add_plain_responses(3, value: "Green", wave: @survey.current_wave)
    token = enable_share!
    delete session_path

    get shared_results_path(token)
    assert_response :success
    assert_select "a.seg-pill[href*='segment=wave_1']"
    assert_select "a.seg-pill[href*='segment=wave_2']"

    get shared_results_path(token, segment: "wave_2")
    assert_response :success
    assert_match "3 responses", response.body # wave 2's own count, not the whole Verto's 5
  end

  # Custom links are the one segment kind the public page does NOT get: a
  # link's name is the owner's internal label for an audience ("RA Sam"), and
  # the shared token is for strangers. An unknown segment id falls back to
  # Overall, so a guessed link_N URL shows nothing extra either.
  test "custom-link segments stay off the shared page" do
    link = @survey.survey_links.create!(name: "RA Sam", slug: "ra-sam-#{SecureRandom.hex(2)}")
    add_plain_responses(2, value: "Blue")
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                              survey_link: link, answers: { "1" => { "type" => "multiple_choice", "value" => "Green" } })
    token = enable_share!
    delete session_path

    get shared_results_path(token)
    assert_response :success
    assert_no_match(/RA Sam/, response.body)
    assert_select "a.seg-pill[href*='segment=link_']", false

    get shared_results_path(token, segment: "link_#{link.id}")
    assert_response :success
    assert_no_match(/RA Sam/, response.body)
    assert_match "3 responses", response.body, "falls back to Overall — every response, not the link's batch"

    sign_in
    get survey_results_path(@survey)
    assert_match "RA Sam", response.body, "the owner's own page still has the pill"
  end

  # ── Report: cached-only, never generates ───────────────────────────────────

  test "the report page 404s when there's no cached report yet" do
    token = enable_share!
    delete session_path

    get shared_results_report_path(token)
    assert_response :not_found
  end

  test "the report page renders cached markdown and NEVER calls the generator" do
    @survey.update_columns(results_report: MD, results_report_response_count: 0)
    token = enable_share!
    delete session_path

    stub_method(ResultsReportGenerator, :call, ->(**) { raise "must never generate for a shared viewer" }) do
      get shared_results_report_path(token)
    end
    assert_response :success
    assert_match "Executive summary", response.body
  end

  test "create_render refuses when there's no cached report" do
    token = enable_share!
    delete session_path

    post shared_results_renders_path(token)
    assert_response :unprocessable_entity
    assert_not JSON.parse(response.body)["ok"]
  end

  test "create_render builds a real PDF from the cached report via the background job" do
    @survey.update_columns(results_report: MD, results_report_response_count: 0)
    token = enable_share!
    delete session_path

    stub_method(ResultsReportGenerator, :call, ->(**) { raise "must never generate for a shared viewer" }) do
      perform_enqueued_jobs { post shared_results_renders_path(token) }
    end
    assert_response :success
    poll_url = JSON.parse(response.body)["poll_url"]

    get poll_url
    body = JSON.parse(response.body)
    assert_equal "succeeded", body["status"]

    get body["download_url"]
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_equal "%PDF", response.body[0, 4]
  end

  test "a shared render never regenerates even when the response count has drifted (stale cache)" do
    # results_report_response_count deliberately mismatches the real completed
    # count — results_report_markdown would treat this as stale and regenerate
    # for a creator's own download. A shared request must use the cached text
    # verbatim regardless.
    add_plain_responses(3)
    @survey.update_columns(results_report: MD, results_report_response_count: 999)
    token = enable_share!
    delete session_path

    stub_method(ResultsReportGenerator, :call, ->(**) { raise "a shared render must never trigger AI spend" }) do
      perform_enqueued_jobs { post shared_results_renders_path(token) }
    end
    assert_response :success
    poll_url = JSON.parse(response.body)["poll_url"]

    get poll_url
    assert_equal "succeeded", JSON.parse(response.body)["status"]
  end

  test "create_render dedupes: a second request while one is already running reuses it" do
    @survey.update_columns(results_report: MD, results_report_response_count: 0)
    token = enable_share!
    delete session_path

    # Don't perform_enqueued_jobs here — the first render stays "pending" so
    # the second request has something in-flight to find and reuse.
    post shared_results_renders_path(token)
    first_id = JSON.parse(response.body)["id"]

    post shared_results_renders_path(token)
    second_id = JSON.parse(response.body)["id"]

    assert_equal first_id, second_id, "a second request should reuse the in-flight render, not queue another"
    assert_equal 1, @survey.report_renders.count
  end

  test "render_status and render_download refuse an id that belongs to a different survey's token" do
    @survey.update_columns(results_report: MD, results_report_response_count: 0)
    token = enable_share!

    other_survey = @org.surveys.create!(title: "Y", theme: "Y", audience_age: "all", key_insight: "k",
                                        default_locale: "en", locales: [ "en" ], cards: [])
    other_render = other_survey.report_renders.create!(user: @user)
    delete session_path

    get shared_results_render_path(token, other_render.id)
    assert_response :not_found
  end

  test "a paused share also takes down the report and render endpoints, not just the main page" do
    @survey.update_columns(results_report: MD, results_report_response_count: 0)
    token = enable_share!
    patch results_share_survey_path(@survey), params: { active: "0" }
    delete session_path

    get shared_results_report_path(token)
    assert_response :not_found
    post shared_results_renders_path(token)
    assert_response :not_found
  end
end
