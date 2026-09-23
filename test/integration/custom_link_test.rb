require "test_helper"

class CustomLinkTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def published_survey(org, slug: nil)
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS, slug: slug,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "update_settings normalises and stores a custom slug" do
    org = sign_in_org("slug-set")
    s   = published_survey(org)

    post survey_settings_path(s), params: { slug: "  Summer Feedback 2026!!  " }
    assert_equal "summer-feedback-2026", s.reload.slug
    assert s.slug?
  end

  test "update_settings clears the slug when blank" do
    org = sign_in_org("slug-clear")
    s   = published_survey(org, slug: "existing-slug")

    post survey_settings_path(s), params: { slug: "   " }
    assert_nil s.reload.slug
    assert_not s.slug?
  end

  test "update_settings rejects a slug already taken by another survey" do
    org = sign_in_org("slug-taken")
    taken = published_survey(org, slug: "popular-name")
    s     = published_survey(org)

    post survey_settings_path(s), params: { slug: "Popular Name" }
    assert_nil s.reload.slug
    assert_includes response.headers["Location"], "slug_error=taken"
    assert_equal "popular-name", taken.reload.slug
  end

  test "update_settings rejects a slug colliding with another survey's publish_token" do
    org = sign_in_org("slug-vs-token")
    other = published_survey(org)
    # normalize_slug lowercases and hyphenates, so an ordinary mixed-case
    # base64 publish_token wouldn't collide with itself post-normalization —
    # use an already-normalized-looking token to exercise a realistic match.
    other.update_column(:publish_token, "already-lowercase-token")
    s = published_survey(org)

    post survey_settings_path(s), params: { slug: "already-lowercase-token" }
    assert_nil s.reload.slug
    assert_includes response.headers["Location"], "slug_error=taken"
  end

  test "a survey keeps its own slug when re-saving other settings" do
    org = sign_in_org("slug-keep")
    s   = published_survey(org, slug: "keep-me")

    post survey_settings_path(s), params: { slug: "keep-me" }
    assert_equal "keep-me", s.reload.slug
  end

  test "the player resolves a survey by its custom slug, and the token leads there" do
    org = sign_in_org("slug-play")
    s   = published_survey(org, slug: "play-me-now")

    get play_survey_path("play-me-now")
    assert_response :success
    assert_select ".q-title", text: "Q"

    # Links handed out before the slug existed still arrive — on the slug.
    get play_survey_path(s.publish_token)
    assert_redirected_to play_survey_path("play-me-now")
    follow_redirect!
    assert_select ".q-title", text: "Q"
  end

  test "a slug does not make an unpublished survey reachable" do
    org = sign_in_org("slug-draft")
    draft = org.surveys.create!(title: "Draft", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS, slug: "sneak-peek")
    assert_not draft.published?

    get play_survey_path("sneak-peek")
    assert_response :not_found
  end
end
