require "test_helper"

# The box beside each question: a reading of that chart ("what the answers tell
# us") over the card's own framework tagging ("why we asked").
#
# The two halves have completely different failure modes and are tested as
# such. The Why is free — it is already on the card, written by the generator
# against config/competencies.yml — so the only thing that can go wrong is
# rendering it where it doesn't belong. The reading costs a model call, so the
# risks are all about the cache: a reading replayed under numbers it was not
# written about is prose that is confidently, fluently wrong, and looks exactly
# like a correct one.
class QuestionInsightsEndpointTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Do you like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  def setup
    @org  = Organisation.create!(name: "O", slug: "qi-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "qi-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS)
    sign_in(@user)
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def answer(country: nil, value: "Yes", token: SecureRandom.uuid)
    @survey.responses.create!(session_token: token, answered: true, status: "completed",
                              region_country: country,
                              answers: { "1" => { "type" => "yes_no", "value" => value } })
  end

  # Records every call so a test can assert the service was NOT reached, which
  # is the whole point of the cache and is invisible from the response body
  # alone — a replay and a fresh read are the same JSON but for one flag.
  def fake_service(insights = { "1" => "Most said yes." })
    calls = []
    fake  = Object.new
    fake.define_singleton_method(:call) do |survey:, aggregated:, total:|
      calls << { total: total, counts: aggregated[1][:counts] }
      insights
    end
    [ fake, calls ]
  end

  test "the first read calls the model and the second replays it from the survey" do
    5.times { answer }
    fake, calls = fake_service

    stub_method(QuestionInsights, :new, ->(*) { fake }) do
      get survey_results_insights_path(@survey)
      assert_response :success
      body = JSON.parse(response.body)
      assert body["ok"]
      refute body["cached"]
      assert_equal({ "1" => "Most said yes." }, body["insights"])

      get survey_results_insights_path(@survey)
      body = JSON.parse(response.body)
      assert body["cached"], "the second visit spent a model call on a reading it already had"
      assert_equal({ "1" => "Most said yes." }, body["insights"])
    end

    assert_equal 1, calls.size
  end

  # The one that matters. results_summary caches on the response count alone,
  # so switching filters can replay a summary written about a different set of
  # people; this endpoint keys on the segment too, and this test is what holds
  # that. Both segments here have the SAME number of answers, so a count-only
  # cache would sail straight through it.
  test "a different segment is read afresh rather than replayed under new numbers" do
    5.times { answer(country: "GB", value: "Yes") }
    5.times { answer(country: "US", value: "No") }

    fake, calls = fake_service
    stub_method(QuestionInsights, :new, ->(*) { fake }) do
      get survey_results_insights_path(@survey, segment: "region_GB")
      assert_response :success
      get survey_results_insights_path(@survey, segment: "region_US")
      assert_response :success
      refute JSON.parse(response.body)["cached"],
        "a reading of Great Britain was replayed as a reading of the United States"
    end

    assert_equal 2, calls.size
    assert_equal({ "Yes" => 5 }, calls.first[:counts])
    assert_equal({ "No" => 5 }, calls.last[:counts])
  end

  test "a new response invalidates the reading it is not counted in" do
    5.times { answer }
    fake, calls = fake_service

    stub_method(QuestionInsights, :new, ->(*) { fake }) do
      get survey_results_insights_path(@survey)
      answer
      get survey_results_insights_path(@survey)
      refute JSON.parse(response.body)["cached"]
    end

    assert_equal [ 5, 6 ], calls.map { |c| c[:total] }
  end

  test "another organisation's survey is a 404, not a reading" do
    other_org  = Organisation.create!(name: "X", slug: "qi-x-#{SecureRandom.hex(3)}")
    other      = other_org.surveys.create!(title: "T", theme: "T", audience_age: "all",
                                           key_insight: "x", default_locale: "en",
                                           locales: [ "en" ], cards: CARDS)
    fake, calls = fake_service

    stub_method(QuestionInsights, :new, ->(*) { fake }) do
      get survey_results_insights_path(other)
    end

    assert_response :not_found
    assert_empty calls
  end

  # The boxes are an extra on a page that works without them, so a model
  # failure must read as "no boxes", never as a broken results page.
  test "a failed reading is a JSON error rather than a 500" do
    5.times { answer }
    boom = Object.new
    boom.define_singleton_method(:call) { |**| raise "upstream down" }

    stub_method(ErrorReporting, :report, nil) do
      stub_method(QuestionInsights, :new, ->(*) { boom }) do
        get survey_results_insights_path(@survey)
      end
    end

    assert_response :service_unavailable
    refute JSON.parse(response.body)["ok"]
    assert_nil @survey.reload.results_insights,
      "a failed read must not be cached as an empty one — the next visit would replay nothing"
  end

  test "signed out is not a way to spend the organisation's model calls" do
    5.times { answer }
    delete session_path
    fake, calls = fake_service

    stub_method(QuestionInsights, :new, ->(*) { fake }) do
      get survey_results_insights_path(@survey)
    end

    assert_redirected_to new_session_path
    assert_empty calls
  end
