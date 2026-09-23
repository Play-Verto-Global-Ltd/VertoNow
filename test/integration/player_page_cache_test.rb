require "test_helper"

# PlayerController#show serves the rendered player HTML from Rails.cache
# (cached_play_page): the same bytes for every respondent on a given link +
# resolved locale, busted by anything that changes those bytes. The suite runs
# on the null cache store (fetch is a pass-through), so swap in a real store to
# observe the caching itself.
class PlayerPageCacheTest < ActionDispatch::IntegrationTest
  def published_survey(theme: "Sports")
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: theme, theme: theme, audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] } ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))
    survey
  end

  def with_memory_cache
    old = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = old
  end

  test "the play page is served from cache and a republish busts it" do
    survey = published_survey(theme: "Sports")

    with_memory_cache do
      get play_survey_path(survey.publish_token)
      assert_response :success
      assert_includes @response.body, "Sports", "first render reaches the deck's theme"

      # Change a rendered field WITHOUT bumping updated_at: the key is unchanged,
      # so the cached bytes must still be served.
      survey.update_columns(theme: "Cricket")
      get play_survey_path(survey.publish_token)
      assert_response :success
      assert_includes @response.body, "Sports", "unchanged updated_at → still the cached page"
      assert_not_includes @response.body, "Cricket"

      # A real edit bumps updated_at → the key changes → re-render.
      survey.touch
      get play_survey_path(survey.publish_token)
      assert_response :success
      assert_includes @response.body, "Cricket", "a republish re-renders the page"
    end
  end

  test "the cache key separates two links to the same Verto" do
    survey = published_survey(theme: "Sports")
    link = survey.survey_links.create!(slug: "vanity-#{SecureRandom.hex(3)}", name: "Q1")

    with_memory_cache do
      get play_survey_path(survey.publish_token)
      assert_response :success
      body_via_token = @response.body

      get play_survey_path(link.slug)
      assert_response :success
      # Each link embeds its own token in every data-*-url the shell reads, so
      # the two responses are cached separately and each carries its own token.
      assert_includes body_via_token, survey.publish_token
      assert_includes @response.body, link.slug
    end
  end
def with_local_page_cache
  old = PlayerController.player_page_local_cache
  PlayerController.player_page_local_cache = ActiveSupport::Cache::MemoryStore.new
  yield
ensure
  PlayerController.player_page_local_cache = old
end

test "each process keeps its own copy, so the shared store is off the page's hot path" do
  survey = published_survey(theme: "Sports")

  with_memory_cache do
    with_local_page_cache do
      get play_survey_path(survey.publish_token)
      assert_response :success
      assert_includes @response.body, "Sports"

      # The shared store loses everything (a Key Value blip, a flush) and the
      # row changes without bumping updated_at: the page is still served, from
      # the process-local copy, with no re-render.
      Rails.cache.clear
      survey.update_columns(theme: "Cricket")
      get play_survey_path(survey.publish_token)
      assert_includes @response.body, "Sports"
      refute_includes @response.body, "Cricket"

      # A republish changes the key; the local copy is bypassed like any other.
      survey.touch
      get play_survey_path(survey.publish_token)
      assert_includes @response.body, "Cricket"
    end
  end
end

# The shared store outlives a deploy, and the page names its stylesheets and
# scripts by digest: a page from the previous build points at files the new
# image doesn't carry, which renders bare and unscripted.
test "a new build never serves the previous build's page" do
  survey = published_survey(theme: "Sports")
  old_build = PlayerController.player_page_build

  with_memory_cache do
    with_local_page_cache do
      PlayerController.player_page_build = "build-a"
      get play_survey_path(survey.publish_token)
      assert_includes @response.body, "Sports"

      # Same deck, same key in every other respect — only the build moved.
      survey.update_columns(theme: "Cricket")
      PlayerController.player_page_build = "build-b"
      get play_survey_path(survey.publish_token)
      assert_includes @response.body, "Cricket", "a new build re-renders rather than reusing build-a's bytes"
    end
  end
ensure
  PlayerController.player_page_build = old_build
end

test "the opaque link sends a respondent to the custom link, query and all" do
  survey = published_survey
  survey.update!(slug: "vanity-#{SecureRandom.hex(3)}")

  get play_survey_path(survey.publish_token, lang: "fr", utm_source: "whatsapp")
  assert_redirected_to play_survey_path(survey.slug, lang: "fr", utm_source: "whatsapp")
  assert_equal 302, response.status

  get play_survey_path(survey.slug)
  assert_response :success
end

test "without a custom link the opaque link is the page" do
  survey = published_survey
  get play_survey_path(survey.publish_token)
  assert_response :success
end

test "a named share link is never redirected to the custom link" do
  survey = published_survey
  survey.update!(slug: "vanity-#{SecureRandom.hex(3)}")
  link = survey.survey_links.create!(slug: "named-#{SecureRandom.hex(3)}", name: "Q1")

  get play_survey_path(link.slug)
  assert_response :success
end

test "a page open on the opaque link still submits after the custom link is set" do
  survey = published_survey
  survey.update!(slug: "vanity-#{SecureRandom.hex(3)}")

  post submit_survey_path(survey.publish_token),
       params: { answers: { "1" => { "value" => "a" } } }.to_json,
       headers: { "CONTENT_TYPE" => "application/json" }
  assert_not_equal 302, response.status
  assert_response :success
end
end
