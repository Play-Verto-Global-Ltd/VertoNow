require "test_helper"

# The contact gate end to end: the player-side pseudo-card, the details riding
# the ordinary save payload into their own table, the leaderboard-name linkage,
# the settings refusal, the admin CSV, and erasure.
class ContactGateTest < ActionDispatch::IntegrationTest
  CARDS = [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ].freeze

  def sign_in_admin(org)
    user = User.create!(name: "U", email_address: "cg-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    user
  end

  def live_survey(contact: true, cards: CARDS.map(&:dup), org: nil)
    org ||= Organisation.create!(name: "O", slug: "cg-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards,
      contact_form_enabled: contact,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  test "the gate is the server-active first card when enabled, and absent when not" do
    s = live_survey
    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "div.preview-card.active[data-card-type=contact_gate_card]", 1
    assert_select "div.preview-card.active", 1
    assert_match "Leave your details", response.body

    off = live_survey(contact: false)
    get play_survey_path(off.publish_token)
    assert_select "[data-card-type=contact_gate_card]", 0
  end

  test "the gate's privacy link opens the published policy" do
    get play_survey_path(live_survey.publish_token)
    assert_select "[data-card-type=contact_gate_card] .play-consent-legal a[href=?]", privacy_policy_url
  end

  test "contact details ride the save into their own table, never into answers" do
    s = live_survey
    key = SecureRandom.uuid

    post progress_survey_path(s.publish_token),
         params: { session_token: "t1", answers: { "0" => "Yes" }, player_key: key,
                   contact: { name: "Ada Lovelace", email: "ada@x.com", industry: "Computing" } },
         as: :json
    assert_response :success

    digest = s.player_key_digest(key)
    contact = s.contact_details.find_by(key_digest: digest)
    assert contact, "the contact row is keyed by the same digest as the leaderboard alias"
    assert_equal "Ada Lovelace", contact.name
    assert_equal "Computing", contact.industry

    resp = s.responses.find_by(session_token: "t1")
    assert_equal({ "0" => "Yes" }, resp.answers, "answers hold answers only")
    assert_equal digest, resp.player_key_digest, "identity recorded even with the leaderboard off"
    assert_equal 1, s.contact_details.count

    # Riding every save is idempotent, and a later save can fill fields in.
    post submit_survey_path(s.publish_token),
         params: { session_token: "t1", answers: { "0" => "Yes" }, player_key: key,
                   contact: { name: "Ada Lovelace", company: "Analytical Engines" } },
         as: :json
    assert_response :success
    assert_equal 1, s.contact_details.count
    assert_equal "Analytical Engines", contact.reload.company
  end

  test "details are refused while the gate is off, and dropped without an identity" do
    off = live_survey(contact: false)
    post progress_survey_path(off.publish_token),
         params: { session_token: "t2", answers: { "0" => "Yes" }, player_key: SecureRandom.uuid,
                   contact: { name: "Nope" } }, as: :json
    assert_response :success
    assert_equal 0, off.contact_details.count

    on = live_survey
    post progress_survey_path(on.publish_token),
         params: { session_token: "t3", answers: { "0" => "Yes" }, contact: { name: "No key" } }, as: :json
    assert_response :success
    assert_equal 0, on.contact_details.count, "no player key, no identity, no row"
  end

  NEURO_CARD = { "type" => "select_many", "text" => "N", "options" => [ "A", "B" ],
                 "demographic" => true, "demographic_key" => "neurodiversity" }.freeze

  test "the settings toggle is refused while the deck asks neurodiversity — and allowed beside the rest of the tail" do
    org = Organisation.create!(name: "O", slug: "cg-set-#{SecureRandom.hex(3)}")
    sign_in_admin(org)
    s = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: CARDS.map(&:dup) + [ NEURO_CARD.dup ]
    )

    post survey_settings_path(s), params: { contact_form_enabled: "1" }
    assert_redirected_to survey_path(s, panel: "publish", contact_error: "neurodiversity")
    assert_not s.reload.contact_form_enabled?

    tail_only = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: DemographicQuestions.append_to(CARDS.map(&:dup))
    )
    post survey_settings_path(tail_only), params: { contact_form_enabled: "1" }
    assert tail_only.reload.contact_form_enabled?, "age/location/gender beside a contact form is allowed"
  end

  test "the card autosave relays the wall's message when neurodiversity tries to join a contact Verto" do
    org = Organisation.create!(name: "O", slug: "cg-auto-#{SecureRandom.hex(3)}")
    sign_in_admin(org)
    s = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
      contact_form_enabled: true
    )

    patch survey_path(s),
          params: { cards: s.cards + [ NEURO_CARD.dup ] }.to_json,
          headers: { "Content-Type" => "application/json" }
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/never both/, body["error"])
    assert_not s.reload.neurodiversity_cards?

    # The scoped wall lets the ordinary tail through the same door.
    patch survey_path(s),
          params: { cards: s.cards + [ { "type" => "multiple_choice",
                                         "text" => "What gender best describes you?",
                                         "options" => [ "A", "B" ], "demographic" => true } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
    assert_response :success
    assert s.reload.demographic_cards?
  end

  test "the contacts CSV is admin-only and carries the leaderboard name for the same identity" do
    org = Organisation.create!(name: "O", slug: "cg-csv-#{SecureRandom.hex(3)}")
    sign_in_admin(org)
    s = live_survey(org: org)
    s.update!(tokenisation_enabled: true, leaderboard_enabled: true)
    ContactDetail.upsert_for!(survey: s, key_digest: s.player_key_digest("k1"), fields: { "name" => "Ada", "email" => "ada@x.com" })

    get survey_contacts_path(s, format: :csv)
    assert_response :success
    assert_equal "text/csv", response.media_type
    lines = response.body.lines
    assert_equal "leaderboard_name,name,company,industry,email,added", lines.first.strip
    row = CSV.parse_line(lines.last)
    assert_equal "Ada", row[1]
    assert row[0].present?, "the alias is minted for the CSV exactly as the results page mints it"
    assert_equal row[0], s.player_aliases.find_by(key_digest: s.player_key_digest("k1")).anon_name
  end

  test "the contacts CSV needs an admin" do
    org  = Organisation.create!(name: "O", slug: "cg-mem-#{SecureRandom.hex(3)}")
    user = User.create!(name: "M", email_address: "cg-m-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org.memberships.create!(user: user, role: "member")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    s = live_survey(org: org)

    get survey_contacts_path(s, format: :csv)
    assert_response :redirect
  end

  test "erasing a respondent erases their contact row and alias with them" do
    org = Organisation.create!(name: "O", slug: "cg-gdpr-#{SecureRandom.hex(3)}")
    sign_in_admin(org)
    s = live_survey(org: org)
    key = SecureRandom.uuid
    post progress_survey_path(s.publish_token),
         params: { session_token: "t9", answers: { "0" => "Yes" }, player_key: key,
                   contact: { name: "Erase Me", email: "e@x.com" } }, as: :json
    digest = s.player_key_digest(key)
    PlayerAlias.ensure_for!(survey: s, key_digest: digest)

    delete survey_respondent_data_path(s), params: { session_token: "t9" }
    assert_redirected_to survey_respondent_data_path(s)
    assert_equal 0, s.responses.where(session_token: "t9").count
    assert_equal 0, s.contact_details.where(key_digest: digest).count
    assert_equal 0, s.player_aliases.where(key_digest: digest).count
  end

  test "the subject-access export includes the contact row" do
    s = live_survey
    key = SecureRandom.uuid
    post progress_survey_path(s.publish_token),
         params: { session_token: "t10", answers: { "0" => "Yes" }, player_key: key,
                   contact: { name: "Seen", industry: "Arts" } }, as: :json

    data = RespondentDataExport.call(survey: s, responses: s.responses.where(session_token: "t10"))
    contact = Array(data["contact_details"]).first
    assert contact, "Article 15 export must carry the contact row"
    assert_equal "Seen", contact["name"]
    assert_equal "Arts", contact["industry"]
  end
end
