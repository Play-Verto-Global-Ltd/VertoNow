require "test_helper"
require "ostruct"

# One reading per question, mapped back to the right question.
#
# The mapping is the whole risk. A reading filed under the wrong chart is not a
# missing feature — it is a confident, fluent sentence about numbers that are
# not on the screen, sitting under the creator's own question. So the tool
# returns {index, insight} pairs and this service drops anything it cannot
# place, rather than guessing. These tests are about that, and about what goes
# INTO the prompt, since nothing downstream can recover from a prompt that
# omitted half the deck.
class QuestionInsightsTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :last_kwargs
    def initialize(insights) = @insights = insights
    def messages = self
    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: { "insights" => @insights }) ],
        usage: OpenStruct.new(input_tokens: 800, output_tokens: 200,
                              cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  def survey
    @survey ||= Survey.new(title: "Sport", theme: "Sport", key_insight: "what stops people playing")
  end

  # Two questions plus a welcome card, so the index the model is given is the
  # index in the WHOLE deck rather than in the questions-only subset — which is
  # what the view looks a reading up by.
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
    svc = QuestionInsights.allocate
    client = FakeClient.new(insights)
    svc.instance_variable_set(:@client, client)
    [ svc.call(survey: survey, aggregated: aggregated, total: total), client ]
  end

  test "a reading is filed under the index the model was given" do
    out, client = run_with([
      { "index" => 1, "insight" => "Cost takes 75% of the field." },
      { "index" => 2, "insight" => "Three in five would come back." }
    ])

    assert_equal({ "1" => "Cost takes 75% of the field.", "2" => "Three in five would come back." }, out)
    assert_equal ClaudeModels::FAST, client.last_kwargs[:model]
    assert_equal "emit_insights", client.last_kwargs[:tool_choice][:name],
      "the tool must be forced — prose to be split up is the shape this avoids"
  end

  # The one that matters. Clamping an out-of-range index would put a reading
  # under a question it was not written about.
  test "an index outside the deck is dropped, never clamped onto a real question" do
    out, = run_with([
      { "index" => 99, "insight" => "About a question that does not exist." },
      { "index" => -1, "insight" => "About a question at the end of the deck." },
      { "index" => 1,  "insight" => "The real one." }
    ])

    assert_equal({ "1" => "The real one." }, out)
  end

  test "a blank or missing reading contributes nothing rather than an empty box" do
    out, = run_with([
      { "index" => 1, "insight" => "   " },
      { "index" => 2, "insight" => nil },
      { "index" => 2, "insight" => "Kept." }
    ])

    assert_equal({ "2" => "Kept." }, out)
  end

  # A reading of four people is a description of four people. The results page
  # already withholds a segment under its own threshold for the same reason.
  test "too few answers is no call at all" do
    svc = QuestionInsights.allocate
    client = FakeClient.new([ { "index" => 1, "insight" => "Should never be asked for." } ])
    svc.instance_variable_set(:@client, client)

    assert_empty svc.call(survey: survey, aggregated: aggregated, total: QuestionInsights::MIN_ANSWERS - 1)
    assert_nil client.last_kwargs, "the model was called for a sample too small to read"
  end

  test "a deck whose questions are all under the threshold is no call at all" do
    thin = aggregated.map { |r| r.merge(total: 2) }
    svc = QuestionInsights.allocate
    client = FakeClient.new([])
    svc.instance_variable_set(:@client, client)

    assert_empty svc.call(survey: survey, aggregated: thin, total: 40)
    assert_nil client.last_kwargs
  end

  # ── What reaches the prompt ────────────────────────────────────────────────

  test "the prompt carries every question's tallies and the framework tagging" do
    _out, client = run_with([ { "index" => 1, "insight" => "x" } ])
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
    _out, client = run_with([ { "index" => 1, "insight" => "x" } ], aggregated: bare)

    refute_match "Framework tagging", client.last_kwargs[:messages].first[:content]
  end

  # Contact details never reach a prompt anywhere in this app, and a reading of
  # them would have nothing to be about.
  test "a contact-form card is not offered for reading" do
    contact = [ { type: "contact_form", total: 40, entries: [],
                  card: { "type" => "contact_form", "text" => "Your details" } } ]
    svc = QuestionInsights.allocate
    client = FakeClient.new([])
    svc.instance_variable_set(:@client, client)

    assert_empty svc.call(survey: survey, aggregated: contact, total: 40)
    assert_nil client.last_kwargs
  end
end
