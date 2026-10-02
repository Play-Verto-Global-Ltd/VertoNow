require "test_helper"

# The Flows panel's ✨ Generate modal posts here. Generation runs as a job now —
# FlowGenerator plus one translation call per secondary locale is up to six
# sequential Claude calls, which has no business on one of three Puma threads —
# so the POST enqueues and the editor polls FlowGenerationsController#show for
# the flow name plus each card's cid + rendered editor HTML. Nothing about the
# deck persists server-side: the client splices the cards and autosave saves them,
# the same contract as generate_card.
class GenerateFlowTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "genf-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "genf-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "T", theme: "Network", audience_age: "adults", key_insight: "regions",
      default_locale: "en", locales: [ "en" ], logic: true,
      cards: [ { "type" => "multiple_choice", "cid" => "c_hub", "text" => "Which region?", "options" => %w[UK UAE USA] } ])
  end

  def with_generator(impl)
    fake = Object.new
    fake.define_singleton_method(:call, &impl)
    FlowGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    FlowGenerator.singleton_class.remove_method(:new)
  end

  def post_flow(payload)
    post generate_survey_flow_path(@survey), params: payload.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  # Post, run the queued job, then poll — the whole round trip the editor makes.
  # Returns the poll response body.
  def generate_flow!(payload)
    post_flow(payload)
    queued = JSON.parse(response.body)
    return queued unless queued["ok"]

    perform_enqueued_jobs
    get queued["poll_url"], headers: { "Accept" => "application/json" }
    JSON.parse(response.body)
  end

  # Records every SurveyTranslator call so a test can assert the call *pattern*,
  # not just the result. Yields the recorder: an array of [locale, card_count].
  def with_translator
    calls = []
    fake  = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:, **|
      calls << [ target_locale.to_s, Array(cards).size ]
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => Array(c["options"]) } }
    end
    SurveyTranslator.define_singleton_method(:new) { |*| fake }
    yield calls
  ensure
    SurveyTranslator.singleton_class.remove_method(:new)
  end

  # ── The hand-off ──────────────────────────────────────────────────────────

  test "the request enqueues and returns immediately, without calling the model" do
    called = false
    with_generator(->(**) { called = true; { "cards" => [] } }) do
      assert_enqueued_with(job: GenerateFlowJob) { post_flow(prompt: "UK local issues") }
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert body["ok"]
    assert body["poll_url"].present?
    assert_not called, "the Claude call belongs to the job, not the request"
  end

  test "a generation in flight reports its status rather than blocking" do
    with_generator(->(**) { { "cards" => [] } }) { post_flow(prompt: "UK stuff") }
    poll_url = JSON.parse(response.body)["poll_url"]

    get poll_url, headers: { "Accept" => "application/json" }
    assert_response :success
    assert_equal "pending", JSON.parse(response.body)["status"]
  end

  # ── The result ────────────────────────────────────────────────────────────

  test "returns the flow name and rendered cards with fresh unique cids" do
    result = { "name" => "UK",
               "cards" => [
                 { "type" => "open_ended", "text" => "How is local transport?" },
                 { "type" => "yes_no", "text" => "Are energy prices fair?", "options" => %w[Yes No] }
               ] }
    body = with_generator(->(**) { result }) do
      generate_flow!(prompt: "UK local issues", answer: "UK", entry_text: "Which region?")
    end

    assert_response :success
    assert body["ok"]
    assert_equal "succeeded", body["status"]
    assert_equal "UK", body["name"]
    assert_equal 2, body["cards"].size
    cids = body["cards"].map { |c| c["cid"] }
    assert cids.all? { |cid| cid.start_with?("c_") }
    assert_equal cids.uniq, cids
    assert_match "How is local transport?", body["cards"][0]["html"]
    assert_match cids[0], body["cards"][0]["html"], "the rendered wrap carries the stamped cid"
  end

  test "a flow's sliders each arrive with their own animation" do
    # A range card with no `range_theme` doesn't render animation-less, it
    # renders the DEFAULT animation — so a flow of sliders used to arrive
    # playing the same basketball on every one of them, whatever the flow was
    # about and whatever the deck was already playing.
    @survey.update!(theme: "Recycling and climate action",
                    cards: @survey.cards + [ { "type" => "range", "cid" => "c_old", "text" => "How much?",
                                               "options" => %w[a b c], "range_theme" => "recycling" } ])
    result = { "name" => "Habits", "cards" => (1..3).map { |i|
      { "type" => "range", "text" => "How often #{i}?", "options" => %w[Never Sometimes Always] }
    } }

    body = with_generator(->(**) { result }) { generate_flow!(prompt: "recycling habits") }

    themes = body["cards"].map { |c| c["card"]["range_theme"] }
    assert_equal 3, themes.compact.size, "every slider gets an animation of its own"
    assert_equal themes.size, themes.uniq.size, "and not the same one three times: #{themes.inspect}"
    refute_includes themes, "recycling", "nor the one the deck is already playing"
    themes.each { |t| assert_includes NpsHelper::RANGE_THEMES, t }
    assert_match themes[0], body["cards"][0]["html"],
      "the rendered wrap carries it, so the client's save keeps it"
  end

  test "a flow's other card types are left exactly as generated" do
    result = { "name" => "UK", "cards" => [ { "type" => "yes_no", "text" => "Fair?", "options" => %w[Yes No] } ] }
    body = with_generator(->(**) { result }) { generate_flow!(prompt: "UK stuff") }

    card = body["cards"][0]["card"]
    assert_nil card["range_theme"], "only range cards take an animation"
    assert_nil card["image"], "a generated flow still arrives without imagery"
  end

  test "the generated deck is not saved onto the survey" do
    result = { "name" => "UK", "cards" => [ { "type" => "yes_no", "text" => "Fair?", "options" => %w[Yes No] } ] }
    with_generator(->(**) { result }) { generate_flow!(prompt: "UK stuff") }

    assert_equal 1, @survey.reload.cards.size, "the client splices and autosave persists — not this path"
  end

  # ── Refusals happen in the request, before anything is queued ─────────────

  test "a blank prompt is rejected without queueing anything" do
    assert_no_enqueued_jobs(only: GenerateFlowJob) { post_flow(prompt: "   ") }
    assert_response :unprocessable_entity
    assert_not JSON.parse(response.body)["ok"]
  end

  test "a published Verto is locked, and queues nothing" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    assert_no_enqueued_jobs(only: GenerateFlowJob) { post_flow(prompt: "UK stuff") }
    assert_response :locked
  end

  # ── Failure ───────────────────────────────────────────────────────────────

  test "a failed generation surfaces a friendly, bounded error through the poll" do
    long = "x" * 500
    body = with_generator(->(**) { raise long }) { generate_flow!(prompt: "UK stuff") }

    assert_response :unprocessable_entity
    assert_not body["ok"]
    assert_equal "failed", body["status"]
    assert body["error"].present?
    assert_operator body["error"].length, :<, long.length
  end

  test "a generation whose job died is reported as failed, not polled forever" do
    with_generator(->(**) { { "cards" => [] } }) { post_flow(prompt: "UK stuff") }
    poll_url = JSON.parse(response.body)["poll_url"]

    FlowGeneration.last.update!(updated_at: (FlowGeneration::STALE_AFTER + 1.minute).ago)
    get poll_url, headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    assert_equal "failed", JSON.parse(response.body)["status"]
  end

  test "another organisation cannot poll your generation" do
    with_generator(->(**) { { "cards" => [] } }) { post_flow(prompt: "UK stuff") }
    poll_url = JSON.parse(response.body)["poll_url"]

    other = User.create!(name: "X", email_address: "x-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    other_org = Organisation.create!(name: "X", slug: "x-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: other, role: "admin")
    post session_path, params: { email_address: other.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get poll_url, headers: { "Accept" => "application/json" }
    assert_response :not_found
  end

  # ── The 1a.1 regression guard, now inside the job ─────────────────────────
  # A multilingual Verto used to make one translator call PER CARD PER LOCALE, so
  # this asserts the call pattern (one per locale, each carrying the whole flow)
  # rather than just the output. Every other fixture here is single-locale, which
  # is exactly why the fan-out went unnoticed.

  test "a multilingual flow translates once per locale, carrying every card" do
    @survey.update!(locales: %w[en es fr])
    result = { "name" => "UK",
               "cards" => [
                 { "type" => "open_ended", "text" => "How is local transport?" },
                 { "type" => "yes_no", "text" => "Are energy prices fair?", "options" => %w[Yes No] },
                 { "type" => "open_ended", "text" => "Anything else?" }
               ] }

    calls = nil
    body = with_generator(->(**) { result }) do
      with_translator do |recorded|
        out = generate_flow!(prompt: "UK local issues", answer: "UK")
        calls = recorded
        out
      end
    end

    assert body["ok"]
    assert_equal %w[es fr], calls.map(&:first).sort, "one call per secondary locale, and only those"
    assert_equal [ 3, 3 ], calls.map(&:last), "each call carries the whole flow, not a single card"
    assert_equal 2, calls.size, "3 cards x 2 locales must be 2 calls, not 6"
  end

  test "a single-locale flow makes no translator calls at all" do
    result = { "cards" => [ { "type" => "yes_no", "text" => "Fair?", "options" => %w[Yes No] } ] }
    calls = nil
    with_generator(->(**) { result }) do
      with_translator do |recorded|
        generate_flow!(prompt: "UK stuff")
        calls = recorded
      end
    end
    assert_empty calls, "secondary_locales is empty — the translator must not be reached"
  end

  test "the editor renders the generate-flow modal for a logic draft" do
    get survey_path(@survey)
    assert_response :success
    assert_select "[data-flows-target='modal']"
    assert_select "[data-flows-target='generatePrompt']"
    assert_match "data-flows-generate-url-value=", response.body
  end
end
