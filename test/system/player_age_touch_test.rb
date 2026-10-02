require "application_system_test_case"

# The age question is a slider that opens on a band, and an untouched pass used
# to store that band as the respondent's age: everyone who simply pressed Next
# was recorded as 25–34, which skewed every age breakdown, the segments built
# on them and the Data Commons. On that card only an answer the respondent
# actually gave counts; every other range card is unchanged.
class PlayerAgeTouchTest < ApplicationSystemTestCase
  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "agt-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "AgeTouch", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "range", "cid" => "c_mood", "text" => "How was your day?",
                 "options" => %w[Awful Poor Fine Good Great] },
               DemographicQuestions.cards.first.merge("cid" => "c_age") ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def play_to_age_card
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    assert_text "How was your day?"
    click_button "Next" # the ordinary range card, untouched: its midpoint still counts
    assert_selector ".preview-card.active .slider-wrap[data-slider-top-down-value='true']"
  end

  def finish_and_fetch
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active, [data-player-target='thankyou'].active", wait: 5
    wait_until { @survey.responses.reload.first&.status == "completed" }
    @survey.responses.first
  end

  test "an untouched age slider is not an answer, so no age band is recorded" do
    play_to_age_card
    row = finish_and_fetch

    assert_nil row.answers.dig("1", "value"), "the band the slider opened on is not the respondent's age"
    assert_nil row.demographic_age_band
    assert_equal 2, row.answers.dig("0", "value"), "an ordinary range card keeps today's behaviour"
  end

  test "an age band the respondent picks is recorded" do
    play_to_age_card
    find(".preview-card.active .slider-label-text", text: "18–24").click
    row = finish_and_fetch

    assert_equal 2, row.answers.dig("1", "value")
    assert_equal "18_24", row.demographic_age_band
  end

  test "picking the band the slider opened on still counts once it is touched" do
    play_to_age_card
    find(".preview-card.active .slider-label-text", text: "25–34").click
    row = finish_and_fetch

    assert_equal "25_34", row.demographic_age_band, "a deliberate 25–34 is a real answer"
  end
end
