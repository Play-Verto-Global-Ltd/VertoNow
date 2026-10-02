require "test_helper"

class ResultsCompareTest < ActionDispatch::IntegrationTest
  # The small-cell line a country segment must clear to be offered.
  MIN = Response::MIN_REGION_SAMPLE_SIZE

  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Do you like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  def create_org_and_sign_in(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def create_survey(org)
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def seed_region(survey, country, label, count)
    count.times do |i|
      survey.responses.create!(session_token: "#{country}-#{label}-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                               region_country: country, region_label: label,
                               answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end
  end

  test "segments group by country, not sub-region label" do
    org = create_org_and_sign_in("group")
    s   = create_survey(org)
    seed_region(s, "US", "Austin, Texas", 5)
    seed_region(s, "US", "Dallas", 5)

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    assert data["ok"]
    region_segments = data["segments"].select { |seg| seg["id"] == "region_US" }
    assert_equal 1, region_segments.size
    region = region_segments.first
    assert_equal "🌍 United States", region["label"]
    assert_equal 10, region["count"]
  end

  test "no geocoding keys appear anywhere in the response" do
    org = create_org_and_sign_in("no-geo")
    s   = create_survey(org)
    seed_region(s, "US", "Austin, Texas", 5)

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    refute data.key?("bounds")
    data["segments"].each do |seg|
      refute seg.key?("lat")
      refute seg.key?("lng")
      refute seg.key?("boundary")
    end
  end

  test "sub-region labels below the per-label threshold combine to clear country-level suppression" do
    org = create_org_and_sign_in("combine")
    s   = create_survey(org)
    seed_region(s, "GB", "Yorkshire", MIN - 2)
    seed_region(s, "GB", "London", 2)

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    region = data["segments"].find { |seg| seg["id"] == "region_GB" }
    assert region, "expected a combined GB segment"
    assert_equal MIN, region["count"]
    assert data["aggregates"].key?("region_GB")
  end

  # The published floor is for people outside the organisation. The one
  # that ran the Verto sees every country it has answers from, however few
  # (ResolvesResultSegments::OWNER_FLOOR, owner's instruction 2026-10-02).
  test "a country below the published floor still gets its own segment on the organisation's own page" do
    org = create_org_and_sign_in("below-floor")
    s   = create_survey(org)
    seed_region(s, "GB", "Yorkshire", 4)

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    region = data["segments"].find { |seg| seg["id"] == "region_GB" }
    assert region, "four respondents in one country are the organisation's own to look at"
    assert_equal 4, region["count"]
  end

  test "two different countries produce two segments" do
    org = create_org_and_sign_in("two-countries")
    s   = create_survey(org)
    seed_region(s, "US", "Austin, Texas", MIN)
    seed_region(s, "GB", "Yorkshire", MIN)

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    region_ids = data["segments"].map { |seg| seg["id"] }.select { |id| id.start_with?("region_") }
    assert_equal [ "region_GB", "region_US" ], region_ids.sort
  end

  test "open-ended aggregates include the raw per-segment texts, not just a count" do
    org = create_org_and_sign_in("open-text")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ],
                              cards: CARDS + [ { "type" => "open_ended", "text" => "Anything else?" } ],
                              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    s.responses.create!(session_token: "gb-#{SecureRandom.hex(3)}", status: "completed",
                        region_country: "GB",
                        answers: { "2" => { "type" => "open_ended", "value" => "More benches please" } })
    # Padding so GB clears the small-cell line and gets a segment at all.
    (MIN - 1).times do |i|
      s.responses.create!(session_token: "gb-pad-#{i}-#{SecureRandom.hex(2)}", status: "completed",
                          region_country: "GB", answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    region_agg = data["aggregates"]["region_GB"][2]
    assert_equal [ "More benches please" ], region_agg["texts"]
    refute data["cards"][2]["demographic"], "a plain open_ended question isn't the demographic tail"
  end

  test "the demographic location/birth-month cards are flagged so the client skips AI summarising them" do
    org = create_org_and_sign_in("demographic-flag")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ],
                              cards: CARDS + DemographicQuestions.cards,
                              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    location_card = data["cards"].find { |c| c["text"] == "Where do you live?" }
    assert location_card["demographic"]
  end

  test "the overall segment is always present and unaffected by region grouping" do
    org = create_org_and_sign_in("overall")
    s   = create_survey(org)
    s.responses.create!(session_token: "plain-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })

    get survey_results_compare_path(s)
    assert_response :success

    overall = JSON.parse(response.body)["segments"].find { |seg| seg["id"] == "overall" }
    assert overall
    refute overall.key?("lat")
  end

  test "wave segments carry their own per-wave aggregates, same shape as any other segment" do
    org = create_org_and_sign_in("waves")
    s   = create_survey(org)
    s.responses.create!(session_token: "w1-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    s.start_next_wave!
    s.responses.create!(session_token: "w2-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "No" } }, survey_wave_id: s.current_wave.id)

    get survey_results_compare_path(s)
    assert_response :success

    data = JSON.parse(response.body)
    wave_ids = data["segments"].map { |seg| seg["id"] }.select { |id| id.start_with?("wave_") }
    assert_equal %w[wave_1 wave_2], wave_ids
    assert data["aggregates"].key?("wave_1")
    assert data["aggregates"].key?("wave_2")
  end

  test "the compare box mounts and preselects waves even with no region data at all" do
    org = create_org_and_sign_in("waves-only")
    s   = create_survey(org)
    s.responses.create!(session_token: "a-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    s.start_next_wave!
    s.responses.create!(session_token: "b-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "No" } }, survey_wave_id: s.current_wave.id)

    get survey_results_path(s)
    assert_response :success
    assert_select "[data-controller~='results-compare']"
    assert_select "[data-results-compare-preselect-value=?]", '["overall","wave_1","wave_2"]'
  end
end
