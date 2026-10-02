require "test_helper"

# The account ask at the end of a Verto, held to the Privacy Notice's minimum
# age (AccountAge): what submit tells the page, and what the two join doors
# and the /you Google door refuse. The page only hides or asks; these
# endpoints are what make it true.
class AccountAgeJoinTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct-horse-battery"
  AGE_CARD = DemographicQuestions.core_card("age")
  JSON_HEADERS = { "CONTENT_TYPE" => "application/json" }.freeze

  def setup
    @org = Organisation.create!(name: "A", slug: "aa-#{SecureRandom.hex(4)}")
  end

  def survey(cards: [ { "type" => "yes_no", "text" => "Q?" }, AGE_CARD ], **attrs)
    s = @org.surveys.create!(
      title: "Age", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: cards, join_prompt_enabled: true, **attrs
    )
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s
  end

  # Finish a run, answering the age card (index 1) with the band at `band`
  # (an index into DemographicQuestions::AGE_BANDS), or skipping it.
  def finish(s, band: nil)
    token   = SecureRandom.uuid
    answers = { "0" => { "value" => "Yes" } }
    answers["1"] = { "value" => band } unless band.nil?
    post submit_survey_path(s.publish_token),
         params: { session_token: token, answers: answers }.to_json, headers: JSON_HEADERS
    assert_response :success
    [ token, JSON.parse(response.body) ]
  end

  def join(s, token, **extra)
    post join_survey_path(s.publish_token),
         params: { email: "aa-#{SecureRandom.hex(4)}@test.com", password: PASSWORD,
                   session_token: token }.merge(extra).to_json,
         headers: JSON_HEADERS
    JSON.parse(response.body)
  end

  BAND = DemographicQuestions::AGE_BAND_KEYS.each_with_index.to_h

  test "a 22-year-old is told they can have an account, and gets one with no box to tick" do
    s = survey
    token, data = finish(s, band: BAND["18_24"])
    assert_equal "eligible", data["join_age"]
    assert_equal 16, data["join_min_age"]

    assert_difference("Player.count", 1) { join(s, token) }
    assert_response :success
  end

  test "a 13-year-old is refused, even with the box ticked" do
    s = survey
    token, data = finish(s, band: BAND["under_16"])
    assert_equal "too_young", data["join_age"]

    assert_no_difference "Player.count" do
      assert_equal "too_young", join(s, token, age_confirmed: true)["error"]
    end
    assert_response :forbidden
  end

  test "no age on record needs the box, and is let through with it" do
    s = survey(cards: [ { "type" => "yes_no", "text" => "Q?" } ])
    token, data = finish(s)
    assert_equal "unknown", data["join_age"]

    assert_no_difference("Player.count") { assert_equal "age_confirm", join(s, token)["error"] }
    assert_difference("Player.count", 1) { join(s, token, age_confirmed: true) }
  end

  test "a skipped age card counts as unknown, not as old enough" do
    s = survey
    token, data = finish(s)
    assert_equal "unknown", data["join_age"]
    assert_equal "age_confirm", join(s, token)["error"]
  end

  test "where the audience country sets 18, a 16-17 is too young and is told 18" do
    s = survey(audience_country: "IN")
    token, data = finish(s, band: BAND["16_17"])
    assert_equal "too_young", data["join_age"]
    assert_equal 18, data["join_min_age"]
    assert_equal "too_young", join(s, token, age_confirmed: true)["error"]
  end

  test "a Verto without the account ask says nothing about age" do
    s = survey(join_prompt_enabled: false)
    _token, data = finish(s, band: BAND["18_24"])
    assert_not data.key?("join_age")
  end

  test "Continue with Google from the card is held to the same rule" do
    ENV["GOOGLE_CLIENT_ID"] = "test-id"
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"
    s = survey
    token, = finish(s, band: BAND["under_16"])

    assert_no_difference "PlayerOauthHandoff.count" do
      post join_google_survey_path(s.publish_token),
           params: { session_token: token, age_confirmed: true }.to_json, headers: JSON_HEADERS
    end
    assert_response :forbidden
    assert_equal "too_young", JSON.parse(response.body)["error"]
  ensure
    ENV.delete("GOOGLE_CLIENT_ID")
    ENV.delete("GOOGLE_CLIENT_SECRET")
  end

  # The bare Google button on /you never asked an age, so it signs in an
  # account that exists and opens none.
  test "Google on /you signs an existing account in, but makes no new one" do
    with_auth_hash(uid: "gp-new", email: "nobody-yet@example.com") do
      assert_no_difference("Player.count") { get player_oauth_callback_path }
    end
    assert_redirected_to new_player_session_path
    assert_match "end of a Verto", flash[:alert]

    Player.create!(email_address: "already@example.com", password: PASSWORD)
    with_auth_hash(uid: "gp-old", email: "already@example.com") do
      assert_no_difference("Player.count") { get player_oauth_callback_path }
    end
    assert_redirected_to you_path
  end

  def with_auth_hash(uid:, email:)
    Rails.application.env_config["omniauth.auth"] = OmniAuth::AuthHash.new(
      provider: "google_player", uid: uid, info: { email: email, name: "Ren" },
      extra: { raw_info: { email_verified: true } }
    )
    yield
  ensure
    Rails.application.env_config.delete("omniauth.auth")
  end
end
