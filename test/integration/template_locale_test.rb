require "test_helper"

# Instantiating a template must produce a Verto IN the creator's language —
# default_locale set, title, cards and the appended demographic tail all
# resolved — not an English deck the creator then has to translate. The
# registry (SurveyTemplates::ALL) stays the English canon; translations merge
# positionally from `templates.<id>.cards` / `demographics.cards`.
class TemplateLocaleTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "T", email_address: "tl-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "tl-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "a template instantiated under a French UI starts as a French Verto" do
    post survey_template_path("csat"), params: { locale: "fr" }
    survey = @org.surveys.order(:created_at).last

    assert_equal "fr", survey.default_locale
    assert_equal [ "fr" ], survey.verto_locales
    assert_equal I18n.t("templates.csat.name", locale: :fr), survey.title
    refute_equal SurveyTemplates.find("csat")[:name], survey.title,
                 "the title stayed English — the locale never reached the instantiation"

    welcome = survey.cards.first
    assert_equal I18n.t("templates.csat.cards", locale: :fr).first[:text], welcome["text"]

    # The demographic tail follows too — this used to be English on every
    # Verto regardless of language.
    # The gender card specifically: the age slider is also a demographic card
    # carrying options now, so "the demographic one with options" is ambiguous.
    gender = survey.cards.find { |c| c["demographic"] && c["type"] == "multiple_choice" }
    assert gender, "no demographic options card appended"
    assert_equal I18n.t("demographics.cards", locale: :fr).last[:options].map(&:to_s), gender["options"]
    refute_includes gender["options"], "Prefer not to say"
  end

  test "an English UI still gets the registry's English, structurally unchanged" do
    post survey_template_path("csat")
    survey = @org.surveys.order(:created_at).last

    assert_equal "en", survey.default_locale
    assert_equal SurveyTemplates.find("csat")[:name], survey.title
    assert_equal SurveyTemplates.find("csat")[:cards].first["text"], survey.cards.first["text"]
    assert_equal "Prefer not to say",
                 survey.cards.find { |c| c["demographic"] && c["type"] == "multiple_choice" }["options"].last
  end

  test "a wrong-length translated options list is refused, not spliced" do
    # The merge must never shorten a scale: answers are positional. Stub a
    # broken translation and assert the English options survive whole.
    broken = SurveyTemplates.find("csat")[:cards].map { { "text" => "x" } }
    broken[1] = { "text" => "x", "options" => [ "a", "b" ] } # registry card has 5
    I18n.backend.store_translations(:fr, { templates: { csat: { cards: broken } } })

    cards = SurveyTemplates.cards_for("csat", locale: :fr)
    assert_equal SurveyTemplates.find("csat")[:cards][1]["options"], cards[1]["options"],
                 "a 2-entry translation replaced a 5-stop scale"
    assert_equal "x", cards[1]["text"], "the text part of the same entry should still merge"
  ensure
    I18n.backend.reload!
  end
end
