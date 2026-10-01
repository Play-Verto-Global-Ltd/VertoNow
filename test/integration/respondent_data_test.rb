require "test_helper"

# GDPR data-subject rights (P0-7). Before this, respondent PII could only be
# removed by destroying the whole Verto — there was no responses controller and
# no routes at all.
#
# The creator is the data controller, so this is admin-only and org-scoped:
# unlike every other results view, which is careful to stay aggregate, these
# endpoints return one named individual's answers.
class RespondentDataTest < ActionDispatch::IntegrationTest
  def setup
    @org    = Organisation.create!(name: "O", slug: "rd-#{SecureRandom.hex(3)}")
    @admin  = User.create!(name: "A", email_address: "rd-a-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    @member = User.create!(name: "M", email_address: "rd-m-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    @org.memberships.create!(user: @admin, role: "admin")
    @org.memberships.create!(user: @member, role: "member")

    @survey = @org.surveys.create!(
      title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Do you feel safe?", "options" => %w[Yes No] },
               { "type" => "open_ended", "input" => "location", "text" => "Where do you live?",
                 "demographic" => true } ]
    )
    @token = SecureRandom.uuid
    @resp  = @survey.responses.create!(
      session_token: @token, status: "completed", answered: true,
      answers: { "0" => { "type" => "yes_no", "value" => "Yes" },
                 "1" => { "type" => "open_ended", "value" => "London" } },
      demographic_birth_year: 1990, demographic_gender: "Female",
      demographic_heritage: "Mixed or multiple heritage",
      demographic_neurodiversity: "|ADHD|Dyslexia|",
      region_country: "GB", region_label: "London", locale: "en", device_kind: "mobile",
      consent_agreed_at: Time.current, consent_text_snapshot: "You agreed to this.",
      started_at: 3.minutes.ago, completed_at: Time.current
    )
  end

  def login(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # ── Authorisation ───────────────────────────────────────────────────────

  test "a non-admin member cannot reach it" do
    login(@member)
    get survey_respondent_data_path(@survey)
    assert_redirected_to root_path

    get survey_respondent_data_export_path(@survey, session_token: @token)
    assert_redirected_to root_path

    delete survey_respondent_data_path(@survey, session_token: @token)
    assert_redirected_to root_path
    assert @resp.reload.persisted?
  end

  test "an admin of another organisation cannot reach this Verto's respondents" do
    other_org  = Organisation.create!(name: "X", slug: "rd-x-#{SecureRandom.hex(3)}")
    other_admin = User.create!(name: "X", email_address: "rd-x-#{SecureRandom.hex(3)}@test.com",
                               password: "verylongpassword")
    other_org.memberships.create!(user: other_admin, role: "admin")

    login(other_admin)
    get survey_respondent_data_path(@survey)
    assert_response :not_found
  end

  test "it is not reachable signed out" do
    get survey_respondent_data_path(@survey)
    assert_response :redirect
    assert_not_equal survey_respondent_data_path(@survey), response.location
  end

  # ── Lookup ──────────────────────────────────────────────────────────────

  test "an admin finds a respondent by session token" do
    login(@admin)
    get survey_respondent_data_path(@survey, session_token: @token)
    assert_response :success
    assert_match "##{@resp.id}", response.body
  end

  test "an unknown identifier reports no match rather than erroring" do
    login(@admin)
    get survey_respondent_data_path(@survey, session_token: "nope")
    assert_response :success
    assert_select "p", text: I18n.t("respondent_data.not_found")
  end

  test "opening the page with no query searches for nothing" do
    login(@admin)
    get survey_respondent_data_path(@survey)
    assert_response :success
    assert_select "p", text: I18n.t("respondent_data.not_found"), count: 0
  end

  test "a respondent code finds every wave that person answered" do
    # The whole point of respondent codes: one person, several responses.
    @survey.update!(respondent_code_enabled: true)
    digest = @survey.respondent_code_digest("Sam 14")
    a = @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                  status: "completed", answers: {})
    b = @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                  status: "completed", answers: {})

    login(@admin)
    get survey_respondent_data_path(@survey, respondent_code: "sam14")
    assert_response :success
    assert_match "##{a.id}", response.body
    assert_match "##{b.id}", response.body
  end

  # ── Export (Article 15 / 20) ────────────────────────────────────────────

  test "the export contains everything held, not just the answers" do
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)
    assert_response :success
    assert_equal "application/json", response.media_type

    row = JSON.parse(response.body)["responses"].first
    assert_equal 1990,     row["demographics"]["birth_year"]
    assert_equal "Female", row["demographics"]["gender"]
    assert_equal "London", row["demographics"]["region"]
    assert_equal "Mixed or multiple heritage", row["demographics"]["heritage"]
    assert_equal %w[ADHD Dyslexia], row["demographics"]["neurodiversity"],
                 "the packed column must unpack for a subject-access reader"
    assert_equal "mobile", row["device"]
    assert_equal "en",     row["language"]
    assert_equal "You agreed to this.", row["consent"]["agreed_to"]
    assert_not_nil row["consent"]["agreed_at"]
    assert_not_nil row["duration_seconds"]
  end

  test "the export says how long they spent on each question, answered or not" do
    @resp.update!(answers: { "0" => { "type" => "yes_no", "value" => "Yes" } }, dwell_ms: { "0" => 8400, "1" => 2600 })
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)

    answers = JSON.parse(response.body)["responses"].first["answers"]
    assert_equal 8.4, answers.first["time_on_question_seconds"]
    # Read and left blank: no answer to show, but the time is still theirs.
    assert_equal "Where do you live?", answers.second["question"]
    assert_nil answers.second["answer"]
    assert_equal 2.6, answers.second["time_on_question_seconds"]
  end

  test "an Other write-in is an answer and is exported as one" do
    @resp.update!(answers: { "0" => { "type" => "yes_no", "value" => nil, "other" => "Sometimes" } })
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)

    answers = JSON.parse(response.body)["responses"].first["answers"]
    assert_equal "Sometimes", answers.first["other"]
    assert_nil answers.first["time_on_question_seconds"], "absent, not zero, where nothing was recorded"
  end

  test "answers are exported next to the question that was asked" do
    # Answers are stored keyed by card INDEX, which is meaningless to the person
    # receiving the file.
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)

    answers = JSON.parse(response.body)["responses"].first["answers"]
    assert_equal "Do you feel safe?", answers.first["question"]
    assert_equal "Yes",               answers.first["answer"]
    assert_equal "Where do you live?", answers.second["question"]
  end

  test "a respondent code is never exported in a reversible form" do
    @survey.update!(respondent_code_enabled: true)
    @resp.update!(respondent_code_digest: @survey.respondent_code_digest("secret-code"))

    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)

    assert_not_includes response.body, "secret-code"
    assert_not_includes response.body, @resp.reload.respondent_code_digest
    assert_equal true, JSON.parse(response.body)["responses"].first["respondent_code"]["linked"]
  end

  test "exporting an unknown identifier says so rather than sending an empty file" do
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: "nope")
    assert_redirected_to survey_respondent_data_path(@survey)
    assert_equal I18n.t("respondent_data.not_found"), flash[:alert]
  end

  # ── Erasure (Article 17) ────────────────────────────────────────────────

  test "erasing removes the row outright rather than blanking it" do
    login(@admin)
    assert_difference -> { @survey.responses.count }, -1 do
      delete survey_respondent_data_path(@survey, session_token: @token)
    end
    assert_redirected_to survey_respondent_data_path(@survey)
    assert_nil Response.find_by(session_token: @token)
  end

  test "erasing by respondent code removes every wave" do
    @survey.update!(respondent_code_enabled: true)
    digest = @survey.respondent_code_digest("Sam 14")
    2.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                status: "completed", answers: {})
    end

    login(@admin)
    assert_difference -> { @survey.responses.count }, -2 do
      delete survey_respondent_data_path(@survey, respondent_code: "sam14")
    end
    # The unrelated respondent is untouched.
    assert Response.exists?(session_token: @token)
  end

  test "erasure takes the responder's export alias with it" do
    @survey.update!(respondent_code_enabled: true)
    digest = @survey.respondent_code_digest("Sam 14")
    resp   = @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                       status: "completed", answers: {})
    RespondentAlias.ensure_for!(survey: @survey, code_digest: digest)

    login(@admin)
    delete survey_respondent_data_path(@survey, respondent_code: "sam14")

    assert_nil Response.find_by(id: resp.id)
    assert_not RespondentAlias.exists?(survey_id: @survey.id, code_digest: digest),
               "the minted name is that person's data too — erased with their rows"
  end

  test "a session-token erasure of one run still purges the shared responder alias" do
    # Deliberate: the name a creator has seen for this identity dies with the
    # erased row even though sibling runs survive; the survivors re-mint a
    # fresh pseudonym on the next export rather than keeping a label that once
    # pointed at erased data.
    @survey.update!(respondent_code_enabled: true)
    digest   = @survey.respondent_code_digest("Sam 14")
    erased   = @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                         status: "completed", answers: {})
    survivor = @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                         status: "completed", answers: {})
    RespondentAlias.ensure_for!(survey: @survey, code_digest: digest)

    login(@admin)
    delete survey_respondent_data_path(@survey, session_token: erased.session_token)

    assert Response.exists?(id: survivor.id)
    assert_not RespondentAlias.exists?(survey_id: @survey.id, code_digest: digest)
  end

  # ── The respondent account ────────────────────────────────────────────────
  #
  # A Player is the first durable respondent handle this app has ever had, so
  # it is the first identifier a data-subject request can plausibly arrive
  # holding — and the first one whose erasure has a boundary, because an
  # account spans Vertos belonging to different creators.

  def player_keeping(response, email: "rd-p-#{SecureRandom.hex(3)}@test.com")
    Player.for_email(email).tap { |pl| PlayerClaim.claim!(player: pl, response: response, source: "signup") }
  end

  test "an admin finds a respondent by the address they kept this Verto with" do
    pl = player_keeping(@resp)
    login(@admin)

    get survey_respondent_data_path(@survey, email_address: pl.email_address.upcase)

    assert_response :success
    assert_match "1 matching", response.body
  end

  test "an address that kept another Verto finds nothing here" do
    other = @org.surveys.create!(title: "T2", theme: "Th", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ],
                                 cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])
    theirs = other.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    pl = player_keeping(theirs)
    login(@admin)

    get survey_respondent_data_path(@survey, email_address: pl.email_address)

    assert_response :success
    assert_match I18n.t("respondent_data.not_found"), response.body
  end

  test "the export carries the account, because Article 15 asks for everything" do
    pl = player_keeping(@resp)
    login(@admin)

    get survey_respondent_data_export_path(@survey, session_token: @token)

    data = JSON.parse(response.body)
    assert_equal pl.email_address, data.dig("account", "email_address")
    assert_equal 1, data.dig("account", "vertos_in_account")
  end

  test "an export with no account has no account section at all" do
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)
    refute JSON.parse(response.body).key?("account")
  end

  test "erasure reaches the claim, and does not raise on the way" do
    # The FK from player_claims to responses is RESTRICT, like every other
    # responses FK here. Without `dependent: :delete_all` on Response this
    # raises ActiveRecord::InvalidForeignKey and erasure fails outright — the
    # regression this pins.
    pl = player_keeping(@resp)
    login(@admin)

    delete survey_respondent_data_path(@survey, session_token: @token)

    assert_redirected_to survey_respondent_data_path(@survey)
    assert_equal 0, PlayerClaim.where(player_id: pl.id).count
    assert_equal 0, Response.where(id: @resp.id).count
  end

  test "an account left holding nothing goes with the last Verto in it" do
    pl = player_keeping(@resp)
    login(@admin)

    delete survey_respondent_data_path(@survey, session_token: @token)

    refute Player.exists?(pl.id), "keeping a bare address after an erasure request is the half-measure this refuses"
  end

  test "an account still holding another creator's Verto survives the erasure" do
    other = @org.surveys.create!(title: "T2", theme: "Th", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ],
                                 cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])
    elsewhere = other.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    pl = player_keeping(@resp)
    PlayerClaim.claim!(player: pl, response: elsewhere, source: "device_key")
    login(@admin)

    delete survey_respondent_data_path(@survey, session_token: @token)

    assert Player.exists?(pl.id),
           "this creator is the data controller for their Verto, not for the rest of the account"
    assert_equal [ elsewhere.id ], pl.player_claims.pluck(:response_id)
  end

  test "erasure takes the told-them records but leaves a standing mail choice alone" do
    other = @org.surveys.create!(title: "T2", theme: "Th", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ],
                                 cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])
    elsewhere = other.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    pl = player_keeping(@resp)
    PlayerClaim.claim!(player: pl, response: elsewhere, source: "device_key")
    PlayerNotification.claim(player: pl, survey: @survey, kind: "impact")
    PlayerEmailPreference.unsubscribe!(player: pl, organisation: @org)
    login(@admin)

    delete survey_respondent_data_path(@survey, session_token: @token)

    assert_equal 0, PlayerNotification.where(survey_id: @survey.id).count,
                 "a record of telling them about an erased Verto is not worth keeping"
    assert PlayerEmailPreference.unsubscribed?(pl.id, @org.id),
           "their standing choice about this organisation is not data about the erased Verto — " \
           "silently re-subscribing them would be the worst reading of an erasure request"
  end

  test "erasing nothing does not claim to have erased something" do
    login(@admin)
    assert_no_difference -> { @survey.responses.count } do
      delete survey_respondent_data_path(@survey, session_token: "nope")
    end
    assert_equal I18n.t("respondent_data.not_found"), flash[:alert]
  end

  test "a lookup with no identifier at all never matches every respondent" do
    # The dangerous failure mode: a blank query falling through to
    # survey.responses and erasing the lot.
    login(@admin)
    assert_no_difference -> { @survey.responses.count } do
      delete survey_respondent_data_path(@survey)
    end
  end

  test "an identifier from one Verto does not reach another's respondents" do
    other = @org.surveys.create!(title: "T2", theme: "Th", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    login(@admin)

    get survey_respondent_data_path(other, session_token: @token)
    assert_response :success
    assert_select "p", text: I18n.t("respondent_data.not_found")

    delete survey_respondent_data_path(other, session_token: @token)
    assert Response.exists?(session_token: @token)
  end

  test "the same code hashes differently in a different Verto" do
    # respondent_code_key is derived per survey id, so a code cannot be used to
    # find the same person across Vertos — including from this tool.
    other = @org.surveys.create!(title: "T2", theme: "Th", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    assert_not_equal @survey.respondent_code_digest("sam14"), other.respondent_code_digest("sam14")
  end

  # ── The entry point ─────────────────────────────────────────────────────

  test "admins see the link on the results page and members don't" do
    # The results page renders a play link, so it needs a published Verto.
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    login(@admin)
    get survey_results_path(@survey)
    assert_select "a[href=?]", survey_respondent_data_path(@survey), 1

    delete session_path
    login(@member)
    get survey_results_path(@survey)
    assert_select "a[href=?]", survey_respondent_data_path(@survey), 0
  end
end