end

# The Why half, which needs no model call at all.
class QuestionInsightsWhyTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "O", slug: "qw-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "qw-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def build_survey(cards)
    @survey = @org.surveys.create!(title: "Cards", theme: "Th", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ],
                                   publish_token: SecureRandom.hex(8), published_at: Time.current,
                                   cards: cards)
  end

  def answer(answers)
    @survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                              status: "completed", answers: answers)
  end

  def open_results
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    get survey_results_path(@survey)
    assert_response :success
  end

  TAGGED = { "type" => "yes_no", "text" => "Would you come back?", "options" => %w[Yes No],
             "competency" => "agency", "condition" => "belonging",
             "outcome" => "Whether the barrier is the place or the people." }.freeze

  test "a tagged card shows its competency, its condition and what it was asked to learn" do
    build_survey([ TAGGED ])
    answer("0" => { "value" => "Yes" })

    open_results

    assert_select ".rc-aside .rc-why", 1
    assert_select ".rc-why-badge", 2
    assert_select ".rc-why-badge", text: /#{Framework.competency("agency")["label"]}/
    assert_select ".rc-why-badge", text: /#{Framework.condition("belonging")["label"]}/
    assert_select ".rc-why-body", text: "Whether the barrier is the place or the people."
  end

  # Most decks carry no tagging — it only exists on cards the generator wrote
  # or that were run through the optimiser. An empty "Why we asked" heading
  # beside every chart would be worse than no box.
  test "an untagged card gets a reading slot and no Why at all" do
    build_survey([ { "type" => "yes_no", "text" => "Plain", "options" => %w[Yes No] } ])
    answer("0" => { "value" => "Yes" })

    open_results

    assert_select ".rc-aside", 1
    assert_select ".rc-why", 0
    assert_select ".rc-tell[data-index='0']", 1
  end

  # A card whose competency key no longer exists in competencies.yml must drop
  # the badge, not render a blank pill with an empty accent colour.
  test "a tagging the framework no longer knows is dropped" do
    build_survey([ TAGGED.merge("competency" => "not_a_real_key", "condition" => "also_gone") ])
    answer("0" => { "value" => "Yes" })

    open_results

    assert_select ".rc-why", 1, "the outcome line alone still earns a Why box"
    assert_select ".rc-why-badge", 0
  end

  test "the reading slot is empty and hidden until the model answers" do
    build_survey([ TAGGED ])
    answer("0" => { "value" => "Yes" })

    open_results

    slot = css_select(".rc-tell").first
    assert slot.attributes.key?("hidden"), "the slot must not show its heading over an empty body"
    assert_equal "", slot.css(".rc-tell-body").text.strip
    # The shimmer is revealed by the controller, not by the server. A page
    # whose JavaScript never arrives would otherwise sit under "Reading the
    # answers…" forever, waiting on a fetch nothing is going to make.
    assert css_select(".rc-tell-wait").first.attributes.key?("hidden"),
      "the server must not render a shimmer for a request it is not making"
    assert_select "[data-question-insights-url-value]", 1,
      "the feed must carry the endpoint, and carry it on the frame so a filter swap refetches"
  end

  # The public share page has no signed-in organisation to bill a model call
  # to, and no throttle bucket to put one in. The Why is already on the card,
  # so it stays; the reading does not appear.
  test "the shared page keeps the Why and asks for no reading" do
    build_survey([ TAGGED ])
    answer("0" => { "value" => "Yes" })
    @survey.update_columns(results_share_active: true, results_share_token: SecureRandom.hex(12))

    get shared_results_path(@survey.results_share_token)
    assert_response :success

    assert_select ".rc-why", 1
    assert_select ".rc-tell", 0
    assert_select "[data-controller~='question-insights']", 0
  end

  # Non-question cards (welcome, consent, contact) have nothing to read and
  # nothing to explain.
  test "a welcome card gets no box" do
    build_survey([ { "type" => "welcome_card", "title" => "hi" },
                   { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])
    answer("1" => { "value" => "Yes" })

    open_results

    assert_select ".rc-aside", 1
    assert_select ".rc-tell[data-index='1']", 1
  end
end
