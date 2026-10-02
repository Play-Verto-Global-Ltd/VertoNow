require "test_helper"

# Filtering results by Verto Integrity Score band: High, Medium, Low,
# Unverified and Unscored as a row of the segment picker, like a country or a
# gender — on the organisation's own pages and a partner's, never the public
# results link, and only once scores are visible at all.
class IntegritySegmentsTest < ActionDispatch::IntegrationTest
  CARDS = [ { "type" => "multiple_choice", "cid" => "c0", "text" => "Colour?", "options" => %w[Blue Green] } ].freeze

  def setup
    @org  = Organisation.create!(name: "O", slug: "is-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "is-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS,
                                   publish_token: SecureRandom.hex(8), published_at: Time.current)
    # Careful Blues, a couple of Low Greens, one Unverified Green in Kenya.
    add(6, "Blue", band: "high", country: "GB")
    add(3, "Blue", band: "medium", country: "KE")
    add(2, "Green", band: "low", country: "KE")
    add(1, "Green", band: "unverified", country: "KE")
    @previous = ENV["INTEGRITY_SCORES_VISIBLE"]
    ENV["INTEGRITY_SCORES_VISIBLE"] = "1"
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def teardown
    ENV["INTEGRITY_SCORES_VISIBLE"] = @previous
  end

  def add(count, value, band:, country: nil, share: nil)
    count.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", survey_share: share,
                                answers: { "0" => { "value" => value } }, integrity_band: band, region_country: country)
    end
  end

  def pills
    css_select(".rh-segments-panel a.rh-seg").map { |a| a.text.squish }
  end

  def csv_rows
    CSV.parse(response.body.delete_prefix("﻿")).drop(1)
  end

  test "the picker offers each band the Verto holds, in its own row" do
    get survey_results_path(@survey)
    assert_response :success

    assert_select ".rh-group-label", text: "integrity"
    assert_includes pills, "🛡️ High6"
    assert_includes pills, "🛡️ Medium3"
    assert_includes pills, "🛡️ Low2"
    assert_includes pills, "🛡️ Unverified1"
    assert_not pills.any? { |p| p.start_with?("🛡️ Unscored") }, "a band nobody is in is not offered"
  end

  test "a band narrows the cards, and combines with a place" do
    get survey_results_path(@survey, segment: "integrity_low")
    assert_select ".rh-count-num", text: "2"
    assert_match(/Green/, css_select(".rc-card").to_s)
    assert_no_match(/Blue/, css_select(".rc-card").to_s)

    get survey_results_path(@survey, segment: "region_KE,integrity_medium")
    assert_select ".rh-count-num", text: "3"
    assert_select ".rh-segments summary .rh-picker-active", text: "🌍 Kenya · 🛡️ Medium"

    get survey_results_path(@survey, segment: "integrity_low,integrity_unverified")
    assert_select ".rh-count-num", { text: "3" }, "two bands are alternatives, as two countries are"
    assert_select ".rh-segments summary .rh-picker-active", text: "🛡️ Low or Unverified"
  end

  test "exports, the timeline and the compare view follow the band" do
    get survey_results_export_path(@survey, kind: "responses", segment: "integrity_low")
    assert_equal 2, csv_rows.size
    assert_equal [ "low" ], csv_rows.map(&:last).uniq

    get survey_results_compare_path(@survey)
    data = JSON.parse(response.body)
    low = data["segments"].find { |s| s["id"] == "integrity_low" }
    assert_equal 2, low["count"]
    assert data["aggregates"].key?("integrity_low")

    get survey_results_timeline_path(@survey, card_index: 0, segment: "integrity_high", range: "7d"), as: :json
    assert_equal 6, JSON.parse(response.body)["periods"].last["n"]
  end

  test "bands the switch leaves out are not offered" do
    @survey.update!(exclude_low_integrity: true)
    get survey_results_path(@survey)

    assert_includes pills, "🛡️ High6"
    assert_not pills.any? { |p| p.include?("Low") || p.include?("Unverified") }
  end

  test "the public results link never offers a band" do
    @survey.update!(results_share_token: SecureRandom.urlsafe_base64(18))
    add(10, "Blue", band: "high")

    get shared_results_path(@survey.results_share_token)
    assert_response :success
    assert_no_match(/🛡️/, response.body)

    get shared_results_path(@survey.results_share_token, segment: "integrity_low")
    assert_no_match(/🛡️ Low/, response.body, "an id the page does not offer falls back to Overall")
  end

  test "in shadow mode there is no integrity row" do
    ENV.delete("INTEGRITY_SCORES_VISIBLE")
    get survey_results_path(@survey)

    assert_select ".rh-group-label", text: "integrity", count: 0
    assert_not pills.any? { |p| p.include?("🛡️") }
  end

  test "a partner filters its own respondents by band, against everyone else's same band" do
    partner = Organisation.create!(name: "Partner", slug: "is-p-#{SecureRandom.hex(3)}")
    admin = User.create!(name: "P", email_address: "is-p-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    partner.memberships.create!(user: admin, role: "admin")
    partnership = @org.partnerships.create!(name: "Group")
    PartnershipMembership.join!(partnership: partnership, organisation: partner)
    pv = partnership.partnership_vertos.create!(survey: @survey)
    PartnershipShareSync.ensure_shares_for(partnership: partnership)
    share = partnership.survey_shares.sole
    add(2, "Green", band: "low", share: share)
    add(3, "Blue", band: "high", share: share)

    delete session_path
    post session_path, params: { email_address: admin.email_address, password: "verylongpassword" }
    get partnership_partnership_verto_path(partnership, pv, segment: "integrity_high")
    assert_response :success

    assert_match(/🛡️ Low/, response.body, "two of the partner's own Low responses are theirs to see")
    assert_select ".seg-pill[aria-current=true]", text: /🛡️ High/
    assert_equal "6", css_select(".rc-vs-n").first.text.strip[/\A\d+/],
                 "everyone else's High — six of them, over the line — is drawn beside the partner's"
  end
end
