require "test_helper"

# The CSP is enforcing (not report-only) and carries the locked-down directives.
# A public page is enough — the header is applied app-wide by the middleware.
class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "an enforcing CSP header is set with the locked-down directives" do
    org = Organisation.create!(name: "CSP Co", slug: "csp-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.hex(8)
    )

    get play_survey_path(survey.publish_token)
    assert_response :success

    # Enforcing header, not the report-only variant.
    csp = response.headers["Content-Security-Policy"]
    assert csp.present?, "Content-Security-Policy header should be set"
    assert_nil response.headers["Content-Security-Policy-Report-Only"]

    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "base-uri 'self'"
    assert_includes csp, "form-action 'self'"
    assert_includes csp, "frame-ancestors 'self'"
    # No third-party script host: Microsoft Clarity, the one analytics vendor
    # that used to be allowlisted here, left the platform on 2026-10-01. Fonts
    # are self-hosted (public/fonts/), not loaded from Google's CDN, so no
    # external font host should be allowlisted either.
    script = csp.split(";").map(&:strip).find { |d| d.start_with?("script-src") }
    assert_equal "script-src 'self' 'unsafe-inline'", script
    assert_not_includes csp, "clarity.ms"
    assert_not_includes csp, "c.bing.com"
    assert_not_includes csp, "fonts.gstatic.com"
    assert_not_includes csp, "fonts.googleapis.com"
  end

  test "the Pexels CDNs are reachable by fetch(), not just by <img> and <video>" do
    get new_session_path
    csp = response.headers["Content-Security-Policy"].to_s
    connect = csp.split(";").map(&:strip).find { |d| d.start_with?("connect-src") }

    # The service worker refetches card art through the Fetch API, and a fetch()
    # is governed by connect-src whatever it is fetching. Listing Pexels only in
    # img-src/media-src left the worker's own request refused before it left the
    # browser, so every Pexels-backed card panel rendered empty.
    assert_includes connect, "https://images.pexels.com"
    assert_includes connect, "https://videos.pexels.com"
  end
end
