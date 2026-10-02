require "test_helper"

# Unbounded Alliance's Spanish: one call for the whole deck ran past the output
# ceiling, and every card after the cut was stored as its English — counted as
# translated on every screen. Long decks are now sent in batches, and a card
# the model never returned comes back nil rather than as its own source text.
class SurveyTranslatorBatchingTest < ActiveSupport::TestCase
  class CountingClient
    attr_reader :sizes

    def initialize(drop_last: false)
      @sizes = []
      @drop_last = drop_last
    end

    def messages = self

    def create(messages:, **)
      sent = JSON.parse(messages.first[:content][/\[.*\]/m])
      @sizes << sent.size
      cards = sent.map { |c| { text: "es:#{c['text']}", options: c["options"] } }
      cards.pop if @drop_last
      Struct.new(:content, :usage).new(
        [ Struct.new(:type, :input).new(:tool_use, { cards: cards }) ],
        Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
              .new(1, 1, 0, 0)
      )
    end
  end

  def setup
    TranslationCache.delete_all
  end

  def deck(n)
    Array.new(n) { |i| { "type" => "open_ended", "cid" => "c#{i}", "text" => "Question #{i}?" } }
  end

  def translator_with(client)
    SurveyTranslator.new(api_key: "x").tap { |t| t.instance_variable_set(:@client, client) }
  end

  test "a long deck is translated in batches, and every card comes back in order" do
    client = CountingClient.new
    out = translator_with(client).call(cards: deck(25), target_locale: "es", source_locale: "en")

    assert_equal [ 12, 12, 1 ], client.sizes
    assert_equal 25, out.size
    assert_equal "es:Question 0?", out.first["text"]
    assert_equal "es:Question 24?", out.last["text"]
  end

  test "a card the model did not return is nil, not its English" do
    client = CountingClient.new(drop_last: true)
    out = translator_with(client).call(cards: deck(3), target_locale: "es", source_locale: "en")

    assert_equal "es:Question 1?", out[1]["text"]
    assert_nil out[2], "the original's words are not a translation of themselves"
    assert_equal 2, TranslationCache.count, "and nothing is cached for the card that never came back"
  end

  test "merging a missing card leaves it untranslated rather than English" do
    card = deck(1).first
    merged = Survey.merge_card_translations([ card ], "es", [ nil ])
    assert_nil merged.first.dig("i18n", "es")
  end
end
