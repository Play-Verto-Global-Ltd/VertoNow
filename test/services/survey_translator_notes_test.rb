require "test_helper"

# The author's note on what a card means ("power" as in motivation), and the
# Re-translate button's request for a translation that is genuinely new.
#
# Both are about the cache, which is keyed by a card's WORDS alone: a hit for a
# noted card would hand back the translation made before anyone said what the
# word meant, and a hit for a re-translate would hand back the very line the
# creator just asked to replace.
class SurveyTranslatorNotesTest < ActiveSupport::TestCase
  class RecordingClient
    attr_reader :prompts

    def initialize
      @prompts = []
    end

    def messages = self

    def create(messages:, **)
      @prompts << messages.first[:content]
      Struct.new(:content, :usage).new(
        [ Struct.new(:type, :input).new(:tool_use, { cards: [ { text: "NEW", options: [] } ] }) ],
        Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
              .new(1, 1, 0, 0)
      )
    end
  end

  def setup
    TranslationCache.delete_all
    @client = RecordingClient.new
    @translator = SurveyTranslator.new(api_key: "x")
    @translator.instance_variable_set(:@client, @client)
    @card = { "type" => "open_ended", "cid" => "c_power", "text" => "What powers you?" }
    TranslationCache.write(@card, source_locale: "en", target_locale: "pt",
                                  translation: { "text" => "O que te dá poder?", "options" => [] })
  end

  test "a card's note reaches the model with it" do
    @translator.call(cards: [ @card ], target_locale: "pt", source_locale: "en",
                     notes: { "c_power" => "power as in motivation" })

    assert_equal 1, @client.prompts.size, "a noted card must not be answered from the cache"
    assert_includes @client.prompts.first, "power as in motivation"
  end

  test "a noted translation is not written back for other Vertos to reuse" do
    @translator.call(cards: [ @card ], target_locale: "pt", source_locale: "en",
                     notes: { "c_power" => "power as in motivation" })

    hit = TranslationCache.lookup_many([ @card ], source_locale: "en", target_locale: "pt").first
    assert_equal "O que te dá poder?", hit["text"]
  end

  test "an unnoted card still comes from the cache" do
    out = @translator.call(cards: [ @card ], target_locale: "pt", source_locale: "en")
    assert_empty @client.prompts
    assert_equal "O que te dá poder?", out.first["text"]
  end

  test "a fresh request skips the cache" do
    out = @translator.call(cards: [ @card ], target_locale: "pt", source_locale: "en", fresh: true)
    assert_equal 1, @client.prompts.size
    assert_equal "NEW", out.first["text"]
    assert_not_includes @client.prompts.first, "note", "a card with no note sends none"
  end
end
