require "test_helper"

# The add-question modal's Demographics tiles, now covering the core tail trio
# (age / location / gender) alongside the opt-in pair — with duplicate
# detection that reads keyless legacy tail cards, and the contact wall said at
# the door.
class DemographicTilesTest < ActionDispatch::IntegrationTest
  BARE = [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ].freeze

  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "dt-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "dt-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    org
  end

  def survey_for(org, cards: BARE.map(&:dup), contact: false, locales: [ "en" ])
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: locales, cards: cards, contact_form_enabled: contact
    )
  end

  test "key_for reads both generations of demographic cards" do
    tail = DemographicQuestions.cards
    assert_equal "age",      DemographicQuestions.key_for(tail[0])
    assert_equal "location", DemographicQuestions.key_for(tail[1])
    assert_equal "gender",   DemographicQuestions.key_for(tail[2])
    assert_equal "heritage", DemographicQuestions.key_for(DemographicQuestions.optional_card("heritage"))
    assert_nil DemographicQuestions.key_for(BARE.first)
    assert_equal "age", DemographicQuestions.key_for(DemographicQuestions.core_card("age")),
                 "an inserted core card carries its key explicitly"
  end

  test "the core trio inserts from the modal endpoint, tagged with its key" do
    org = sign_in_org("core")
    s = survey_for(org)

    post demographic_survey_card_path(s), params: { key: "age" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "age", body["card"]["demographic_key"]
    assert_equal "range", body["card"]["type"]
    assert_equal "vertical", body["card"]["slider_axis"]
    assert_equal DemographicQuestions::AGE_BAND_LABELS, body["card"]["options"]
    assert body["card"]["demographic"]
  end

  test "a keyless legacy tail card blocks its tile's insert" do
    org = sign_in_org("dup")
    s = survey_for(org, cards: DemographicQuestions.append_to(BARE.map(&:dup)))
    assert s.cards.none? { |c| c["demographic_key"] }, "the auto-appended tail is keyless — that's the point"

    post demographic_survey_card_path(s), params: { key: "age" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :unprocessable_entity
    assert_match(/already asks/, JSON.parse(response.body)["error"])
  end

  test "the contact wall refuses only the neurodiversity insert at the door" do
    org = sign_in_org("wall")
    s = survey_for(org, contact: true)

    post demographic_survey_card_path(s), params: { key: "neurodiversity" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :unprocessable_entity
    assert_match(/never both/, JSON.parse(response.body)["error"])

    post demographic_survey_card_path(s), params: { key: "gender" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success, "gender beside a contact form is allowed"
    assert_equal "gender", JSON.parse(response.body)["card"]["demographic_key"]
  end

  test "the modal renders five tiles, greyed by deck state and by the wall" do
    org = sign_in_org("modal")

    bare = survey_for(org)
    get survey_path(bare)
    assert_select ".aq-demographic-tile", 5
    assert_select ".aq-demographic-tile[disabled]", 0

    tailed = survey_for(org, cards: DemographicQuestions.append_to(BARE.map(&:dup)))
    get survey_path(tailed)
    assert_select ".aq-demographic-tile[disabled]", 3
    assert_select ".aq-demographic-tile[data-demographic-key=age][disabled]", 1

    walled = survey_for(org, contact: true)
    get survey_path(walled)
    assert_select ".aq-demographic-tile[disabled]", 1
    assert_select ".aq-demographic-tile[data-demographic-key=neurodiversity][disabled]", 1
    assert_match "can't also ask the", response.body
  end

  test "a multilingual insert arrives with its translations prefilled" do
    org = sign_in_org("i18n")
    s = survey_for(org, locales: %w[en fr])

    post demographic_survey_card_path(s), params: { key: "location" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success
    card = JSON.parse(response.body)["card"]
    fr = card.dig("i18n", "fr")
    assert fr.is_a?(Hash) && fr["text"].present?, "the locale files already hold the tail's translations"
    assert_not_equal card["text"], fr["text"]
  end
end
