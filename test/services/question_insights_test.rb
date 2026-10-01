require "test_helper"
require "ostruct"

# One reading per question, mapped back to the right question.
#
# The mapping is the whole risk. A reading filed under the wrong chart is not a
# missing feature — it is a confident, fluent sentence about numbers that are
# not on the screen, sitting under the creator's own question. So the tool
# returns {question, insight} pairs — the number printed on the digest's own
# "Q3" line, copied — and this service translates that to a deck index and
# drops anything it cannot place, rather than guessing. These tests are about
# that round trip, and about what goes INTO the prompt, since nothing
# downstream can recover from a prompt that omitted half the deck.
class QuestionInsightsTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :last_kwargs
    def initialize(insights) = @insights = insights
    def messages = self
    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: { "insights" => insights_for(kwargs) }) ],
        usage: OpenStruct.new(input_tokens: 800, output_tokens: 200,
                              cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end

    private

    def insights_for(_kwargs) = @insights
  end

  # Does what the model is asked to do: reads the digest it was handed and
  # copies the number off the line it is writing about. Nothing in this class
  # knows a deck index — which is the point. The first cut of the service
  # asked for an index the prompt never printed, and the model echoed the Q
  # number instead (BUG-043); a fake fed already-correct indices could not see
  # that, so this one derives its answer from the prompt the way the model does.
  class EchoingClient < FakeClient
    attr_reader :echoed
    def initialize(line, insight)
      @line    = line
      @insight = insight
    end

    private

    def insights_for(kwargs)
      prompt  = kwargs[:messages].first[:content]
      @echoed = prompt[/^Q(\d+) #{Regexp.escape(@line)}/, 1]&.to_i
      @echoed ? [ { "question" => @echoed, "insight" => @insight } ] : []
    end
  end

  def survey
    @survey ||= Survey.new(title: "Sport", theme: "Sport", key_insight: "what stops people playing")
  end

  # Two questions plus a welcome card, so the number the model copies is a
  # position in the WHOLE deck rather than in the questions-only subset — the
  # digest says Q2 and Q3, never Q1 — and the index a reading is filed under
  # is the one the view looks it up by.
  def aggregated
    [
      { type: "welcome_card", card: { "type" => "welcome_card", "text" => "Kick off" }, total: 40, counts: {} },
      { type: "multiple_choice", total: 40, counts: { "Cost" => 30, "Time" => 10 },
        card: { "type" => "multiple_choice", "text" => "What stops you?", "options" => %w[Cost Time],
                "competency" => "agency", "condition" => "belonging",
                "outcome" => "Which barriers are about the place and which about the people." } },
      { type: "yes_no", total: 40, counts: { "Yes" => 24, "No" => 16 },
        card: { "type" => "yes_no", "text" => "Would you come back?", "options" => %w[Yes No] } }
    ]
  end

  def run_with(insights, aggregated: self.aggregated, total: 40)
    run_client(FakeClient.new(insights), aggregated: aggregated, total: total)
  end

  def run_client(client, aggregated: self.aggregated, total: 40)
    svc = QuestionInsights.allocate
    svc.instance_variable_set(:@client, client)
    [ svc.call(survey: survey, aggregated: aggregated, total: total), client ]
  end

  test "a reading is filed under the card whose Q number the model copied" do
    out, client = run_with([
      { "question" => 2, "insight" => "Cost takes 75% of the field." },
      { "question" => 3, "insight" => "Three in five would come back." }
    ])

    assert_equal({ "1" => "Cost takes 75% of the field.", "2" => "Three in five would come back." }, out)
    assert_equal ClaudeModels::FAST, client.last_kwargs[:model]
    assert_equal "emit_insights", client.last_kwargs[:tool_choice][:name],
      "the tool must be forced — prose to be split up is the shape this avoids"

    fields = client.last_kwargs[:tools].first[:input_schema][:properties][:insights][:items]
    assert_includes fields[:required], "question"
    refute fields[:properties].key?(:index), "an index the prompt never prints is not a thing to ask for"
    refute_match(/index/i, QuestionInsights::TOOL.to_json, "no index wording left to contradict the Q number")
    refute_match(/index/i, QuestionInsights::SYSTEM)
  end

  # The one that matters. The digest labels the card at deck index 2 "Q3",
  # which is what the results page calls "Card 3"; a model that copies that
  # label must land on index 2 — not 3, which is the next card down.
  test "the number copied off the digest line lands on the card the page shows under it" do
    out, client = run_client(EchoingClient.new("[yes_no]: Would you come back?", "Three in five would come back."))

    assert_equal 3, client.echoed, "the digest numbers the whole deck, welcome card included"
    assert_equal({ "2" => "Three in five would come back." }, out)
  end

  # Clamping or coercing would put a reading under a question it was not
  # written about. In range is not enough either: the welcome card is inside
  # the deck and was never offered.
  test "a number naming no offered question is dropped, never clamped" do
    out, = run_with([
      { "question" => 100, "insight" => "About a question that does not exist." },
      { "question" => 0,   "insight" => "About a question before the deck." },
      { "question" => -1,  "insight" => "About a question at the end of the deck." },
      { "question" => 1,   "insight" => "About the welcome card, which has no box." },
      { "question" => "3", "insight" => "A number the digest did not print." },
      { "question" => 2,   "insight" => "The real one." },
      { "question" => 3,   "insight" => "The last card, which a range check against the deck size used to throw away." }
    ])

    assert_equal({ "1" => "The real one.",
                   "2" => "The last card, which a range check against the deck size used to throw away." }, out)
  end

  test "a question under the threshold is not offered, so a reading of it is dropped" do
    thin = aggregated.map { |r| r[:type] == "yes_no" ? r.merge(total: QuestionInsights::MIN_ANSWERS - 1) : r }
    out, = run_with([
      { "question" => 2, "insight" => "Kept." },
      { "question" => 3, "insight" => "A reading of four people." }
    ], aggregated: thin)

    assert_equal({ "1" => "Kept." }, out)
  end

  test "a blank or missing reading contributes nothing rather than an empty box" do
    out, = run_with([
      { "question" => 2, "insight" => "   " },
      { "question" => 3, "insight" => nil },
      { "question" => 3, "insight" => "Kept." }
    ])

    assert_equal({ "2" => "Kept." }, out)
  end

  # A reading of four people is a description of four people. The results page
  # already withholds a segment under its own threshold for the same reason.
  test "too few answers is no call at all" do
    out, client = run_with([ { "question" => 2, "insight" => "Should never be asked for." } ],
                           total: QuestionInsights::MIN_ANSWERS - 1)

    assert_empty out
    assert_nil client.last_kwargs, "the model was called for a sample too small to read"
  end

  test "a deck whose questions are all under the threshold is no call at all" do
    thin = aggregated.map { |r| r.merge(total: 2) }
    out, client = run_with([], aggregated: thin)

    assert_empty out
    assert_nil client.last_kwargs
  end

  # ── What reaches the prompt ────────────────────────────────────────────────

  test "the prompt carries every question's tallies and the framework tagging" do
    _out, client = run_with([ { "question" => 2, "insight" => "x" } ])
    prompt = client.last_kwargs[:messages].first[:content]

    assert_match "What stops you?", prompt
    assert_match "Cost: 30", prompt, "the digest's own tallies must be there"
    assert_match "Framework tagging", prompt
    assert_match "Q2 — competency: Agency; condition: Belonging", prompt,
      "the tagging is numbered the way the digest numbers its questions"
    assert_match "asked in order to learn: Which barriers", prompt
  end

  # An untagged deck is most decks — the tagging only exists on cards that came
  # through the generator or were optimised. The block must be absent entirely
  # rather than present and empty, or the model is invited to use a vocabulary
  # it has been given no values for.
  test "a deck with no framework tagging gets no framework block" do
    bare = aggregated.map { |r| r.merge(card: r[:card].except("competency", "condition", "outcome")) }
    _out, client = run_with([ { "question" => 2, "insight" => "x" } ], aggregated: bare)

    refute_match "Framework tagging", client.last_kwargs[:messages].first[:content]
  end

  # Contact details never reach a prompt anywhere in this app, and a reading of
  # them would have nothing to be about.
  test "a contact-form card is not offered for reading" do
    contact = [ { type: "contact_form", total: 40, entries: [],
                  card: { "type" => "contact_form", "text" => "Your details" } } ]
    out, client = run_with([], aggregated: contact)

    assert_empty out
    assert_nil client.last_kwargs
  end
end
