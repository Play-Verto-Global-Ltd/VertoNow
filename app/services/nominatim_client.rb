require "net/http"
require "json"
require "uri"

# Thin wrapper around OpenStreetMap's Nominatim search API
# (https://nominatim.org/release-docs/latest/api/Search/), used for the
# respondent-facing "where are you" location search (a satnav-style
# type-ahead, replacing a free-text area field so location data groups
# reliably instead of by whatever a respondent happened to type).
#
# Privacy/GDPR note: this client deliberately never reads or returns Nominatim's
# `lat`/`lon` fields — only the resolved city/region/country. That omission,
# not a redaction step, is the guarantee that no precise coordinate or address
# ever enters this app's data model; storage stays exactly as coarse as the
# existing self-declared country+area fields it replaces.
#
# Two things read a result's `boundingbox`, and neither lets it out: a search
# narrowed to several cities compares each result's box with the cities' and
# then drops it, and the editor's city picker (search_cities) returns a
# CITY's box to the creator who is configuring a card. A respondent's pick is
# still resolved to names and nothing else.
#
# Provider: the public OpenStreetMap Nominatim server enforces a strict usage
# policy and, in practice, returns HTTP 403 for server-side calls from cloud /
# datacenter IPs — which is where this app runs. So when LOCATIONIQ_API_KEY is
# set the client routes searches through LocationIQ instead: a hosted Nominatim
# whose response shape is identical (so normalize/privacy below are unchanged)
# but which permits server-side use. Without the key it falls back to the public
# OSM server, keeping dev/test/CI key-free. Both instances serve OpenStreetMap
# data, so the "Search by OpenStreetMap" attribution credit near the results
# (see the welcome-intake view) stays accurate either way.
#
# A custom User-Agent identifies the app (required by both). The 3-char minimum
# query length, day-long cache of successful lookups and client-side debounce
# keep call volume low, and an app-wide budget (SharedRateLimiter, P1-11) caps
# the total outbound rate across every thread and process. The per-IP
# rate_limit on PlayerController#location_search bounds one respondent; this
# bounds the app, which is what the provider's usage policy is written about
# and what an IP ban would follow from.
class NominatimClient
  NOMINATIM_ENDPOINT  = "https://nominatim.openstreetmap.org/search".freeze
  # LocationIQ mirrors Nominatim's /search API; region is us1 (default) or eu1.
  LOCATIONIQ_ENDPOINT = "https://%<region>s.locationiq.com/v1/search".freeze
  TIMEOUT_SECS = 6
  MIN_QUERY_LEN = 3
  # Nominatim's public usage policy is an absolute maximum of 1 request/second;
  # LocationIQ's free tier is 2/second. Default to the stricter of the two and
  # let an operator raise it to match whatever plan they're actually on.
  DEFAULT_MAX_RPS = 1
  # How many results a narrowed search asks for before filtering down.
  MAX_FETCH = 10
  USER_AGENT   = "Playverto/1.0 (https://playverto.app; support@playverto.app)".freeze

  class << self
    # Returns an array of { display_name:, name:, place_type:, city:, region:,
    # country:, country_code: } (possibly empty). Never raises — any
    # network/parse/non-200 error is logged and yields [] so the search box just
    # shows no suggestions.
    #
    # The scope (see LocationScope) is the creator's narrowing of a location
    # card: `places` keeps only those kinds of place, `countries` and `cities`
    # keep the search inside them. All empty searches exactly as this always
    # did. `locale` asks for place names in the respondent's language.
    def search(query:, limit: 5, places: [], countries: [], cities: [], locale: nil)
      q = query.to_s.strip
      return [] if q.length < MIN_QUERY_LEN

      places    = LocationScope.sanitize_places(places)
      countries = LocationScope.sanitize_countries(countries)
      cities    = LocationScope.sanitize_cities(cities, countries: countries)
      locale    = locale.to_s.presence

      cache_key = search_cache_key(q, limit, places, countries, cities, locale)
      cached = Rails.cache.read(cache_key)
      return cached if cached

      # Checked AFTER the cache read, deliberately: a cached term makes no
      # outbound call, so it must not spend budget. Over the limit we return no
      # suggestions rather than sleeping — the search box is a type-ahead, the
      # respondent's next keystroke retries in a moment, and blocking a Puma
      # thread on a third-party quota is the failure mode P0-3 was about.
      unless limiter.allow?
        Rails.logger.info("[NominatimClient] outbound budget reached, skipping search")
        return []
      end

      # A narrowed search asks for more than it shows, because the type filter
      # below throws some away — ask for five and keep "towns only" and a
      # respondent typing a town that shares its name with a region might see
      # nothing at all.
      scoped = places.any? || cities.any?
      params = request_params(q, scoped ? MAX_FETCH : limit)
      params[:countrycodes] = (countries + cities.map { |c| c["country_code"] }).uniq.map(&:downcase).join(",") if countries.any? || cities.any?
      params[:"accept-language"] = locale if locale
      feature = feature_type_for(places)
      params[:featureType] = feature if feature
      if cities.any?
        s, n, w, e = union_bbox(cities.map { |c| c["bbox"] })
        params[:viewbox] = [ w, n, e, s ].join(",")
        params[:bounded] = 1
      end

      body    = Array(get_json(endpoint, params))
      body    = body.select { |place| inside_any?(place, cities) } if cities.size > 1
      results = body.filter_map { |place| normalize(place) }
      results = results.select { |r| places.include?(LocationScope.level_for(r[:place_type])) } if places.any?
      results = results.uniq { |r| r[:display_name] }.first(limit.to_i.clamp(1, 10))
      # Only cache a real hit — never let a transient outage or a 403 poison a
      # search term with an empty list for a full day.
      Rails.cache.write(cache_key, results, expires_in: 1.day) if results.any?
      results
    rescue => e
      ErrorReporting.report("NominatimClient", e)
      []
    end

    # The editor's city picker, for a creator narrowing a location card to one
    # or more cities. Returns [{ name:, display_name:, country_code:, bbox: }].
    #
    # This is the ONE place a box is read off a result, and it is the city's
    # own public boundary box, fetched for a creator configuring a card and
    # stored on that card — never anything about a respondent. search above
    # still returns no coordinate of any kind.
    def search_cities(query:, countries: [], locale: nil)
      q = query.to_s.strip
      return [] if q.length < MIN_QUERY_LEN

      countries = LocationScope.sanitize_countries(countries)
      cache_key = "geocode_cities:v1:#{provider}:#{countries.join(",")}:#{locale}:#{q.downcase}"
      cached = Rails.cache.read(cache_key)
      return cached if cached
      return [] unless limiter.allow?

      params = request_params(q, MAX_FETCH)
      params[:featureType] = "settlement"
      params[:countrycodes] = countries.map(&:downcase).join(",") if countries.any?
      params[:"accept-language"] = locale.to_s if locale.present?

      results = Array(get_json(endpoint, params)).filter_map do |place|
        norm = normalize(place)
        next unless norm && %w[city town].include?(LocationScope.level_for(norm[:place_type]))

        bbox = LocationScope.sanitize_bbox(place["boundingbox"])
        next unless bbox

        { name: norm[:name] || norm[:city], display_name: norm[:display_name],
          country_code: norm[:country_code], bbox: bbox }
      end.uniq { |c| c[:display_name] }.first(5)
      Rails.cache.write(cache_key, results, expires_in: 1.day) if results.any?
      results
    rescue => e
      ErrorReporting.report("NominatimClient", e)
      []
    end

    def max_rps
      Integer(ENV.fetch("GEOCODE_MAX_RPS", DEFAULT_MAX_RPS))
    rescue ArgumentError
      DEFAULT_MAX_RPS
    end

    private

    # Keyed per provider: switching to LocationIQ shouldn't inherit the budget
    # already spent against the public OSM server, and the two have different
    # published limits.
    def limiter
      SharedRateLimiter.new("geocode:#{provider}", per_second: max_rps)
    end

    # "locationiq" when a key is configured, else the public "nominatim" server.
    def provider
      ENV["LOCATIONIQ_API_KEY"].present? ? "locationiq" : "nominatim"
    end

    def endpoint
      if provider == "locationiq"
        format(LOCATIONIQ_ENDPOINT, region: ENV.fetch("LOCATIONIQ_REGION", "us1"))
      else
        NOMINATIM_ENDPOINT
      end
    end

    # Both back ends accept the same core params; LocationIQ needs the key and
    # its own `format=json` (vs Nominatim's `jsonv2`) — the response body is the
    # same either way, so normalize below is untouched.
    def request_params(q, limit)
      params = { q: q, addressdetails: 1, limit: limit.to_i.clamp(1, 10) }
      if provider == "locationiq"
        params[:format] = "json"
        params[:key]    = ENV["LOCATIONIQ_API_KEY"]
      else
        params[:format] = "jsonv2"
      end
      params
    end

    # Resolve one Nominatim place into the coarse shape this app stores.
    # Deliberately does not read place["lat"] / place["lon"].
    def normalize(place)
      address = place["address"] || {}
      country_code = address["country_code"].to_s.upcase.presence
      return nil unless country_code

      city = address["city"] || address["town"] || address["village"] ||
             address["municipality"] || address["county"]
      region = address["state"] || address["region"] || address["state_district"]

      {
        display_name: place["display_name"].to_s,
        name: place_name(place),
        place_type: place_type(place, address),
        city: city,
        region: region,
        country: address["country"],
        country_code: country_code
      }
    end

    # Every part of the scope is in the key: "Springfield" searched for towns
    # in the US and for anywhere at all are different answers.
    def search_cache_key(q, limit, places = [], countries = [], cities = [], locale = nil)
      scope = [ places.join(","), countries.join(","),
                cities.map { |c| "#{c["country_code"]}:#{c["bbox"].join(",")}" }.join(";"), locale ].join("|")
      "geocode_search:v3:#{provider}:#{scope}:#{q.downcase}:#{limit}"
    end

    # Nominatim's own coarse filter, sent only when every chosen level sits
    # inside one of its classes — it is a hint that saves the over-fetch being
    # spent on the wrong kind of place, and the type filter in search is what
    # actually decides. LocationIQ ignores parameters it doesn't know.
    def feature_type_for(places)
      return nil if places.empty?
      return "country" if places == %w[country]
      return "state" if places == %w[region]
      return "settlement" if (places - %w[city town village]).empty?

      nil
    end

    def place_name(place)
      place["name"].to_s.strip.presence || place["display_name"].to_s.split(",").first.to_s.strip.presence
    end

    # What kind of place a result is, in OSM's own tag. jsonv2 answers it
    # directly (`addresstype`). LocationIQ's `format=json` doesn't, and its
    # `type` for any place drawn as a boundary — most countries, regions and
    # many cities — is just "administrative"; so the fallback finds the address
    # line that names the place itself ("Germany" is the address's country).
    def place_type(place, address)
      return place["addresstype"].to_s if place["addresstype"].present?

      name = place_name(place)
      key  = address.find { |k, v| k != "country_code" && v.to_s == name }&.first
      key.presence || place["type"].to_s.presence
    end

    # The south/north/west/east box covering every chosen city.
    def union_bbox(boxes)
      [ boxes.map { |b| b[0] }.min, boxes.map { |b| b[1] }.max,
        boxes.map { |b| b[2] }.min, boxes.map { |b| b[3] }.max ]
    end

    # With several cities the request's viewbox is the box around all of them,
    # which for Nairobi and Mombasa is most of Kenya — so each result is kept
    # only if its own box overlaps one of the cities'. The result's box is read
    # for this comparison and dropped with the result; normalize never sees it.
    def inside_any?(place, cities)
      box = LocationScope.sanitize_bbox(place["boundingbox"])
      return false unless box

      cities.any? do |c|
        s, n, w, e = c["bbox"]
        box[0] <= n && box[1] >= s && box[2] <= e && box[3] >= w
      end
    end

    # Isolated HTTP seam so tests can stub a canned response.
    def get_json(url, params)
      uri = URI.parse(url)
      uri.query = URI.encode_www_form(params)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = TIMEOUT_SECS
      http.read_timeout = TIMEOUT_SECS

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = USER_AGENT
      req["Accept"]     = "application/json"

      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[NominatimClient] HTTP #{res.code} for query")
        return nil
      end
      JSON.parse(res.body)
    end
  end
end
