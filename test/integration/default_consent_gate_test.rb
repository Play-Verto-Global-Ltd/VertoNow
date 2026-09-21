require "test_helper"

# DemographicQuestions appends birth month/year, location and gender to every
# Verto at creation, and the consent gate was optional — so in practice the
# platform was collecting personal data with no gate at all unless the creator
# happened to write one (P0-6).
#
# The gate is now supplied by the player when a Verto collects personal data and
# has no gate of its own. Enforced here rather than at publish on purpose: a
# publish-time rule would leave every already-live Verto ungated, which is the
# actual exposure.
class DefaultConsentGateTest < ActionDispatch::IntegrationTest
  DEMOGRAPHIC = { "type" => "open_ended", "input" => "location", "text" => "Where do you live?",
                  "demographic" => true }.freeze
  PLAIN       = { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] }.freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "dcg-#{SecureRandom.hex(3)}")
  end

  def published(cards, **attrs)
    survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: cards, **attrs)
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey.reload
  end

  # ── The model rule ──────────────────────────────────────────────────────

  test "a Verto with a demographic card collects personal data" do
    assert published([ PLAIN, DEMOGRAPHIC ]).collects_personal_data?
    assert_not published([ PLAIN ]).collects_personal_data?
  end

  test "the default gate applies only when the creator built no gate" do
    assert published([ DEMOGRAPHIC ]).default_consent_gate?

    # The creator's own wording wins.
    assert_not published([ DEMOGRAPHIC ], consent_text: "Mine").default_consent_gate?

    # So does a consent_gate card, which is the more specific thing they built.
    card = { "type" => "consent_gate", "cid" => "c_g", "pages" => [ { "id" => "p1", "text" => "Agree?" } ] }
    assert_not published([ card, DEMOGRAPHIC ]).default_consent_gate?
  end

  test "a Verto that collects nothing personal gets no gate" do
    survey = published([ PLAIN ])
    assert_not survey.default_consent_gate?
    assert_not survey.show_consent_gate?
    assert_not survey.consent_gated?
  end

  test "effective_consent_text prefers the creator's wording" do
    assert_equal "Mine", published([ DEMOGRAPHIC ], consent_text: "Mine").effective_consent_text
    assert_equal I18n.t("player.consent_default_text"),
                 published([ DEMOGRAPHIC ]).effective_consent_text
    assert_nil published([ PLAIN ]).effective_consent_text
  end

  # ── What the respondent actually sees ───────────────────────────────────

  test "the player renders a gate on a Verto that would otherwise be ungated" do
    survey = published([ PLAIN, DEMOGRAPHIC ])

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select ".play-consent-banner", 1
    assert_select ".preview-overlay[data-consent-pending]"
    # "your age", not "your birth date": the tail asks for an age band now,
    # and the gate is the one place a respondent is told what is collected.
    assert_select ".play-consent-body", text: /your age/
  end

  test "the gate links to the privacy policy" do
    get play_survey_path(published([ DEMOGRAPHIC ]).publish_token)
    assert_select ".play-consent-legal a[href=?]", privacy_path
  end

  test "a creator-authored gate also gets the privacy link" do
    # The link is on every gate, not only the default one.
    get play_survey_path(published([ DEMOGRAPHIC ], consent_text: "My own wording").publish_token)
    assert_select ".play-consent-body", text: /My own wording/
    assert_select ".play-consent-legal a[href=?]", privacy_path
  end

  test "no gate is rendered when nothing personal is collected" do
    get play_survey_path(published([ PLAIN ]).publish_token)
    assert_response :success
    assert_select ".play-consent-banner", 0
    assert_select ".preview-overlay[data-consent-pending]", 0
  end

  test "the default gate does not stack on top of a consent_gate card" do
    card   = { "type" => "consent_gate", "cid" => "c_g", "pages" => [ { "id" => "p1", "text" => "Agree?" } ] }
    survey = published([ card, DEMOGRAPHIC ])

    get play_survey_path(survey.publish_token)
    assert_select ".play-consent-banner", 0, "the card gate is the only gate"
    assert_select "[data-card-type=consent_gate]", 1
  end

  # ── The audit trail ─────────────────────────────────────────────────────

  test "agreeing to the default gate records the wording that was shown" do
    # A blank snapshot would make the consent record worthless: the whole point
    # of consent_text_snapshot is that it says what the respondent agreed to.
    survey = published([ DEMOGRAPHIC ])
    token  = SecureRandom.uuid

    post consent_survey_path(survey.publish_token),
         params: { session_token: token, agreed: true }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success

    resp = survey.responses.find_by(session_token: token)
    assert_not_nil resp.consent_agreed_at
    assert_equal I18n.t("player.consent_default_text"), resp.consent_text_snapshot
  end

  test "the gate is rendered and recorded in the respondent's language" do
    survey = published([ DEMOGRAPHIC ], default_locale: "fr", locales: [ "fr" ])
    token  = SecureRandom.uuid

    post consent_survey_path(survey.publish_token),
         params: { session_token: token, agreed: true }.to_json,
         headers: { "Content-Type" => "application/json", "Accept-Language" => "fr" }

    resp = survey.responses.find_by(session_token: token)
    assert_equal I18n.t("player.consent_default_text", locale: :fr), resp.consent_text_snapshot
  end
end
