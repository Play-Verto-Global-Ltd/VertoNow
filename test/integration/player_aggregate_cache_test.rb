require "test_helper"

# The public aggregate endpoints (#results, #regions, #scores) are cached for
# a few seconds per survey so at burst scale the recompute happens per window,
# not per viewer. The suite's null cache store makes fetch a pass-through, so
# these tests swap in a MemoryStore to lock the caching contract, and lock the
# rewritten #regions shape (grouped COUNT + per-country batched aggregation)
# against what the old materialise-everything implementation returned.
class PlayerAggregateCacheTest < ActionDispatch::IntegrationTest
  # The small-cell line: under it #results serves the suppressed payload and
  # #regions drops the country, so the fixtures below clear it to cache a real
  # aggregate.
  MIN = Response::MIN_REGION_SAMPLE_SIZE

  def build_survey
    org = Organisation.create!(name: "O", slug: "agg-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] }
      ],
      show_results_comparison: true, regions_enabled: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def respond!(survey, value:, country: nil)
    survey.responses.create!(
      session_token: "agg-#{SecureRandom.hex(4)}", status: "completed",
      answers: { "1" => { "type" => "multiple_choice", "value" => value } },
      region_country: country
    )
  end

  test "results are served from the cache within a window and recompute after it clears" do
    survey = build_survey
    MIN.times { respond!(survey, value: "A") }

    stub_method(Rails, :cache, ActiveSupport::Cache::MemoryStore.new) do
      get player_results_path(survey.publish_token)
      first = JSON.parse(response.body)
      assert_equal MIN, first["total_responses"]
      refute first["suppressed"], "the fixture must clear the small-cell line, or the cache holds no aggregate"

      respond!(survey, value: "B")
      get player_results_path(survey.publish_token)
      assert_equal MIN, JSON.parse(response.body)["total_responses"],
                   "within the TTL the cached aggregate is served"

      Rails.cache.clear
      get player_results_path(survey.publish_token)
      assert_equal MIN + 1, JSON.parse(response.body)["total_responses"],
                   "after expiry the aggregate recomputes"
    end
  end

  test "a deck edit changes the cache key immediately, without waiting out the TTL" do
    survey = build_survey
    MIN.times { respond!(survey, value: "A") }

    stub_method(Rails, :cache, ActiveSupport::Cache::MemoryStore.new) do
      get player_results_path(survey.publish_token)
      assert_equal MIN, JSON.parse(response.body)["total_responses"]

      respond!(survey, value: "B")
      survey.touch
      get player_results_path(survey.publish_token)
      assert_equal MIN + 1, JSON.parse(response.body)["total_responses"]
    end
  end

  test "regions groups per country with small cells suppressed, sorted by responders" do
    survey = build_survey
    MIN.times { respond!(survey, value: "A", country: "GB") }
    2.times { respond!(survey, value: "B", country: "FR") } # below MIN — suppressed
    respond!(survey, value: "A") # untagged — counts nowhere

    get player_regions_path(survey.publish_token)
    body = JSON.parse(response.body)

    assert body["ok"]
    assert_equal MIN + 2, body["total_tagged"], "every tagged responder counts toward the total"
    assert_equal [ "GB" ], body["regions"].map { |r| r["country"] }
    gb = body["regions"].first
    assert_equal MIN, gb["responders"]
    row = gb["results"].find { |r| r["index"] == 1 }
    assert_equal MIN, row["counts"].values.sum, "the per-country aggregation covers that country's answers"
  end
end
