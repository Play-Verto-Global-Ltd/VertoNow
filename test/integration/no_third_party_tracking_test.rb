require "test_helper"

# Microsoft Clarity (session-replay analytics) left the platform on 2026-10-01,
# and with it the cookie-consent banner whose only job was gating it: the site
# now sets strictly necessary cookies only (the sign-in sessions, the locale),
# which need no consent. This keeps both out — a tracker that comes back
# through a layout, and a banner that comes back with nothing to gate. A new
# tracker brings the whole requirement back with it: prior consent, a banner
# to collect it, and its hosts in the CSP (docs/TOOLING_AND_VENDORS.md §6).
class NoThirdPartyTrackingTest < ActionDispatch::IntegrationTest
  def published_survey
    org = Organisation.create!(name: "Quiet Co", slug: "quiet-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.hex(8)
    )
  end

  def assert_no_tracking_in(body)
    assert_no_match(/clarity\.ms/, body, "a Microsoft Clarity loader is back")
    assert_no_match(/cookie-consent/, body, "a cookie-consent banner is back — there is nothing non-essential for it to gate")
  end

  test "the player loads no tracker and shows no cookie-consent banner" do
    get play_survey_path(published_survey.publish_token)
    assert_response :success
    assert_no_tracking_in response.body
  end

  test "neither does the sign-in page (the banner was site-wide, not just the player)" do
    get new_session_path
    assert_response :success
    assert_no_tracking_in response.body
  end

  test "the legal pages name no analytics vendor" do
    get privacy_path
    assert_response :success
    assert_no_match(/Clarity/, response.body)

    get cookie_policy_path
    assert_response :success
    assert_no_match(/Clarity/, response.body)
    assert_no_tracking_in response.body
  end
end
