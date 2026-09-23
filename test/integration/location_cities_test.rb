require "test_helper"

# The editor's "Limit to cities" picker for a location card (LocationScope).
class LocationCitiesTest < ActionDispatch::IntegrationTest
  NAIROBI = { name: "Nairobi", display_name: "Nairobi, Kenya", country_code: "KE", bbox: [ -1.44, -1.16, 36.66, 37.1 ] }.freeze

  def sign_in
    user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: user, role: "member")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "a signed-in creator gets cities with their boxes, narrowed to the chosen countries" do
    sign_in
    seen = nil
    stub_method(NominatimClient, :search_cities, ->(**kw) { seen = kw; [ NAIROBI ] }) do
      get location_cities_path, params: { q: "Nair", countries: [ "KE" ] }
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Nairobi", body["results"].first["name"]
    assert_equal [ -1.44, -1.16, 36.66, 37.1 ], body["results"].first["bbox"]
    assert_equal "Nair", seen[:query]
    assert_equal [ "KE" ], seen[:countries]
  end

  test "is not open to anyone who isn't signed in" do
    stub_method(NominatimClient, :search_cities, ->(**_kw) { raise "must not search" }) do
      get location_cities_path, params: { q: "Nair" }
    end
    assert_response :redirect
  end
end
