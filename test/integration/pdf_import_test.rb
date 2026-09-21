require "test_helper"

class PdfImportTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "pdf-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "pdf-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def pdf_upload(content_type = "application/pdf")
    Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/questions.pdf"), content_type
    )
  end

  # Stub PdfQuestionImporter.new so the controller gets an object whose #call
  # returns `result` without touching the Anthropic API. `new` is stubbed with a
  # lambda (stub_method invokes callables) that returns the fake instance.
  def stub_importer(result, &block)
    fake = Object.new
    fake.define_singleton_method(:call) { |**_| result }
    # The import runs in a background job now (P0-3), so drain the queue inside
    # the stub and walk the wait-screen redirect chain — these tests are about
    # the import itself, not the hand-off.
    stub_method(PdfQuestionImporter, :new, ->(*_a, **_k) { fake }) do
      perform_enqueued_jobs { block.call }
      follow_verto_build!
    end
  end

  test "the wizard exposes the Import from PDF entry point" do
    get new_survey_path
    assert_response :success
    assert_match "Import from PDF", response.body
    assert_match 'name="pdf"', response.body
    assert_match import_pdf_survey_path, response.body
  end

  test "importing a PDF preserves quiz mode chosen via the Create menu" do
    cards = [ { "type" => "select_one_grid", "text" => "Which best describes you?", "options" => %w[New Returning Lapsed Curious] } ]

    stub_importer({ "title" => "Imported", "cards" => cards }) do
      post import_pdf_survey_path, params: { pdf: pdf_upload, default_locale: "en", locales: [ "en" ], quiz: "1" }
    end

    survey = @org.surveys.order(:created_at).last
    assert survey.quiz?, "quiz mode chosen at the Create menu must survive a PDF import, not just AI generation"
  end

  test "importing a PDF creates a Verto from the matched questions and opens the editor" do
    cards = [
      { "type" => "select_one_grid", "text" => "Which best describes you?", "options" => %w[New Returning Lapsed Curious] },
      { "type" => "open_ended",      "text" => "What would make you stay?" }
    ]

    # The Verto is created on the import's second leg (resume_import), which
    # stub_importer walks to — so the count is asserted around the whole flow.
    assert_difference -> { @org.surveys.count }, 1 do
      stub_importer({ "title" => "Imported", "description" => "Hi", "cards" => cards }) do
        post import_pdf_survey_path, params: { pdf: pdf_upload, default_locale: "en", locales: [ "en" ] }
      end
    end

    survey = @org.surveys.order(:created_at).last
    assert_redirected_to survey_path(survey)
    assert_equal "Imported", survey.title
    # 1 welcome card + 2 imported questions + the 3 set demographic questions
    assert_equal 6, Array(survey.cards).size
    assert_equal "welcome_card", survey.cards.first["type"]
    assert_equal "select_one_grid", survey.cards[1]["type"]
    demographics = survey.cards.select { |c| c["demographic"] }
    assert_equal [ "How old are you?", "Where do you live?", "What gender best describes you?" ],
                 demographics.map { |c| c["text"] }
    assert_equal demographics, survey.cards.last(3), "demographics must sit at the end"
  end

  test "non-compliant questions pause the import on a review screen" do
    cards = [
      { "type" => "open_ended", "text" => "What would make you stay?", "original_text" => "What would make you stay?", "compliant" => true },
      { "type" => "open_ended", "text" => "How could the programme improve?",
        "original_text" => "Thinking about everything you have experienced in the programme so far this year, in what ways do you feel it could be improved and why?",
        "compliant" => false, "issue" => "Over the 100-character cap." }
    ]

    stub_importer({ "title" => "Imported", "cards" => cards }) do
      assert_no_difference -> { @org.surveys.count } do
        post import_pdf_survey_path, params: { pdf: pdf_upload, default_locale: "en", locales: [ "en" ], verto_name: "Programme Review" }
      end
    end
    assert_response :success
    assert_match "don't meet Verto's guidelines", response.body
    assert_match "Thinking about everything you have experienced", response.body
    assert_match "How could the programme improve?", response.body
    assert_match "Optimise with Verto", response.body
    assert_match "Keep my wording", response.body
  end

  test "finalize keeps verbatim wording or takes the optimised version" do
    cards = [
      { "type" => "open_ended", "text" => "Short version?", "original_text" => "The very long original wording of this question?", "compliant" => false, "issue" => "Too long." }
    ]
    payload = {
      "result" => { "title" => "Imported", "cards" => cards },
      "verto_name" => "Named on import", "theme" => "", "audience_age" => "", "key_insight" => "",
      "brand_palette" => nil, "default_locale" => "en", "locales" => [ "en" ],
      "common_question_ids" => []
    }
    signed = SurveysController.import_verifier.generate(payload)

    post finalize_import_survey_path, params: { payload: signed, variant: "verbatim" }
    verbatim = @org.surveys.order(:id).last
    assert_redirected_to survey_path(verbatim)
    assert_equal "welcome_card", verbatim.cards.first["type"], "every imported Verto opens with a welcome card"
    imported = verbatim.cards.find { |c| c["type"] == "open_ended" }
    assert_equal "The very long original wording of this question?", imported["text"]
    assert_equal "Named on import", verbatim.title
    assert verbatim.cards.last["demographic"], "demographic tail appended on finalize"
    refute imported.key?("compliant"), "review-only fields are stripped from stored cards"

    post finalize_import_survey_path, params: { payload: signed, variant: "optimised" }
    optimised = @org.surveys.order(:id).last
    assert_equal "Short version?", optimised.cards.find { |c| c["type"] == "open_ended" }["text"]
  end

  # "Keep my wording exactly as uploaded" used to restore the question TEXT and
  # nothing else — so a Verto in which every question was kept as written could
  # still carry the model's wording, and (before PromptLanguage) the model's
  # SPELLING, through every option label and sub-text. The review screen diffed
  # only the text, so none of it was ever visible either.
  test "verbatim restores the options and sub-text, not just the question" do
    cards = [
      { "type" => "multiple_choice", "text" => "Favourite colour?", "compliant" => true,
        "original_text" => "Favorite color?",
        "options"              => [ "Blue", "Grey", "Neither" ],
        "original_options"     => [ "Blue", "Gray", "Neither" ],
        "description"          => "Pick the colour you like best.",
        "original_description" => "Pick the color you like best." }
    ]
    payload = {
      "result" => { "title" => "Imported", "cards" => cards },
      "verto_name" => "US spellings", "theme" => "", "audience_age" => "", "key_insight" => "",
      "brand_palette" => nil, "default_locale" => "en-US", "locales" => [ "en-US" ],
      "common_question_ids" => []
    }
    signed = SurveysController.import_verifier.generate(payload)

    post finalize_import_survey_path, params: { payload: signed, variant: "verbatim" }
    card = @org.surveys.order(:id).last.cards.find { |c| c["type"] == "multiple_choice" }

    assert_equal "Favorite color?", card["text"]
    assert_equal [ "Blue", "Gray", "Neither" ], card["options"],
                 "an option label the creator wrote is their wording too"
    assert_equal "Pick the color you like best.", card["description"]
    %w[original_options original_description compliant issue original_text].each do |key|
      refute card.key?(key), "#{key} is review-only and must not reach the stored deck"
    end

    post finalize_import_survey_path, params: { payload: signed, variant: "optimised" }
    optimised = @org.surveys.order(:id).last.cards.find { |c| c["type"] == "multiple_choice" }
    assert_equal [ "Blue", "Grey", "Neither" ], optimised["options"], "the other button still takes Verto's version"
  end

  # A card whose text was already compliant could have its OPTIONS reworded and
  # sail straight past the review screen into the editor, so the creator never
  # saw the change and never got the choice.
  test "reworded options pause the import even when every question was compliant" do
    cards = [
      { "type" => "multiple_choice", "text" => "Favourite colour?", "compliant" => true,
        "original_text" => "Favourite colour?",
        "options" => [ "Blue", "Grey" ], "original_options" => [ "Blue", "Gray" ] }
    ]
    stub_importer({ "title" => "Imported", "cards" => cards }) do
      assert_no_difference -> { @org.surveys.count } do
        post import_pdf_survey_path, params: { pdf: pdf_upload, default_locale: "en", locales: [ "en" ], verto_name: "Colours" }
      end
    end
    assert_response :success
    assert_match "had their answers reworded", response.body
    assert_match "Your answers", response.body
    assert_match "Gray", response.body, "the creator has to be able to SEE what changed"
  end

  test "a tampered finalize payload is rejected" do
    assert_no_difference -> { @org.surveys.count } do
      post finalize_import_survey_path, params: { payload: "garbage", variant: "verbatim" }
    end
    assert_redirected_to new_survey_path
  end

  test "a non-PDF upload re-renders the wizard with an error and creates nothing" do
    assert_no_difference -> { @org.surveys.count } do
      post import_pdf_survey_path, params: { pdf: pdf_upload("text/plain") }
    end
    assert_response :unprocessable_entity
    assert_match "Please choose a PDF file", response.body
  end

  test "a PDF with no extractable questions re-renders the wizard with an error" do
    assert_no_difference -> { @org.surveys.count } do
      stub_importer({ "title" => "Empty", "cards" => [] }) do
        post import_pdf_survey_path, params: { pdf: pdf_upload }
      end
    end
    # The read happens in a job now, so "nothing to import" comes back through
    # the build rather than as an immediate re-render — the creator still lands
    # on the wizard with the reason.
    assert_redirected_to new_survey_path
    assert_match(/couldn't find any questions/i, flash[:alert])
  end
end
