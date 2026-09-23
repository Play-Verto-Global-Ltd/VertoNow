# What a creator has narrowed a location card's search to, and the one
# definition of the vocabulary that narrowing is written in.
#
# Three optional keys ride on an `open_ended` + `input: "location"` card:
#
#   location_places    — which KINDS of place the search offers, any mix of
#                        PLACE_TYPES. Absent means any place, which is what
#                        every card did before this existed.
#   location_countries — ISO codes the search stays inside.
#   location_cities    — cities the search stays inside, each
#                        { "name", "country_code", "bbox" => [s, n, w, e] }.
#
# The levels are deliberately few and named for what they are everywhere
# rather than in one country: a "county" is a region in England and a
# district in Kenya, a "borough" is a district of London and a town in
# Pennsylvania, so the list is six levels and each one gathers the OSM tags
# that mean it (see OSM_TYPES). A creator in Lagos and one in Leeds read the
# same six buttons the same way.
#
# The stored ANSWER is unchanged — still "CC|Label" (see
# PlayerController#sync_region_from_answers!). Only the label's shape follows
# the scope: a countries-only card stores "FR|", which already reads as
# "France" everywhere an answer is shown.
#
# A city's bbox is the city's public boundary box, fetched once when the
# creator picks it and stored on the CARD. It is configuration, not a
# respondent's data — NominatimClient still never reads a result's lat/lon,
# and nothing finer than a place name ever reaches a response.
module LocationScope
  PLACE_TYPES = %w[country region city town village district].freeze

  # Nominatim's `addresstype` (jsonv2) / `type` values each level accepts.
  OSM_TYPES = {
    "country"  => %w[country],
    "region"   => %w[state province region county state_district],
    "city"     => %w[city],
    "town"     => %w[town municipality],
    "village"  => %w[village hamlet],
    "district" => %w[borough city_district district suburb quarter neighbourhood]
  }.freeze

  MAX_COUNTRIES = 10
  MAX_CITIES    = 10
  MAX_CITY_NAME = 80

  module_function

  def location_card?(card)
    card.is_a?(Hash) && card["type"].to_s == "open_ended" && card["input"].to_s == "location"
  end

  def countries_only?(places)
    Array(places) == [ "country" ]
  end

  # Kept in PLACE_TYPES order, so the same choice always stores the same array
  # (and the search cache is keyed the same whichever order it was ticked in).
  def sanitize_places(value)
    wanted = Array(value).map(&:to_s)
    PLACE_TYPES.select { |t| wanted.include?(t) }
  end

  def sanitize_countries(value)
    Array(value).map { |c| c.to_s.upcase }.select { |c| WorldRegions.valid?(c) }.uniq.first(MAX_COUNTRIES)
  end

  # A city outside the chosen countries is dropped rather than kept: "Kenya,
  # but also Paris" is not a narrowing, and the editor's city search is
  # already confined to the chosen countries, so only a stale client or a
  # country removed after the city was added can produce one.
  def sanitize_cities(value, countries: [])
    Array(value).filter_map do |c|
      next unless c.is_a?(Hash)

      name = c["name"].to_s.strip.first(MAX_CITY_NAME)
      code = c["country_code"].to_s.upcase
      bbox = sanitize_bbox(c["bbox"])
      next if name.blank? || bbox.nil? || !WorldRegions.valid?(code)
      next if countries.any? && !countries.include?(code)

      { "name" => name, "country_code" => code, "bbox" => bbox }
    end.uniq { |c| [ c["name"].downcase, c["country_code"] ] }.first(MAX_CITIES)
  end

  # [south, north, west, east] as floats, the order Nominatim's `boundingbox`
  # uses; nil unless it is four finite numbers describing a real box.
  def sanitize_bbox(value)
    nums = Array(value).map { |v| Float(v, exception: false) }
    return nil unless nums.size == 4 && nums.all? { |n| n&.finite? }

    s, n, w, e = nums
    return nil unless s.between?(-90, 90) && n.between?(-90, 90) && w.between?(-180, 180) && e.between?(-180, 180)
    return nil unless s < n && w < e

    nums.map { |v| v.round(5) }
  end

  # Rewrites the three keys in place on a card from the editor, dropping each
  # one that is empty — and all three from a card that isn't a location card.
  def sanitize_card!(card)
    return card unless card.is_a?(Hash)

    unless location_card?(card)
      card.delete("location_places")
      card.delete("location_countries")
      card.delete("location_cities")
      return card
    end

    places    = sanitize_places(card["location_places"])
    countries = sanitize_countries(card["location_countries"])
    # A country can't be found inside a city, so a countries-only card has no
    # city limit to keep.
    cities = countries_only?(places) ? [] : sanitize_cities(card["location_cities"], countries: countries)

    { "location_places" => places, "location_countries" => countries, "location_cities" => cities }.each do |key, val|
      val.any? ? card[key] = val : card.delete(key)
    end
    card
  end

  # The scope a search runs under, read off a saved card. Anything that isn't
  # a location card has no scope — which searches exactly as before.
  def for_card(card)
    return { places: [], countries: [], cities: [] } unless location_card?(card)

    places    = sanitize_places(card["location_places"])
    countries = sanitize_countries(card["location_countries"])
    cities    = countries_only?(places) ? [] : sanitize_cities(card["location_cities"], countries: countries)
    { places: places, countries: countries, cities: cities }
  end

  # Which of PLACE_TYPES a normalised place is, or nil when its tag is one
  # none of them claims (a road, a shop, a postcode area).
  def level_for(place_type)
    t = place_type.to_s
    OSM_TYPES.find { |_, tags| tags.include?(t) }&.first
  end

  # The label stored after the country code. Unscoped cards keep exactly the
  # label they always had ("city, region"); a scoped card labels the place at
  # the level the respondent picked it at.
  def label_for(place, places)
    return legacy_label(place) if Array(places).empty?

    parts =
      case level_for(place[:place_type])
      when "country"                  then []
      when "region"                   then [ place[:name] || place[:region] ]
      when "city", "town", "village"  then [ place[:name] || place[:city], place[:region] ]
      when "district"                 then [ place[:name], place[:city] || place[:region] ]
      else [ place[:city], place[:region] ]
      end
    parts.compact_blank.uniq.join(", ").first(60).presence
  end

  def legacy_label(place)
    [ place[:city], place[:region] ].compact_blank.join(", ").first(60).presence
  end

  # The player's search-box placeholder key for a card's places: one level
  # gets its own sentence, several get the generic "place", none keeps the
  # card's original wording.
  def placeholder_key(places)
    places = sanitize_places(places)
    case places.size
    when 0 then "player.region_search_placeholder"
    when 1 then "player.location_search_placeholder.#{places.first}"
    else        "player.location_search_placeholder.any"
    end
  end
end
