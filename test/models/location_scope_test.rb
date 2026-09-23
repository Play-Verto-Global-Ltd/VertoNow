require "test_helper"

class LocationScopeTest < ActiveSupport::TestCase
  NAIROBI = { "name" => "Nairobi", "country_code" => "KE", "bbox" => [ -1.44, -1.16, 36.66, 37.1 ] }.freeze
  LONDON  = { "name" => "London", "country_code" => "GB", "bbox" => [ 51.28, 51.69, -0.51, 0.33 ] }.freeze

  def location_card(extra = {})
    { "type" => "open_ended", "input" => "location", "text" => "Where do you live?", "demographic" => true }.merge(extra)
  end

  test "places are whitelisted and kept in the fixed order whatever order they were ticked in" do
    assert_equal %w[city town village], LocationScope.sanitize_places(%w[village bogus town city town])
    assert_equal [], LocationScope.sanitize_places(nil)
  end

  test "countries keep only real ISO codes, upcased, capped" do
    assert_equal %w[KE GB], LocationScope.sanitize_countries(%w[ke GB XX ke])
    assert_equal 10, LocationScope.sanitize_countries(WorldRegions::COUNTRIES.keys).size
  end

  test "cities need a name, a real country and a real box, and must sit inside the chosen countries" do
    bad_box  = NAIROBI.merge("bbox" => [ 5, 1, 0, 1 ])
    no_name  = NAIROBI.merge("name" => " ")
    kept = LocationScope.sanitize_cities([ NAIROBI, LONDON, bad_box, no_name, "junk", NAIROBI ])
    assert_equal %w[Nairobi London], kept.map { |c| c["name"] }

    assert_equal %w[Nairobi], LocationScope.sanitize_cities([ NAIROBI, LONDON ], countries: %w[KE]).map { |c| c["name"] }
  end

  test "Survey sanitiser keeps a location card's scope and drops what it can't use" do
    card = location_card("location_places" => %w[town city nope], "location_countries" => %w[ke],
                         "location_cities" => [ NAIROBI, LONDON ])
    out = Survey.sanitize_cards_images!([ card ]).first
    assert_equal %w[city town], out["location_places"]
    assert_equal %w[KE], out["location_countries"]
    assert_equal [ "Nairobi" ], out["location_cities"].map { |c| c["name"] }
  end

  test "Survey sanitiser drops empty keys and every key on a card that isn't a location card" do
    out = Survey.sanitize_cards_images!([ location_card("location_places" => [], "location_countries" => [ "XX" ]) ]).first
    refute out.key?("location_places")
    refute out.key?("location_countries")

    mc = { "type" => "multiple_choice", "text" => "Q", "options" => %w[a b], "location_places" => %w[city] }
    refute Survey.sanitize_cards_images!([ mc ]).first.key?("location_places")
  end

  test "countries only has no city limit — a country can't be inside a city" do
    card = location_card("location_places" => %w[country], "location_cities" => [ LONDON ])
    refute Survey.sanitize_cards_images!([ card ]).first.key?("location_cities")
    assert_equal [], LocationScope.for_card(card)[:cities]
  end

  test "for_card is empty for anything that isn't a location card" do
    assert_equal({ places: [], countries: [], cities: [] }, LocationScope.for_card(nil))
    assert_equal({ places: [], countries: [], cities: [] }, LocationScope.for_card({ "type" => "open_ended", "location_places" => %w[city] }))
  end

  test "labels follow the level the place was picked at; unscoped keeps the old city, region label" do
    hackney = { name: "Hackney", place_type: "borough", city: "London", region: "England" }
    assert_equal "Hackney, London", LocationScope.label_for(hackney, %w[district])
    assert_equal "London, England", LocationScope.label_for(hackney, [])

    assert_nil LocationScope.label_for({ name: "Kenya", place_type: "country" }, %w[country])
    assert_equal "Nakuru, Nakuru County",
                 LocationScope.label_for({ name: "Nakuru", place_type: "city", city: "Nakuru", region: "Nakuru County" }, %w[city])
    assert_equal "Bavaria", LocationScope.label_for({ name: "Bavaria", place_type: "state", region: "Bavaria" }, %w[region])
  end

  test "placeholder key: none keeps the original, one level names it, several say place" do
    assert_equal "player.region_search_placeholder", LocationScope.placeholder_key(nil)
    assert_equal "player.location_search_placeholder.country", LocationScope.placeholder_key(%w[country])
    assert_equal "player.location_search_placeholder.any", LocationScope.placeholder_key(%w[town village])
    LocationScope::PLACE_TYPES.each do |p|
      assert I18n.exists?("player.location_search_placeholder.#{p}", :en), p
      assert I18n.exists?("card.location_place.#{p}", :en), p
    end
  end
end
