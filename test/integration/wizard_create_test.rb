require "test_helper"

class WizardCreateTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "wiz-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "wiz-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def with_fake_generator
    fake = Object.new
    def fake.call(**)
      { "title" => "AI title", "description" => "d", "theme" => "T", "audience_age" => "a",
        "key_insight" => "k", "cards" => [ { "type" => "welcome_card", "title" => "hi" },
                                           { "type" => "yes_no", "text" => "Like it?", "options" => [ "Yes", "No" ] } ] }
    end
    SurveyGenerator.define_singleton_method(:new) { |*| fake }
    # Verto creation is a background job now (P0-3); these tests are about the
    # generation pipeline, so drain the queue inside the stub.
    perform_enqueued_jobs { yield }
  ensure
    SurveyGenerator.singleton_class.remove_method(:new)
  end

  test "the wizard asks for no name — the AI-written title names the Verto" do
    get new_survey_path
    assert_response :success
    refute_match 'name="verto_name"', response.body, "the mandatory name field was removed"

    with_fake_generator do
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0"
      }
    end
    assert_equal "AI title", @org.surveys.order(:id).last.title
  end

  test "the Create menu's quiz choice pre-sets the wizard's hidden quiz field" do
    get new_survey_path(quiz: 1)
    assert_response :success
    assert_match 'name="quiz" value="1"', response.body
    refute_match 'type="checkbox" name="quiz"', response.body, "quiz is decided up front, not a mid-wizard checkbox"

    get new_survey_path
    assert_match 'name="quiz" value="0"', response.body
  end

  test "the imports live together on the final card, not the first" do
    get new_survey_path
    assert_response :success
    # All three own-questions doors point at their import endpoints…
    assert_match 'name="manual_questions"', response.body
    assert_match import_manual_survey_path, response.body
    assert_match import_pdf_survey_path, response.body
    # …and the Google-Form door sits with them (its connect link when Google
    # isn't linked), not on the welcome card.
    assert_match "Or import from a Google Form", response.body
  end

  test "every generated Verto ends with the 3 set demographic questions" do
    with_fake_generator do
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0"
      }
    end
    survey = @org.surveys.order(:id).last
    tail = survey.cards.last(3)
    assert tail.all? { |c| c["demographic"] }, "last three cards must be the demographic tail"
    assert_equal [ "How old are you?", "Where do you live?", "What gender best describes you?" ],
                 tail.map { |c| c["text"] }
    assert_equal [ "Male", "Female", "Non-binary", "Other", "Prefer not to say" ], tail.last["options"]
  end

  test "the wizard tells the creator about the demographic tail" do
    get new_survey_path
    assert_response :success
    assert_match "3 set demographic questions", response.body
  end

  test "common questions alone create a Verto without AI generation" do
    set = @org.common_question_sets.create!(name: "Core")
    q   = set.common_questions.create!(text: "How confident are you?", card_type: "range")

    boom = Object.new
    def boom.call(**) = raise("SurveyGenerator must not be called")
    SurveyGenerator.define_singleton_method(:new) { |*| boom }
    begin
      perform_enqueued_jobs do
        post generate_survey_path, params: {
          theme: "T", audience_age: "a",
          show_results_comparison: "0", common_question_ids: [ q.id ]
        }
      end
    ensure
      SurveyGenerator.singleton_class.remove_method(:new)
    end

    survey = @org.surveys.order(:id).last
    # Creation hands off to a background job, so the request redirects to the
    # build's wait screen; that screen forwards to the editor once it lands.
    assert_redirected_to verto_build_path(@org.verto_builds.order(:id).last)
    assert_equal "T", survey.title, "with no AI generation the theme names the Verto"
    types = survey.cards.map { |c| c["type"] }
    assert_equal "welcome_card", types.first
    assert(survey.cards.any? { |c| c["common_question_id"] == q.id })
    assert survey.cards.last["demographic"], "demographic tail still appended"
  end

  test "neither a learning goal nor common questions is rejected" do
    assert_no_difference -> { @org.surveys.count } do
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", show_results_comparison: "0"
      }
    end
    assert_response :unprocessable_entity
    assert_match "Common Questions", response.body
  end

  test "the age demographic renders as a vertical band slider in the player" do
    with_fake_generator do
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0"
      }
    end
    survey = @org.surveys.order(:id).last
    survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get play_survey_path(survey.publish_token)
    assert_response :success
    # The vertical slider, with a stop per band — and no month/year inputs,
    # which is the whole point: the player never collects a date of birth.
    assert_match 'data-slider-axis-value="vertical"', response.body
    assert_match 'data-slider-steps-value="7"', response.body
    DemographicQuestions::AGE_BAND_LABELS.each do |label|
      assert_match label, response.body
    end
    refute_match 'class="freeform-month"', response.body
    refute_match 'class="freeform-year"', response.body
  end
end
