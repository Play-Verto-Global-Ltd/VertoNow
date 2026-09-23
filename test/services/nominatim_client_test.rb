require "test_helper"

class NominatimClientTest < ActiveSupport::TestCase
  PLACE = {
    "display_name" => "Austin, Travis County, Texas, United States",
    "address" => {
      "city" => "Austin",
      "state" => "Texas",
      "country" => "United States",
      "country_code" => "us"
    },
    "lat" => "30.267153",
    "lon" => "-97.7430608"
  }.freeze

  test "search normalizes a Nominatim place, never exposing lat/lon" do
    stub_method(NominatimClient, :get_json, ->(_url, _params) { [ PLACE ] }) do
      results = NominatimClient.search(query: "Austin")
      assert_equal 1, results.size
      place = results.first
      assert_equal "Austin", place[:city]
      assert_equal "Texas", place[:region]
      assert_equal "United States", place[:country]
      assert_equal "US", place[:country_code]
      assert_equal "Austin, Travis County, Texas, United States", place[:display_name]
      refute place.key?(:lat)
      refute place.key?(:lon)
    end
  end

  test "search returns [] for a too-short query without hitting the network" do
    stub_method(NominatimClient, :get_json, ->(_u, _p) { raise "should not be called" }) do
      assert_equal [], NominatimClient.search(query: "ab")
      assert_equal [], NominatimClient.search(query: "  ")
    end
  end

  test "search returns [] and never raises on error" do
    stub_method(NominatimClient, :get_json, ->(_u, _p) { raise "boom" }) do
      assert_equal [], NominatimClient.search(query: "somewhere-unique-#{SecureRandom.hex(4)}")
    end
  end

  test "search drops a place with no resolvable country" do
    stub_method(NominatimClient, :get_json, ->(_u, _p) { [ { "display_name" => "Nowhere", "address" => {} } ] }) do
      assert_equal [], NominatimClient.search(query: "nowhere-unique-#{SecureRandom.hex(4)}")
    end
  end

  test "search falls back through town/village and region/state_district when city/state are absent" do
    place = {
      "display_name" => "Hallstatt, Gmunden, Upper Austria, Austria",
      "address" => { "town" => "Hallstatt", "state_district" => "Gmunden", "country" => "Austria", "country_code" => "at" }
    }
    stub_method(NominatimClient, :get_json, ->(_u, _p) { [ place ] }) do
      result = NominatimClient.search(query: "hallstatt-unique-#{SecureRandom.hex(4)}").first
      assert_equal "Hallstatt", result[:city]
      assert_equal "Gmunden", result[:region]
      assert_equal "AT", result[:country_code]
    end
  end

  test "search hits the public Nominatim server when no LocationIQ key is set" do
    seen_url = seen_params = nil
    stub_method(NominatimClient, :get_json, ->(url, params) { seen_url = url; seen_params = params; [ PLACE ] }) do
      NominatimClient.search(query: "austin-#{SecureRandom.hex(4)}")
    end
    assert_equal "https://nominatim.openstreetmap.org/search", seen_url
    assert_equal "jsonv2", seen_params[:format]
    assert_nil seen_params[:key]
  end

  test "search routes through LocationIQ with the key when LOCATIONIQ_API_KEY is set" do
    seen_url = seen_params = nil
    with_env("LOCATIONIQ_API_KEY" => "test-key", "LOCATIONIQ_REGION" => "eu1") do
      stub_method(NominatimClient, :get_json, ->(url, params) { seen_url = url; seen_params = params; [ PLACE ] }) do
        NominatimClient.search(query: "austin-#{SecureRandom.hex(4)}")
      end
    end
    assert_equal "https://eu1.locationiq.com/v1/search", seen_url
    assert_equal "json", seen_params[:format]
    assert_equal "test-key", seen_params[:key]
  end

  test "an empty result is not cached, so a transient 403 never poisons a search term" do
    # Needs headroom in the app-wide outbound budget (P1-11): this makes two
    # network calls for the same term in one second, which the default 1/s
    # would legitimately skip. The subject here is cache poisoning, not the
    # throttle — that has its own tests below.
    with_memory_cache do
      ENV["GEOCODE_MAX_RPS"] = "50"
      query = "somewhere-#{SecureRandom.hex(4)}"
      calls = 0
      stub_method(NominatimClient, :get_json, ->(_u, _p) { calls += 1; calls == 1 ? [] : [ PLACE ] }) do
        assert_equal [], NominatimClient.search(query: query)  # first lookup fails (empty)
        refute_empty NominatimClient.search(query: query)      # retries — not served a cached []
        NominatimClient.search(query: query)                   # now served from cache
      end
      assert_equal 2, calls, "empty result must not be cached; the real hit should be"
    end
  ensure
    ENV.delete("GEOCODE_MAX_RPS")
  end

  test "a scoped search keeps only the chosen kinds of place" do
    region = PLACE.merge("display_name" => "Texas, United States", "name" => "Texas", "addresstype" => "state",
                         "address" => { "state" => "Texas", "country" => "United States", "country_code" => "us" })
    city = PLACE.merge("name" => "Austin", "addresstype" => "city")
    seen = nil
    stub_method(NominatimClient, :get_json, ->(_u, params) { seen = params; [ region, city ] }) do
      results = NominatimClient.search(query: "tex-#{SecureRandom.hex(4)}", places: %w[city town])
      assert_equal [ "Austin" ], results.map { |r| r[:name] }
    end
    assert_equal NominatimClient::MAX_FETCH, seen[:limit], "a filtered search over-fetches"
    assert_equal "settlement", seen[:featureType]
  end

  test "countries only asks Nominatim for countries, and a boundary result is typed off its address" do
    # LocationIQ's format=json has no addresstype, and a country drawn as a
    # boundary is type "administrative" — the address line naming it decides.
    germany = { "display_name" => "Deutschland", "type" => "administrative",
                "address" => { "country" => "Deutschland", "country_code" => "de" } }
    seen = nil
    stub_method(NominatimClient, :get_json, ->(_u, params) { seen = params; [ germany, PLACE ] }) do
      results = NominatimClient.search(query: "deu-#{SecureRandom.hex(4)}", places: %w[country], locale: "de")
      assert_equal [ "DE" ], results.map { |r| r[:country_code] }
      assert_equal "country", results.first[:place_type]
    end
    assert_equal "country", seen[:featureType]
    assert_equal "de", seen[:"accept-language"]
  end

  test "countries and cities narrow the request, and several cities filter by overlap without exposing a box" do
    nairobi = { "name" => "Nairobi", "country_code" => "KE", "bbox" => [ -1.44, -1.16, 36.66, 37.1 ] }
    mombasa = { "name" => "Mombasa", "country_code" => "KE", "bbox" => [ -4.1, -3.9, 39.5, 39.8 ] }
    inside  = { "display_name" => "Kibera, Nairobi, Kenya", "name" => "Kibera", "addresstype" => "suburb",
                "boundingbox" => %w[-1.33 -1.30 36.77 36.80],
                "address" => { "suburb" => "Kibera", "city" => "Nairobi", "country" => "Kenya", "country_code" => "ke" } }
    between = inside.merge("display_name" => "Kibwezi, Kenya", "name" => "Kibwezi", "boundingbox" => %w[-2.5 -2.3 37.9 38.1])
    seen = nil
    stub_method(NominatimClient, :get_json, ->(_u, params) { seen = params; [ inside, between ] }) do
      results = NominatimClient.search(query: "kib-#{SecureRandom.hex(4)}", countries: %w[KE], cities: [ nairobi, mombasa ])
      assert_equal [ "Kibera" ], results.map { |r| r[:name] }
      refute results.first.key?(:bbox)
      refute results.first.key?(:boundingbox)
    end
    assert_equal "ke", seen[:countrycodes]
    assert_equal "36.66,-1.16,39.8,-4.1", seen[:viewbox]
    assert_equal 1, seen[:bounded]
  end

  test "an unscoped search sends none of the scope parameters" do
    seen = nil
    stub_method(NominatimClient, :get_json, ->(_u, params) { seen = params; [ PLACE ] }) do
      NominatimClient.search(query: "aus-#{SecureRandom.hex(4)}")
    end
    assert_equal 5, seen[:limit]
    %i[countrycodes viewbox bounded featureType].each { |k| refute seen.key?(k), k }
  end

  test "the scope is part of the cache key" do
    refute_equal NominatimClient.send(:search_cache_key, "springfield", 5),
                 NominatimClient.send(:search_cache_key, "springfield", 5, %w[town], %w[US])
  end

  test "search_cities returns cities and towns with their box, and nothing else" do
    city = PLACE.merge("name" => "Austin", "addresstype" => "city", "boundingbox" => %w[30.09 30.52 -97.94 -97.56])
    village = PLACE.merge("display_name" => "Tiny, Texas", "name" => "Tiny", "addresstype" => "village",
                          "boundingbox" => %w[30 30.1 -97 -96.9])
    stub_method(NominatimClient, :get_json, ->(_u, _p) { [ city, village ] }) do
      results = NominatimClient.search_cities(query: "aus-#{SecureRandom.hex(4)}", countries: %w[US])
      assert_equal 1, results.size
      assert_equal "Austin", results.first[:name]
      assert_equal "US", results.first[:country_code]
      assert_equal [ 30.09, 30.52, -97.94, -97.56 ], results.first[:bbox]
    end
  end

  private

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  def with_env(vars)
    original = ENV.slice(*vars.keys)
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    vars.each_key { |k| original.key?(k) ? ENV[k] = original[k] : ENV.delete(k) }
  end

  # ── App-wide outbound budget (P1-11) ──────────────────────────────────────

  # Frozen clock: the budget window is one second wide, so without this a test
  # whose calls straddle a boundary silently gets a second budget and the
  # "must be skipped" assertions flake.
  def with_cache_and_rps(rps)
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:solid_cache_store)
    ENV["GEOCODE_MAX_RPS"] = rps.to_s
    SolidCache::Entry.delete_all
    travel_to(Time.utc(2026, 7, 30, 12, 0, 0)) { yield }
  ensure
    ENV.delete("GEOCODE_MAX_RPS")
    SolidCache::Entry.delete_all
    Rails.cache = previous
  end

  test "the outbound budget stops calls once the app-wide rate is spent" do
    calls = 0
    with_cache_and_rps(2) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { calls += 1; [ PLACE ] }) do
        # Distinct queries so the day-long result cache never serves them.
        assert NominatimClient.search(query: "Austin").any?
        assert NominatimClient.search(query: "Boston").any?
        assert_equal [], NominatimClient.search(query: "Chicago"),
                     "the third call in the same second must be skipped"
      end
    end
    assert_equal 2, calls, "only the calls inside the budget should reach the network"
  end

  test "a cached term costs no budget" do
    # The budget is checked AFTER the cache read on purpose: a cached term makes
    # no outbound call, so spending budget on it would throttle the app for
    # requests it never actually made.
    calls = 0
    with_cache_and_rps(1) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { calls += 1; [ PLACE ] }) do
        assert NominatimClient.search(query: "Austin").any?      # spends the budget
        assert NominatimClient.search(query: "Austin").any?      # served from cache
        assert NominatimClient.search(query: "Austin").any?
      end
    end
    assert_equal 1, calls
  end

  test "being over budget degrades to no suggestions rather than raising" do
    with_cache_and_rps(1) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { [ PLACE ] }) do
        NominatimClient.search(query: "Austin")
        assert_nothing_raised { NominatimClient.search(query: "Denver") }
        assert_equal [], NominatimClient.search(query: "Seattle")
      end
    end
  end

  test "an over-budget skip is not cached as an empty result" do
    # A skipped search must not poison the term for a full day — the existing
    # "only cache a real hit" rule is what protects this, so pin it.
    with_cache_and_rps(1) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { [ PLACE ] }) do
        NominatimClient.search(query: "Austin")
        assert_equal [], NominatimClient.search(query: "Lisbon")
      end
      # A later second, budget refreshed: the term resolves properly.
      travel 2.seconds
      SolidCache::Entry.delete_all
      stub_method(NominatimClient, :get_json, ->(_u, _p) { [ PLACE ] }) do
        assert NominatimClient.search(query: "Lisbon").any?,
               "the skipped term must not have been cached empty"
      end
    end
  end
end
