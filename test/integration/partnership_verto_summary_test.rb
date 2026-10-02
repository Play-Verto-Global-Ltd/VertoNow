require "test_helper"

# The AI summary on a partner's results page. What matters is who it is about
# and what reaches the model: the slice the page is showing, the same slice of
# everyone else (or nothing, under the small-cell line) — and never everyone
# else's written answers, which the page itself withholds.
class PartnershipVertoSummaryTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "multiple_choice", "text" => "Pick", "options" => [ "Pitch", "Court" ] },
    { "type" => "open_ended", "text" => "Why?" }
  ].freeze

  setup do
    @owner = Organisation.create!(name: "Owner", slug: "sum-owner-#{SecureRandom.hex(3)}")
    @partner = Organisation.create!(name: "Partner", slug: "sum-partner-#{SecureRandom.hex(3)}")
    @admin = User.create!(name: "P", email_address: "sum-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @partner.memberships.create!(user: @admin, role: "admin")
    @survey = @owner.surveys.create!(title: "Sum Verto", theme: "T", audience_age: "all", key_insight: "x",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS,
                                     publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    @partnership = @owner.partnerships.create!(name: "Sum Group")
    PartnershipMembership.join!(partnership: @partnership, organisation: @partner)
    @pv = @partnership.partnership_vertos.create!(survey: @survey)
    PartnershipShareSync.ensure_shares_for(partnership: @partnership)
    @share = @partnership.survey_shares.sole
  end

  def respond(share, pick, why, gender: nil, country: nil)
    r = @survey.responses.create!(session_token: SecureRandom.uuid, survey_share: share, status: "completed",
                                  answers: { "0" => { "value" => pick }, "1" => { "value" => why } })
    r.update_columns(demographic_gender: gender, region_country: country)
  end

  def sign_in
    post session_path, params: { email_address: @admin.email_address, password: "verylongpassword" }
  end

  # A summariser that records what it was asked and streams a fixed reply.
  def with_fake_summariser
    calls = []
    fake = Object.new
    fake.define_singleton_method(:call_for_partner) do |**kw, &blk|
      calls << kw
      blk.call("Your people prefer the pitch.")
    end
    stub_method(ResultsSummariser, :new, fake) { yield calls }
  end

  test "it streams a summary of the partner's respondents against everyone else's" do
    3.times { respond(@share, "Pitch", "Our own words") }
    5.times { respond(nil, "Court", "Their words") }
    sign_in

    with_fake_summariser do |calls|
      get partnership_partnership_verto_summary_path(@partnership, @pv)

      assert_response :success
      assert_equal "Your people prefer the pitch.", response.body
      call = calls.sole
      assert_equal 3, call[:total]
      assert_equal({ "Pitch" => 3 }, call[:aggregated][0][:counts].to_h)
      assert_equal 5, call[:baseline_total]
      assert_equal({ "Court" => 5 }, call[:baseline][0][:counts].to_h)
    end
  end

  test "it summarises the slice the page is showing, against the same slice of everyone else" do
    6.times { respond(@share, "Pitch", "w", gender: "female") }
    5.times { respond(@share, "Court", "w", gender: "male") }
    5.times { respond(nil, "Court", "w", gender: "female") }
    3.times { respond(nil, "Pitch", "w", gender: "male") }
    sign_in

    with_fake_summariser do |calls|
      get partnership_partnership_verto_summary_path(@partnership, @pv, segment: "gender_female")
      assert_equal 6, calls.last[:total]
      assert_equal 5, calls.last[:baseline_total]
      assert_equal({ "Court" => 5 }, calls.last[:baseline][0][:counts].to_h)

      # Everyone else's men are three — too few to stand for anyone, so the
      # summary describes the partner's men alone.
      get partnership_partnership_verto_summary_path(@partnership, @pv, segment: "gender_male")
      assert_equal 5, calls.last[:total]
      assert_nil calls.last[:baseline]
    end
  end

  test "a slice under the small-cell line is never sent to the model" do
    # Five women and five people in the UK, but no woman in the UK: each pill
    # is offered, and their combination is under the line.
    5.times { respond(@share, "Pitch", "w", gender: "female", country: "ES") }
    5.times { respond(@share, "Court", "w", gender: "male", country: "GB") }
    sign_in

    with_fake_summariser do |calls|
      get partnership_partnership_verto_summary_path(@partnership, @pv, segment: "region_GB,gender_female")
      assert_response :success
      assert_empty calls
    end
  end

  test "only the partnership's members and owner can read it" do
    stranger = User.create!(name: "S", email_address: "sum-s-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    Organisation.create!(name: "Stranger", slug: "sum-x-#{SecureRandom.hex(3)}").memberships.create!(user: stranger, role: "admin")
    post session_path, params: { email_address: stranger.email_address, password: "verylongpassword" }

    with_fake_summariser do |calls|
      get partnership_partnership_verto_summary_path(@partnership, @pv)
      assert_response :not_found
      assert_empty calls
    end
  end

  # The model is the last place everyone else's words could leak from: the
  # page never shows them, so the prompt must never carry them.
  test "everyone else reaches the model as figures only" do
    summariser = ResultsSummariser.new
    prompts = []
    summariser.define_singleton_method(:stream_summary) { |system, prompt| prompts << [ system, prompt ] }
    mine = [ { type: "open_ended", card: CARDS[1], total: 1, texts: [ "Our own words" ], other_texts: [], held: 0 } ]
    base = [ { type: "open_ended", card: CARDS[1], total: 6, texts: [ "The owner's respondent wrote this" ], other_texts: [], held: 0 } ]

    summariser.call_for_partner(survey: @survey, aggregated: mine, total: 1, baseline: base, baseline_total: 6) { }

    system, prompt = prompts.sole
    assert_equal ResultsSummariser::PARTNER_SYSTEM_WITH_SAFETY, system
    assert_includes prompt, "Our own words"
    assert_includes prompt, "6 written answers (withheld)"
    assert_not_includes prompt, "The owner's respondent wrote this"
  end
end
