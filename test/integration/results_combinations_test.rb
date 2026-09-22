require "test_helper"

# Combining segments on the results page: ?segment=region_AT,gender_male is
# Austrian men. OR within a kind (a respondent has one country), AND across
# kinds, and a combination that includes an identity slice is held to the
# same small-cell rule a single slice is — see
# ResolvesResultSegments#combine_result_segments. Each test below was checked
# by breaking the code under it.
class ResultsCombinationsTest < ActionDispatch::IntegrationTest
  include ResolvesResultSegments

  MIN = ResolvesResultSegments::MIN_DEMOGRAPHIC_SAMPLE

  def setup
    @org  = Organisation.create!(name: "O", slug: "cmb-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "cmb-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ] +
             DemographicQuestions.cards,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def add(count, country: nil, gender: nil, birth_year: nil, link: nil, wave: nil, created_at: Time.current, value: "Yes")
    count.times do
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed",
        answers: { "0" => { "value" => value } },
        region_country: country, demographic_gender: gender, demographic_birth_year: birth_year,
        survey_link: link, survey_wave_id: wave&.id, created_at: created_at, updated_at: created_at
      )
    end
  end

  # Enough in every single slice to clear the threshold, so the only thing a
  # combination can fall under is its own count.
  def seed_grid
    add(MIN + 1, country: "AT", gender: "Male")
    add(MIN + 1, country: "AT", gender: "Female")
    add(MIN + 1, country: "DE", gender: "Male")
  end

  def active_for(param, range = nil)
    _base, _segments, active = resolve_result_segments(@survey, param, range)
    active
  end

  # ── Resolving ──────────────────────────────────────────────────────────────

  test "two kinds intersect" do
    seed_grid

    active = active_for("region_AT,gender_male")
    assert active[:combination]
    assert_equal MIN + 1, active[:count]
    assert_equal MIN + 1, active[:scope].count
    assert active[:scope].all? { |r| r.region_country == "AT" && r.demographic_gender == "Male" }
  end

  test "two of one kind are alternatives, not an empty intersection" do
    seed_grid

    active = active_for("region_AT,region_DE")
    assert_equal 3 * (MIN + 1), active[:count], "Austria OR Germany is everyone here"
    refute active[:suppressed]
  end

  test "alternatives within a kind still intersect with the other kinds" do
    seed_grid

    active = active_for("region_AT,region_DE,gender_female")
    assert_equal MIN + 1, active[:count], "(AT or DE) and Female"
  end

  test "the id is canonical whatever order the parts were picked in" do
    seed_grid

    a = active_for("gender_male,region_AT")
    b = active_for("region_AT,gender_male")
    assert_equal "region_AT,gender_male", a[:id], "places come before gender in the picker, so in the id"
    assert_equal a[:id], b[:id]
    assert_equal a[:count], b[:count]
  end

  test "one id is that segment, unchanged — not a one-part combination" do
    seed_grid

    active = active_for("region_AT")
    refute active[:combination]
    assert_equal "region_AT", active[:id]
    assert_equal 2 * (MIN + 1), active[:count]
  end

  test "ids this base does not offer are dropped rather than failing the request" do
    seed_grid

    active = active_for("region_AT,region_XX,gender_nonexistent")
    refute active[:combination]
    assert_equal "region_AT", active[:id]

    assert_equal "overall", active_for("region_XX,region_YY")[:id]
    assert_equal "overall", active_for(",,")[:id]
  end

  test "overall in a list means nothing, and a repeated id counts once" do
    seed_grid

    assert_equal "region_AT", active_for("overall,region_AT")[:id]
    assert_equal "region_AT", active_for("region_AT,region_AT")[:id]
    assert_equal "overall", active_for("overall")[:id], "the one-id form every existing link uses still works"
  end

  test "the label reads as the sentence the scope is" do
    seed_grid

    assert_equal "🌍 Austria · 👤 Male", active_for("region_AT,gender_male")[:label]
    assert_equal "🌍 Austria or Germany · 👤 Female", active_for("region_AT,region_DE,gender_female")[:label],
      "a kind's emoji is said once per run"
  end

  # ── Small cells ────────────────────────────────────────────────────────────

  test "a combination of identity slices under the threshold is suppressed — count, rows and all" do
    seed_grid # nobody is German and female

    active = active_for("region_DE,gender_female")
    assert active[:suppressed]
    assert_equal 0, active[:count]
    assert_equal 0, active[:scope].count
    assert active[:combination], "still a combination: the page names what was asked for"
    assert_equal "🌍 Germany · 👤 Female", active[:label]
  end

  test "under the threshold means fewer than it, not at it" do
    add(MIN, country: "AT", gender: "Male")
    add(MIN, country: "AT", gender: "Female")
    add(MIN - 1, country: "DE", gender: "Male")
    add(1, country: "DE", gender: "Female")

    refute active_for("region_AT,gender_male")[:suppressed], "exactly MIN is shown, as a single slice would be"
    assert active_for("region_DE,gender_male")[:suppressed], "MIN - 1 is not, however big both parts are"
  end

  test "a combination of structural segments is never suppressed" do
    # Links and waves are groupings the owner made on purpose, with no
    # small-cell rule on their own (see result_segments) — and none combined.
    link = @survey.survey_links.create!(name: "RA Ana", slug: "ra-ana-#{SecureRandom.hex(2)}")
    add(2, link: link)
    add(3)
    @survey.start_next_wave!
    # Stamped explicitly: the player stamps the wave on submit, a direct
    # create does not (results_waves_test's own fixture shape).
    add(1, link: link, wave: @survey.current_wave)

    active = active_for("link_#{link.id},wave_2")
    assert active[:combination]
    refute active[:suppressed]
    assert_equal 1, active[:count]
  end

  test "a structural segment combined with an identity slice takes the identity rule" do
    link = @survey.survey_links.create!(name: "RA Ana", slug: "ra-ana-#{SecureRandom.hex(2)}")
    add(MIN, country: "AT")
    add(2, country: "AT", link: link)

    active = active_for("link_#{link.id},region_AT")
    assert active[:suppressed], "the link narrows Austria to two people, which is what the rule is for"
  end

  test "the date window narrows a combination too" do
    add(MIN + 1, country: "AT", gender: "Male", created_at: 60.days.ago)
    add(MIN + 1, country: "AT", gender: "Male", created_at: 2.days.ago)
    add(MIN + 1, country: "AT", gender: "Female", created_at: 2.days.ago)

    assert_equal 2 * (MIN + 1), active_for("region_AT,gender_male")[:count]
    assert_equal MIN + 1,       active_for("region_AT,gender_male", "7d")[:count]
  end

  # ── The page ───────────────────────────────────────────────────────────────

  test "the picker names the combination and marks every part selected" do
    seed_grid

    get survey_results_path(@survey, segment: "region_AT,gender_male")
    assert_response :success

    assert_select ".rh-segments summary .rh-picker-active", text: "🌍 Austria · 👤 Male"
    selected = css_select(".rh-segments-panel a.rh-seg[aria-current='true']").map { |a| a.text.strip }
    assert_equal 2, selected.size
    assert selected.any? { |t| t.include?("Austria") }
    assert selected.any? { |t| t.include?("Male") }
    assert_select ".rh-segments-panel .rh-group-hint", 1
    assert_select "a.seg-pill.rh-picker-wide[aria-current='false']", text: /Overall/
    assert_match "#{MIN + 1}", css_select(".rh-count-num").first.text
  end

  test "every pill is a toggle: adding a kind narrows, adding to a kind widens, clicking a part removes it" do
    seed_grid

    get survey_results_path(@survey, segment: "region_AT,gender_male")

    hrefs = css_select(".rh-segments-panel a.rh-seg").to_h { |a| [ a.text.strip, a["href"] ] }
    female  = hrefs.keys.find { |t| t.include?("Female") }
    germany = hrefs.keys.find { |t| t.include?("Germany") }
    male    = hrefs.keys.find { |t| t.include?("Male") && !t.include?("Female") }
    austria = hrefs.keys.find { |t| t.include?("Austria") }

    assert_equal survey_results_path(@survey, segment: "region_AT,gender_male,gender_female"), hrefs[female]
    assert_equal survey_results_path(@survey, segment: "region_AT,region_DE,gender_male"),     hrefs[germany]
    assert_equal survey_results_path(@survey, segment: "region_AT"),                           hrefs[male]
    assert_equal survey_results_path(@survey, segment: "gender_male"),                         hrefs[austria]
  end

  test "removing the last part leads to Overall, with no empty segment parameter" do
    seed_grid

    get survey_results_path(@survey, segment: "region_AT", range: "30d")

    austria = css_select(".rh-segments-panel a.rh-seg").find { |a| a.text.include?("Austria") }
    assert_equal survey_results_path(@survey, range: "30d"), austria["href"]
  end

  test "the window rides along on every toggle" do
    seed_grid

    get survey_results_path(@survey, segment: "region_AT", range: "7d")
    css_select(".rh-segments-panel a.rh-seg").each do |a|
      assert_includes a["href"], "range=7d", "#{a.text.strip} would drop the window"
    end
  end

  test "a suppressed combination shows the notice in place of the cards, and withholds the number" do
    seed_grid

    get survey_results_path(@survey, segment: "region_DE,gender_female")
    assert_response :success

    assert_select ".rc-suppressed", 1
    assert_select ".rc-card", 1, "only the notice — no per-question cards saying 'No responses yet'"
    assert_select ".rh-count-num", text: "<#{MIN}"
    assert_select ".rh-segments summary .rh-picker-active", text: "🌍 Germany · 👤 Female"
    # The explanation is in the pinned header too: the feed's card is a whole
    # screen below the number it explains.
    assert_select ".results-header .rh-notice", text: /Too few responses/
    assert_select ".results-header .rh-notice", text: /Fewer than #{MIN} people/
  end

  test "a shown combination carries no notice" do
    seed_grid

    get survey_results_path(@survey, segment: "region_AT,gender_male")
    assert_select ".rh-notice", false
    assert_select ".rc-suppressed", false
  end

  test "exports and the answers panel carry the combination, so they count what the page counts" do
    seed_grid

    get survey_results_path(@survey, segment: "region_AT,gender_male")
    assert_select "details.results-export-menu a[href=?]",
      survey_results_export_path(@survey, kind: "responses", segment: "region_AT,gender_male")

    get survey_results_export_path(@survey, kind: "responses", segment: "region_AT,gender_male")
    assert_response :success
    rows = CSV.parse(response.body.delete_prefix("﻿"))
    assert_equal MIN + 1, rows.drop(1).size

    get survey_results_export_path(@survey, kind: "responses", segment: "region_DE,gender_female")
    rows = CSV.parse(response.body.delete_prefix("﻿"))
    assert_equal 0, rows.drop(1).size, "a suppressed combination exports nothing, by the scope not by the view"
  end
end
