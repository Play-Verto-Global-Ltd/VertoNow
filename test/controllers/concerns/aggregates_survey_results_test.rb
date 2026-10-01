require "test_helper"

class AggregatesSurveyResultsTest < ActiveSupport::TestCase
  # Tiny includer to exercise the private concern method directly.
  class Aggregator
    include AggregatesSurveyResults
    def run(cards, responses) = aggregate_results(cards, responses)
  end

  def setup
    @agg = Aggregator.new
  end

  # Build plain in-memory Response objects so the array path is exercised
  # (no DB needed); each answers hash is keyed by card index as a string.
  def resp(answers) = Response.new(answers: answers)

  CARDS = [
    { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] }, # 0
    { "type" => "select_many",     "text" => "Many", "options" => %w[X Y] }, # 1
    { "type" => "rating",          "text" => "Rate", "options" => %w[Lo Hi] }, # 2
    { "type" => "range",           "text" => "Range" }, # 3
    { "type" => "tap_card",        "text" => "Tap" }, # 4
    { "type" => "open_ended",      "text" => "Say" }, # 5
    { "type" => "welcome_card",    "title" => "Hi" }, # 6 (else branch)
    { "type" => "prioritise",      "text" => "Rank", "options" => %w[A B C] }, # 7
    { "type" => "scenario",        "text" => "Choose", "options" => %w[Left Right] } # 8
  ].freeze

  def sample_responses
    [
      resp({
        "0" => { "value" => "A" },
        "1" => { "value" => %w[X Y] },
        "2" => { "value" => 4 },
        "3" => { "value" => 2 },
        "4" => { "value" => { "Statement 1" => "yes" } },
        "5" => { "value" => "Loved it" }
      }),
      resp({
        "0" => { "value" => nil, "other" => "Custom" }, # Other
        "1" => { "value" => %w[X] },
        "2" => { "value" => 2 },
        "3" => { "value" => 5 },
        "4" => { "value" => { "Statement 1" => "no" } },
        "5" => { "value" => "" } # blank text — counts toward total, not texts
      }),
      resp({ "0" => { "value" => "B" } })
    ]
  end

  # A deck edited under the live-edit override (LiveEditAccess) can leave an
  # answer recorded against a different card at a scale card's index — a
  # select_many's array, a tap card's hash. Those are skipped: Array#to_i would
  # take the whole results page down, and re-pointed answers are the accepted
  # cost of that override, not a reason results can't render.
  test "a wrong-shaped answer at a scale index is skipped rather than crashing" do
    responses = [
      resp({ "2" => { "value" => %w[X Y] }, "3" => { "value" => { "Statement 1" => "yes" } } }),
      resp({ "2" => { "value" => 4 },       "3" => { "value" => "2" } })
    ]
    rows = nil
    assert_nothing_raised { rows = @agg.run(CARDS, responses) }

    rating = rows[2]
    assert_equal({ 4 => 1 }, rating[:counts].to_h)
    assert_equal 4.0, rating[:avg]
    assert_equal 1, rating[:total], "the skipped answer must not be counted over a single bar"
    range = rows[3]
    assert_equal({ 2 => 1 }, range[:counts].to_h)
    assert_equal 1, range[:total]
  end

  test "prioritise banks each option's rank and totals responders" do
    responses = [
      resp({ "7" => { "value" => %w[A B C] } }), # A=1 B=2 C=3
      resp({ "7" => { "value" => %w[B A C] } })  # B=1 A=2 C=3
    ]
    row = @agg.run(CARDS, responses)[7]
    assert_equal 2, row[:total]
    # sum of ranks: A=1+2=3, B=2+1=3, C=3+3=6 → mean A=B=1.5, C=3.0
    assert_equal({ "A" => 3, "B" => 3, "C" => 6 }, row[:counts].to_h)
  end

  test "multiple_choice tallies counts, Other, and total" do
    row = @agg.run(CARDS, sample_responses)[0]
    assert_equal 3, row[:total] # A + B + Other
    assert_equal 1, row[:counts]["A"]
    assert_equal 1, row[:counts]["B"]
    assert_equal 1, row[:counts]["Other"]
    assert_equal [ "Custom" ], row[:other_texts]
  end

  test "scenario tallies counts and total like multiple_choice" do
    responses = [
      resp({ "8" => { "value" => "Left" } }),
      resp({ "8" => { "value" => "Right" } }),
      resp({ "8" => { "value" => "Left" } })
    ]
    row = @agg.run(CARDS, responses)[8]
    assert_equal 3, row[:total]
    assert_equal 2, row[:counts]["Left"]
    assert_equal 1, row[:counts]["Right"]
  end

  test "select_many counts each selection but totals responders" do
    row = @agg.run(CARDS, sample_responses)[1]
    assert_equal 2, row[:total]      # two responders answered
    assert_equal 2, row[:counts]["X"]
    assert_equal 1, row[:counts]["Y"]
  end

  test "rating averages over responders" do
    row = @agg.run(CARDS, sample_responses)[2]
    assert_equal 2, row[:total]
    assert_equal 3.0, row[:avg] # (4 + 2) / 2
    assert_equal 1, row[:counts][4]
    assert_equal 1, row[:counts][2]
  end

  test "range buckets by integer" do
    row = @agg.run(CARDS, sample_responses)[3]
    assert_equal({ 2 => 1, 5 => 1 }, row[:counts].to_h)
    assert_equal 2, row[:total]
  end

  test "tap_card tallies yes/no/unsure per statement" do
    row = @agg.run(CARDS, sample_responses)[4]
    assert_equal({ "yes" => 1, "no" => 1, "unsure" => 0 }, row[:counts]["Statement 1"])
    assert_equal 2, row[:total]
  end

  test "a card with its own scale is tallied on that scale, not the historic three" do
    # The seed used to be a literal {"yes"=>0,"no"=>0,"unsure"=>0}, which meant a
    # five-point card's answers landed in a hash with no slot for them and were
    # dropped on the floor — the results page would have shown nothing at all.
    cards = [ { "type" => "tap_card", "text" => "Tap", "responses" => TapScales.preset(5) } ]
    responses = [
      resp({ "0" => { "value" => { "Stmt" => "strongly_agree" } } }),
      resp({ "0" => { "value" => { "Stmt" => "neutral" } } }),
      resp({ "0" => { "value" => { "Stmt" => "strongly_agree" } } })
    ]
    row = @agg.run(cards, responses)[0]

    assert_equal({ "strongly_disagree" => 0, "disagree" => 0, "neutral" => 1,
                   "agree" => 0, "strongly_agree" => 2 }, row[:counts]["Stmt"],
                 "every response on the scale gets a slot, including the ones nobody picked")
    assert_equal 3, row[:total]
  end

  test "an answer keyed off the card's scale is ignored rather than invented" do
    cards = [ { "type" => "tap_card", "text" => "Tap", "responses" => TapScales.preset(2) } ]
    row = @agg.run(cards, [ resp({ "0" => { "value" => { "Stmt" => "neutral" } } }) ])[0]

    assert_equal({ "no" => 0, "yes" => 0 }, row[:counts]["Stmt"],
                 "a card re-scaled after collection must not grow a bar for an answer it no longer offers")
  end

  test "tap_card counts the unsure direction" do
    responses = [
      resp({ "4" => { "value" => { "Statement 1" => "unsure" } } }),
      resp({ "4" => { "value" => { "Statement 1" => "yes" } } })
    ]
    row = @agg.run(CARDS, responses)[4]
    assert_equal({ "yes" => 1, "no" => 0, "unsure" => 1 }, row[:counts]["Statement 1"])
  end

  test "open_ended keeps non-blank texts but totals all answers" do
    row = @agg.run(CARDS, sample_responses)[5]
    assert_equal [ "Loved it" ], row[:texts]
    assert_equal 2, row[:total] # both answered (one blank), blank excluded from texts
  end

  test "non-question card totals all responses" do
    row = @agg.run(CARDS, sample_responses)[6]
    assert_equal 3, row[:total]
    assert_equal({}, row[:counts])
  end

  test "handles an empty response set" do
    rows = @agg.run(CARDS, [])
    assert_equal 0, rows[0][:total]
    assert_equal 0.0, rows[2][:avg]
  end

  # The Other box combines with the picks: a respondent can tick an answer AND
  # write one in. That respondent is one respondent. The old total was
  # value_count + other_count, which said "2 answers" over one person and
  # pushed every percentage on the card down.
  test "a respondent who picks AND writes in counts once toward the total, on every type" do
    responses = [
      resp({
        "0" => { "value" => "A", "other" => "Custom" },
        "1" => { "value" => %w[X], "other" => "Custom" },
        "2" => { "value" => 4, "other" => "a note" },
        "3" => { "value" => 2, "other" => "a note" },
        "4" => { "value" => { "Statement 1" => "yes" }, "other" => "a note" },
        "5" => { "value" => "Loved it", "other" => "and this" },
        "8" => { "value" => "Left", "other" => "Custom" }
      }),
      resp({ "0" => { "value" => "B" }, "1" => { "value" => %w[Y] }, "2" => { "value" => 2 },
             "3" => { "value" => 5 }, "4" => { "value" => { "Statement 1" => "no" } },
             "5" => { "value" => "Fine" }, "8" => { "value" => "Right" } })
    ]
    rows = @agg.run(CARDS, responses)

    mc = rows[0]
    assert_equal 2, mc[:total], "two people answered, one of them twice over"
    assert_equal({ "A" => 1, "B" => 1, "Other" => 1 }, mc[:counts].to_h, "the write-in is still its own bar")
    assert_equal [ "Custom" ], mc[:other_texts]

    assert_equal 2, rows[1][:total]
    assert_equal({ "X" => 1, "Y" => 1, "Other" => 1 }, rows[1][:counts].to_h)
    assert_equal 2, rows[2][:total]
    assert_equal 3.0, rows[2][:avg], "the note does not dilute the average"
    assert_equal 2, rows[3][:total]
    assert_equal 2, rows[4][:total]
    assert_equal 2, rows[5][:total]
    assert_equal 2, rows[8][:total]
  end

  test "a write-in alone still counts, and a held write-in beside a pick counts once" do
    responses = [
      resp({ "0" => { "value" => nil, "other" => "Custom" } }),
      resp({ "0" => { "value" => "A", "other" => nil, "held" => { "other" => true } } }),
      resp({ "0" => { "value" => "B" } })
    ]
    row = @agg.run(CARDS, responses)[0]

    assert_equal 3, row[:total], "three respondents: Other only, A plus a held write-in, B"
    assert_equal 2, row[:counts]["Other"], "both write-ins are in the Other bar, the held one included"
    assert_equal 1, row[:held]
  end

  test "prioritise keeps totalling the people who ranked" do
    responses = [
      resp({ "7" => { "value" => %w[A B C], "other" => "D too" } }),
      resp({ "7" => { "value" => nil, "other" => "none of these" } })
    ]
    row = @agg.run(CARDS, responses)[7]
    assert_equal 1, row[:total], "a mean rank is divided by the people who ranked, not by the write-ins"
  end
end
