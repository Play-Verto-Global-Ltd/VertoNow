require "test_helper"

class SurveySummariesTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Do you like sport?", "options" => [ "Yes", "No" ] },
    { "type" => "open_ended", "text" => "What would you change?" }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "sst-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "sst-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS)
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "refuses a card that isn't open-text" do
    get survey_results_summarize_texts_path(@survey, card_index: 1, segment: "overall")
    assert_response :success
    assert_equal "Not an open-text question.", response.body
  end

  test "refuses an unknown segment" do
    get survey_results_summarize_texts_path(@survey, card_index: 2, segment: "region_ZZ")
    assert_response :success
    assert_equal "Unknown segment.", response.body
  end

  test "refuses the demographic location/birth-month cards even though they're open_ended" do
    survey = @org.surveys.create!(title: "T2", theme: "T", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ],
                                  cards: CARDS + DemographicQuestions.cards)
    location_idx = survey.cards.index { |c| c["demographic"] && c["input"] == "location" }

    get survey_results_summarize_texts_path(survey, card_index: location_idx, segment: "overall")
    assert_response :success
    assert_equal "Not an open-text question.", response.body
  end

  test "streams the summariser's output for the resolved segment's texts" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                              answers: { "2" => { "type" => "open_ended", "value" => "More benches please" } })
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                              answers: { "2" => { "type" => "open_ended", "value" => "Better lighting" } })

    captured = nil
    fake = Object.new
    fake.define_singleton_method(:call) do |question:, texts:, &block|
      captured = { question: question, texts: texts }
      block.call("Two themes: benches and lighting.")
    end

    stub_method(OpenTextSummariser, :new, ->(*) { fake }) do
      get survey_results_summarize_texts_path(@survey, card_index: 2, segment: "overall")
    end

    assert_response :success
    assert_equal "Two themes: benches and lighting.", response.body
    assert_equal "What would you change?", captured[:question]
    assert_equal [ "More benches please", "Better lighting" ].sort, captured[:texts].sort
  end

  test "scopes texts to just the selected region segment" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                              region_country: "US",
                              answers: { "2" => { "type" => "open_ended", "value" => "US answer" } })
    (Response::MIN_REGION_SAMPLE_SIZE - 1).times do |i|
      @survey.responses.create!(session_token: "us-pad-#{i}-#{SecureRandom.hex(2)}", status: "completed", answered: true,
                                region_country: "US", answers: { "2" => { "type" => "open_ended", "value" => "padding #{i}" } })
    end
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                              region_country: "GB",
                              answers: { "2" => { "type" => "open_ended", "value" => "GB answer" } })
    # GB needs its own padding to clear Response::MIN_REGION_SAMPLE_SIZE, on a
    # different card so it doesn't add extra open-ended texts to assert against.
    (Response::MIN_REGION_SAMPLE_SIZE - 1).times do |i|
      @survey.responses.create!(session_token: "gb-pad-#{i}-#{SecureRandom.hex(2)}", status: "completed", answered: true,
                                region_country: "GB", answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end

    captured = nil
    fake = Object.new
    fake.define_singleton_method(:call) do |question:, texts:, &block|
      captured = texts
      block.call("summary")
    end

    stub_method(OpenTextSummariser, :new, ->(*) { fake }) do
      get survey_results_summarize_texts_path(@survey, card_index: 2, segment: "region_GB")
    end

    assert_response :success
    assert_equal [ "GB answer" ], captured
  end
end
