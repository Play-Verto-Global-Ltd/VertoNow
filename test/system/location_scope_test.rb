require "application_system_test_case"

# A location card narrowed by its creator (LocationScope): the editor panel
# that writes the narrowing, and the respondent's search that runs under it.
# The panel's buttons and chips exist only in the browser, and the autosave
# carries the narrowing only if the DOM round-trip does — neither is reachable
# below this layer.
class LocationScopeSystemTest < ApplicationSystemTestCase
  NAIROBI = { name: "Nairobi", display_name: "Nairobi, Kenya", country_code: "KE",
              bbox: [ -1.44, -1.16, 36.66, 37.1 ] }.freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "lsc-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Lsc", email_address: "lsc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def survey_with(extra = {})
    card = { "type" => "open_ended", "input" => "location", "cid" => "loc", "text" => "Where do you live?" }.merge(extra)
    @org.surveys.create!(title: "Places", theme: "Places", audience_age: "all", key_insight: "k",
                         default_locale: "en", locales: [ "en" ], cards: [ card ])
  end

  test "the creator narrows the search to kinds of place, a country and a city, and it saves" do
    survey = survey_with
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner

    find("[data-card-cid='loc'] .card-num-pill").click
    assert_selector ".editor-grid.is-panel-open"
    panel = find("[data-survey-editor-target='locationScope']", visible: true)

    panel.find(".response-scale-btn[data-place='town']").click
    panel.find(".response-scale-btn[data-place='village']").click
    assert_equal "true", panel.find(".response-scale-btn[data-place='town']")[:"aria-pressed"]
    # The card's own search box is the respondent's view of the setting.
    assert_equal I18n.t("player.location_search_placeholder.any"),
                 find("[data-card-cid='loc'] .location-search-field")[:placeholder]

    panel.find("[data-location-scope-target='countrySelect']").select("Kenya")
    assert_selector ".location-scope-chip", text: "Kenya"

    seen = nil
    stub_method(NominatimClient, :search_cities, ->(**kw) { seen = kw; [ NAIROBI ] }) do
      panel.find("[data-location-scope-target='cityInput']").fill_in(with: "Nair")
      panel.find(".location-search-result", text: "Nairobi, Kenya").click
    end
    assert_equal [ "KE" ], seen[:countries], "the city picker searches inside the chosen countries"
    assert_selector ".location-scope-chip", text: "Nairobi (KE)"

    saved = wait_until do
      card = survey.reload.cards.first
      card["location_places"] == %w[town village] && card["location_countries"] == %w[KE] &&
        card["location_cities"]&.map { |c| c["name"] } == %w[Nairobi]
    end
    assert saved, "autosave carries the narrowing: #{survey.reload.cards.first.slice("location_places", "location_countries", "location_cities").inspect}"

    # Country on its own is "countries only": no city limit to show or keep.
    panel.find(".response-scale-btn[data-place='town']").click
    panel.find(".response-scale-btn[data-place='village']").click
    panel.find(".response-scale-btn[data-place='country']").click
    assert_no_selector "[data-location-scope-target='citiesSection']", visible: true
    assert_equal I18n.t("player.location_search_placeholder.country"),
                 find("[data-card-cid='loc'] .location-search-field")[:placeholder]
    saved = wait_until do
      card = survey.reload.cards.first
      card["location_places"] == %w[country] && !card.key?("location_cities")
    end
    assert saved, "countries only keeps no city limit: #{survey.reload.cards.first.slice("location_places", "location_cities").inspect}"
  end

  test "the respondent's search is worded for, and runs under, the card's narrowing" do
    survey = survey_with("location_places" => %w[town], "location_countries" => %w[KE])
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    field = find(".preview-card.active .location-search-field", wait: 5)
    assert_equal I18n.t("player.location_search_placeholder.town"), field[:placeholder]

    seen = nil
    naivasha = { display_name: "Naivasha, Nakuru, Kenya", name: "Naivasha", place_type: "town",
                 city: "Naivasha", region: "Nakuru", country: "Kenya", country_code: "KE" }
    stub_method(NominatimClient, :search, ->(**kw) { seen = kw; [ naivasha ] }) do
      field.fill_in(with: "Naiv")
      assert_selector ".location-search-result", text: "Naivasha, Nakuru, Kenya"
    end
    assert_equal %w[town], seen[:places]
    assert_equal %w[KE], seen[:countries]
  end
end
