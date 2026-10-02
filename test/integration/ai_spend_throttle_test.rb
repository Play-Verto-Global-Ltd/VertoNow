require "test_helper"

# The creator-facing AI endpoints had no throttle of any kind: the public player
# and the auth endpoints were rate-limited, but a signed-in user could queue
# unbounded paid generations (P0-4).
#
# Scope note, so these tests aren't read as proving more than they do: Rails'
# `rate_limit` resolves its store ONCE, at class-definition time, from
# ActionController::Base.cache_store. The suite runs on :null_store, so no
# `rate_limit` in this app can be exercised end-to-end here and swapping
# Rails.cache mid-test cannot reach it — see CacheStoreTest. What is testable is
# (a) the declaration coverage, which is what actually gets forgotten when a new
# AI endpoint is added, and (b) the daily cap, which is this app's own code and
# reads Rails.cache at call time.
class AiSpendThrottleTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "ai-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ai-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # ── Declaration coverage ────────────────────────────────────────────────

  test "every Claude-spending action in SurveysController is throttled" do
    # Hand-maintained on purpose: adding an AI endpoint should require a
    # deliberate decision about its limit, and this failing is the reminder.
    # update_audience_country spends when the Verto has both an audience
    # country and a Heritage card: it regenerates that card's options for the
    # new country.
    expected = %i[
      generate import_pdf import_manual import_google_form finalize_import
      create_blank resume_import generate_flow generate_card optimise_card
      moderate_image update_audience_country
    ]

    missing = expected - SurveysController.ai_throttled_actions
    assert_empty missing, "unthrottled AI endpoints: #{missing.join(', ')}"
  end

  test "the external-media endpoints are throttled too" do
    # Pexels rather than Anthropic — no money, but a quota worth not burning.
    assert_includes SurveysController.ai_throttled_actions, :pexels_search
    assert_includes SurveysController.ai_throttled_actions, :shuffle_assets
  end

  # A JSON client that can't tell "you are going too fast" from any other
  # failure will guess, and the media picker guessed wrong: it reported this
  # response as "Couldn't reach the stock service", which cost a creator a
  # morning of believing Pexels was down (18 Aug). The machine-readable code is
  # what lets the picker say what actually happened.
  test "a throttled JSON request carries a machine-readable code" do
    rendered = nil
    controller = SurveysController.new
    controller.define_singleton_method(:render) { |**kwargs| rendered = kwargs }
    controller.send(:deny_ai_request, :json, "slow down")

    assert_equal :too_many_requests, rendered[:status]
    assert_equal "rate_limited", rendered[:json][:code]
    assert_equal "slow down", rendered[:json][:error]
    refute rendered[:json][:ok]
  end

  # The stock endpoints spend nothing — Pexels is free — so the old copy
  # ("faster than we can pay for them") was both untrue and unhelpful, and the
  # 60/hour ceiling was low enough that a creator illustrating one Verto could
  # trip it just by working. The picker fires a search per keystroke pause, per
  # modal open, per media-tab switch and per Load-more page.
  test "the stock throttle is sized for real editing and says something true" do
    assert_no_match(/pay for them/i, SurveysController::STOCK_THROTTLE_MESSAGE,
                    "stock search costs nothing — don't tell creators otherwise")
    assert_match(/stock searches/i, SurveysController::STOCK_THROTTLE_MESSAGE)
  end

  # A turn here is up to MAX_TOOL_ROUNDS + 1 Sonnet calls against the per-Verto
  # chat's single Haiku call, so it takes BOTH guards — the rate limit and the
  # per-organisation daily cap that the older streaming endpoints skip.
  test "the Ask Verto tool loop is throttled and capped" do
    assert_includes AskMessagesController.ai_throttled_actions, :create
    assert_includes AskMessagesController.ai_capped_actions, :create,
      "the daily cap is the guard that bounds what reaches an invoice"

    assert_operator AskMessagesController::HOURLY_LIMIT, :<, 60,
      "a tool loop costs several Claude calls per message; its ceiling must be below the chat's"
  end

  test "the streaming and question-set generators are throttled" do
    assert_includes SurveyChatsController.ai_throttled_actions, :create
    assert_includes SurveySummariesController.ai_throttled_actions, :show
    assert_includes SurveySummariesController.ai_throttled_actions, :texts
    assert_includes PartnershipVertoSummariesController.ai_throttled_actions, :show
    assert_includes ResultsReportStreamsController.ai_throttled_actions, :show
    assert_includes CommonQuestionSetsController.ai_throttled_actions, :generate
  end

  test "throttling one controller does not leak into another" do
    # ai_throttled_actions is a class_attribute on a shared concern; if it were
    # accumulating on the module rather than per-controller, every controller
    # would report every other controller's actions.
    assert_not_includes SurveyChatsController.ai_throttled_actions, :generate_card
    assert_not_includes SurveysController.ai_throttled_actions, :texts
  end

  # ── The daily organisation cap ──────────────────────────────────────────

  test "the cap blocks a JSON endpoint once the organisation's day is spent" do
    with_cache_and_cap(cap: 3) do
      3.times do
        post moderate_image_survey_path(survey), params: { image: "" }.to_json,
             headers: json_headers
        assert_response :success
      end

      post moderate_image_survey_path(survey), params: { image: "" }.to_json,
           headers: json_headers
      assert_response :too_many_requests
      body = JSON.parse(response.body)
      assert_equal false, body["ok"]
      assert_match(/daily AI limit/, body["error"])
    end
  end

  test "the cap is per organisation, not per user" do
    other_user = User.create!(name: "U2", email_address: "ai2-#{SecureRandom.hex(3)}@test.com",
                              password: "verylongpassword")
    @org.memberships.create!(user: other_user, role: "admin")
    target = survey

    with_cache_and_cap(cap: 2) do
      2.times do
        post moderate_image_survey_path(target), params: { image: "" }.to_json, headers: json_headers
        assert_response :success
      end

      # A second seat in the same organisation spends the same budget — that's
      # the point of capping by organisation rather than by user.
      delete session_path
      post session_path, params: { email_address: other_user.email_address, password: "verylongpassword" }
      follow_redirect! if response.redirect?

      post moderate_image_survey_path(target), params: { image: "" }.to_json, headers: json_headers
      assert_response :too_many_requests
    end
  end

  test "one organisation's spend does not count against another's" do
    other_org = Organisation.create!(name: "O2", slug: "ai-other-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: @user, role: "admin")
    target = survey

    with_cache_and_cap(cap: 2) do
      2.times do
        post moderate_image_survey_path(target), params: { image: "" }.to_json, headers: json_headers
      end

      controller = SurveysController.new
      assert_not_equal controller.send(:ai_cap_key, @org),
                       controller.send(:ai_cap_key, other_org),
                       "each organisation must have its own daily counter"
    end
  end

  test "a cap of 0 disables the ceiling entirely" do
    with_cache_and_cap(cap: 0) do
      5.times do
        post moderate_image_survey_path(survey), params: { image: "" }.to_json, headers: json_headers
        assert_response :success
      end
    end
  end

  test "the counter is keyed to the UTC day" do
    controller = SurveysController.new
    key = controller.send(:ai_cap_key, @org)
    assert_match(/\Aai-daily-cap:#{@org.id}:#{Time.now.utc.to_date}\z/, key)
  end

  test "a cache that cannot count fails open rather than blocking every endpoint" do
    # :null_store — the suite's default — returns nil from increment. A spend
    # guard that breaks all AI work when the cache is misconfigured is worse
    # than one that doesn't count, so this must NOT throttle.
    ENV["AI_DAILY_GENERATION_CAP"] = "1"
    5.times do
      post moderate_image_survey_path(survey), params: { image: "" }.to_json, headers: json_headers
      assert_response :success
    end
  ensure
    ENV.delete("AI_DAILY_GENERATION_CAP")
  end

  private

  def survey
    @survey ||= @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults",
                                     key_insight: "k", default_locale: "en", locales: [ "en" ],
                                     cards: [])
  end

  def json_headers
    { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def with_cache_and_cap(cap:)
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:solid_cache_store)
    ENV["AI_DAILY_GENERATION_CAP"] = cap.to_s
    SolidCache::Entry.delete_all
    yield
  ensure
    ENV.delete("AI_DAILY_GENERATION_CAP")
    SolidCache::Entry.delete_all
    Rails.cache = previous_cache
  end
end
