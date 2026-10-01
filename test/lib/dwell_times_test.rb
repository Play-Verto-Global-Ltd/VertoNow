require "test_helper"

# The per-question typical time to answer behind the results page's chip and
# the summary export's two rows. Median first, over answered cards only.
class DwellTimesTest < ActiveSupport::TestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "yes_no", "text" => "Like it?", "options" => %w[Yes No] },
    { "type" => "open_ended", "text" => "Why?" }
  ].freeze

  def response(answers, dwell)
    Response.new(answers: answers, dwell_ms: dwell)
  end

  test "median and mean per question card, over the respondents who answered it" do
    rows = [
      response({ "1" => { "value" => "Yes" }, "2" => { "value" => "Because" } }, { "0" => 500, "1" => 1000, "2" => 7000 }),
      response({ "1" => { "value" => "No" } },                                     { "1" => 3000, "2" => 9000 }),
      response({ "1" => { "value" => "Yes" } },                                    { "1" => 20_000 })
    ]

    stats = DwellTimes.for(CARDS, rows)

    assert_equal [ 1, 2 ], stats.keys.sort, "the welcome card is not a question"
    assert_equal({ n: 3, median_ms: 3000, mean_ms: 8000 }, stats[1])
    # The second respondent spent nine seconds on "Why?" and never answered it:
    # real time, but not time to answer.
    assert_equal({ n: 1, median_ms: 7000, mean_ms: 7000 }, stats[2])
  end

  test "an even count takes the midpoint, and the mean rounds to whole milliseconds" do
    rows = [
      response({ "1" => { "value" => "Yes" } }, { "1" => 1000 }),
      response({ "1" => { "value" => "Yes" } }, { "1" => 2000 }),
      response({ "1" => { "value" => "Yes" } }, { "1" => 2500 }),
      response({ "1" => { "value" => "Yes" } }, { "1" => 10_001 })
    ]

    assert_equal({ n: 4, median_ms: 2250, mean_ms: 3875 }, DwellTimes.for(CARDS, rows)[1])
  end

  test "an answer the moderator is holding still counts as answered" do
    rows = [ response({ "2" => { "value" => nil, "held" => { "value" => "pending" } } }, { "2" => 4000 }) ]
    assert_equal({ n: 1, median_ms: 4000, mean_ms: 4000 }, DwellTimes.for(CARDS, rows)[2])
  end

  test "nothing recorded, nothing reported" do
    rows = [
      response({ "1" => { "value" => "Yes" } }, {}),
      response({ "1" => { "value" => "Yes" } }, nil),
      response({ "1" => { "value" => "Yes" } }, { "1" => 0 }),
      response({ "1" => { "value" => "Yes" } }, { "1" => "fast" })
    ]

    assert_equal({}, DwellTimes.for(CARDS, rows))
    assert_equal({}, DwellTimes.for([], rows))
    assert_equal({}, DwellTimes.for(CARDS, []))
  end

  test "reads an ActiveRecord relation in batches with the same result as an array" do
    org    = Organisation.create!(name: "O", slug: "dwl-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: CARDS)
    [ 1500, 2500, 6000 ].each do |ms|
      survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                               answers: { "1" => { "value" => "Yes" } }, dwell_ms: { "1" => ms })
    end
    survey.responses.create!(session_token: SecureRandom.uuid, status: "started",
                             answers: {}, dwell_ms: { "1" => 99_000 })

    from_relation = DwellTimes.for(CARDS, survey.responses)
    from_array    = DwellTimes.for(CARDS, survey.responses.to_a)

    assert_equal({ 1 => { n: 3, median_ms: 2500, mean_ms: 3333 } }, from_relation)
    assert_equal from_relation, from_array
  ensure
    survey&.destroy
    org&.destroy
  end
end
