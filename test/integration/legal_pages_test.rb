require "test_helper"

class LegalPagesTest < ActionDispatch::IntegrationTest
  test "privacy, terms, and cookie policy pages are public and render a draft notice" do
    get privacy_path
    assert_response :success
    assert_select ".legal-draft-notice"
    assert_select "h1", text: I18n.t("legal.privacy_title")

    get terms_path
    assert_response :success
    assert_select ".legal-draft-notice"
    assert_select "h1", text: I18n.t("legal.terms_title")

    get cookie_policy_path
    assert_response :success
    assert_select ".legal-draft-notice"
    assert_select "h1", text: I18n.t("legal.cookie_policy_title")
  end

  test "an unauthenticated page (sign-in) links to the legal pages" do
    get new_session_path
    assert_response :success

    assert_select "footer.legal-footer" do
      assert_select "a[href=?]", privacy_path
      assert_select "a[href=?]", terms_path
      assert_select "a[href=?]", cookie_policy_path
      # No "Cookie settings" any more: the site sets only strictly necessary
      # cookies, so there is no choice to offer (NoThirdPartyTrackingTest).
      assert_select "button", false
    end
  end

  test "the public player has no legal footer (avoids cluttering its full-viewport UI)" do
    org = Organisation.create!(name: "Footer Co", slug: "footer-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.hex(8)
    )

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select "footer.legal-footer", false
  end
end
