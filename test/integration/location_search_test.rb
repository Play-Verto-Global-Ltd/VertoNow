require "test_helper"

class LocationSearchTest < ActionDispatch::IntegrationTest
  def published_survey
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ],
                        cards: [ { "type" => "welcome_card", "title" => "hi" } ],
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  RESULT = { display_name: "Austin, Texas, United States", city: "Austin", region: "Texas",
             country: "United States", country_code: "US" }.freeze

  test "returns the resolved country_code + label, built from city/region only" do
    s = published_survey
    stub_method(NominatimClient, :search, ->(**_kw) { [ RESULT ] }) do
      get player_location_search_path(s.publish_token), params: { q: "Austin" }
    end
    assert_response :success
    data = JSON.parse(response.body)
    assert data["ok"]
    assert_equal 1, data["results"].size
    r = data["results"].first
    assert_equal "US", r["country_code"]
    assert_equal "Austin, Texas", r["label"]
    assert_equal "Austin, Texas, United States", r["display_name"]
  end

  test "the search runs under the scope saved on the card, not one sent by the client" do
    s = published_survey
    s.update_columns(cards: s.cards + [ { "type" => "open_ended", "input" => "location", "text" => "Where?",
                                          "location_places" => [ "district" ], "location_countries" => [ "GB" ] } ])
    seen = nil
    hackney = { display_name: "Hackney, London, England, United Kingdom", name: "Hackney", place_type: "borough",
                city: "London", region: "England", country: "United Kingdom", country_code: "GB" }
    stub_method(NominatimClient, :search, ->(**kw) { seen = kw; [ hackney ] }) do
      get player_location_search_path(s.publish_token),
          params: { q: "Hack", card: 1, location_places: [ "country" ], location_countries: [ "US" ] }
    end
    assert_response :success
    assert_equal [ "district" ], seen[:places]
    assert_equal [ "GB" ], seen[:countries]
    assert_equal "en", seen[:locale]
    assert_equal "Hackney, London", JSON.parse(response.body)["results"].first["label"]
  end

  test "a countries-only card labels the pick with nothing but its country" do
    s = published_survey
    s.update_columns(cards: s.cards + [ { "type" => "open_ended", "input" => "location", "text" => "Where?",
                                          "location_places" => [ "country" ] } ])
    kenya = { display_name: "Kenya", name: "Kenya", place_type: "country", country: "Kenya", country_code: "KE" }
    stub_method(NominatimClient, :search, ->(**_kw) { [ kenya ] }) do
      get player_location_search_path(s.publish_token), params: { q: "Ken", card: 1 }
    end
    r = JSON.parse(response.body)["results"].first
    assert_equal "KE", r["country_code"]
    assert_nil r["label"]
  end

  test "the card is found by its cid, which wins over a wrong index" do
    # The editor and its Preview render no card index, only the cid — without
    # this a search there ran unscoped (seen on a live Verto, 2026-09-23).
    s = published_survey
    s.update_columns(cards: s.cards + [ { "type" => "open_ended", "input" => "location", "text" => "Where?",
                                          "cid" => "c_loc", "location_places" => [ "country" ] } ])
    seen = nil
    stub_method(NominatimClient, :search, ->(**kw) { seen = kw; [] }) do
      get player_location_search_path(s.publish_token), params: { q: "Germ", cid: "c_loc" }
      assert_equal [ "country" ], seen[:places], "cid alone"

      get player_location_search_path(s.publish_token), params: { q: "Germ", cid: "c_loc", card: 0 }
      assert_equal [ "country" ], seen[:places], "cid over a wrong index"

      get player_location_search_path(s.publish_token), params: { q: "Germ", cid: "nope" }
      assert_equal [], seen[:places], "an unknown cid and no index is unscoped"

      get player_location_search_path(s.publish_token), params: { q: "Germ", cid: "nope", card: 1 }
      assert_equal [ "country" ], seen[:places], "an unknown cid falls back to the index"
    end
  end

  test "a card index that isn't a location card searches unscoped" do
    s = published_survey
    seen = nil
    [ 0, 99, -1, "x" ].each do |card|
      stub_method(NominatimClient, :search, ->(**kw) { seen = kw; [] }) do
        get player_location_search_path(s.publish_token), params: { q: "Austin", card: card }
      end
      assert_response :success
      assert_equal [], seen[:places], card.inspect
      assert_equal [], seen[:cities], card.inspect
    end
  end

  test "the location scale leaves the cap unchanged at its default" do
    # PLAYER_LOCATION_RATE_LIMIT_SCALE is unset in test, which is the promise
    # the comment above the declaration makes: setting nothing changes nothing.
    assert_equal 1, PlayerController::LOCATION_RATE_LIMIT_SCALE
  end

  test "the location scale reaches location_search and nothing else" do
    source = File.read(Rails.root.join("app/controllers/player_controller.rb"))

    decl = source.lines.find { |l| l.include?('name: "location_search"') }
    assert_match(/\* LOCATION_RATE_LIMIT_SCALE/, decl,
                 "the per-IP location cap must carry its scale or a venue crowd hits it")

    recall = source.lines.find { |l| l.include?('name: "recall"') }
    refute_match(/RATE_LIMIT_SCALE/, recall,
                 "recall and eligibility bound a code-guessing oracle for PRIVACY, not a crowd — " \
                 "a bigger room is never a reason to allow more guesses")

    assert_match(
      /LOCATION_RATE_LIMIT_SCALE = ENV\.fetch\("PLAYER_LOCATION_RATE_LIMIT_SCALE", "1"\)\.to_i\.clamp\(1, 10_000\)/,
      source,
      "a scale of 0 multiplies the cap to zero and refuses every search — the clamp is what " \
      "makes an unset or mistyped value a no-op instead of an outage"
    )
  end

  test "a cached search term spends no outbound budget" do
    # This is the invariant that makes scaling the per-IP cap safe, so it is
    # pinned rather than trusted. The cap counts REQUESTS; the provider's usage
    # policy is about API CALLS; and NominatimClient reads its day-long cache
    # BEFORE it asks the limiter. If that order ever flips, raising the request
    # cap starts spending real quota and becomes a way to get the app IP-banned.
    tripwire = Object.new
    def tripwire.allow?
      raise "the outbound limiter must not be consulted for a cached term"
    end

    stub_method(Rails, :cache, ActiveSupport::Cache::MemoryStore.new) do
      Rails.cache.write(NominatimClient.send(:search_cache_key, "Austin", 5), [ RESULT ])
      stub_method(NominatimClient, :limiter, tripwire) do
        assert_equal [ RESULT ], NominatimClient.search(query: "Austin")
      end
    end
  end

  test "404s for an unknown token" do
    stub_method(NominatimClient, :search, ->(**_kw) { [] }) do
      get player_location_search_path("does-not-exist"), params: { q: "Austin" }
    end
    assert_response :not_found
  end

  test "surfaces an empty result set gracefully" do
    s = published_survey
    stub_method(NominatimClient, :search, ->(**_kw) { [] }) do
      get player_location_search_path(s.publish_token), params: { q: "zzz" }
    end
    assert_response :success
    assert_equal [], JSON.parse(response.body)["results"]
  end
end
