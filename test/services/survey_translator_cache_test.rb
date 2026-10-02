require "test_helper"

class SurveyTranslatorCacheTest < ActiveSupport::TestCase
  def setup
    TranslationCache.delete_all
  end

  # Minimal fake Anthropic client that records call count and replays a
  # fixed tool-use response shape per call.
  class FakeClient
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def messages
      self
    end

    def create(model:, max_tokens:, system:, tools:, tool_choice:, messages:)
      @calls += 1
      Struct.new(:content, :usage).new(
        [
          Struct.new(:type, :input).new(:tool_use, {
            cards: [
              { text: "TRANSLATED", description: "", options: [ "A_T", "B_T" ] }
            ]
          })
        ],
        # Mirror the real response shape so usage logging has fields to read.
        Struct.new(:input_tokens, :output_tokens,
                   :cache_creation_input_tokens, :cache_read_input_tokens)
              .new(100, 20, 0, 0)
      )
    end
  end

  test "first call hits the API, second identical call uses cache and skips the API" do
    fake = FakeClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    card = { "type" => "multiple_choice", "text" => "Hello",
             "description" => "", "options" => [ "A", "B" ] }

    out1 = translator.call(cards: [ card ], target_locale: "es", source_locale: "en")
    assert_equal 1, fake.calls
    assert_equal "TRANSLATED", out1.first["text"]
    assert_equal 1, TranslationCache.count

    # Same source content + same target = cache hit. No new API call.
    out2 = translator.call(cards: [ card ], target_locale: "es", source_locale: "en")
    assert_equal 1, fake.calls, "second call should NOT hit the API"
    assert_equal out1, out2
  end

  test "different target locale is a separate cache entry" do
    fake = FakeClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    card = { "type" => "multiple_choice", "text" => "Hello",
             "description" => "", "options" => [ "A", "B" ] }

    translator.call(cards: [ card ], target_locale: "es", source_locale: "en")
    translator.call(cards: [ card ], target_locale: "fr", source_locale: "en")

    assert_equal 2, fake.calls
    assert_equal 2, TranslationCache.count
  end

  test "common-question cards are translated like any other card (not skipped)" do
    # Guard against a regression where someone might be tempted to skip cards
    # carrying a common_question_id. They must be translated so the player
    # presents them in the Verto's language alongside everything else; the
    # SOURCE-language verbatim guarantee is enforced separately in
    # SurveyGenerator#reconcile_common_cards! (the Ruby reconcile step),
    # not by side-stepping translation.
    fake = FakeClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    common_card = { "type" => "rating", "text" => "How safe?",
                    "description" => "", "options" => [ "1", "2", "3", "4", "5" ],
                    "common_question_id" => 42, "common_question_set_id" => 7 }

    out = translator.call(cards: [ common_card ], target_locale: "fr", source_locale: "en")
    assert_equal 1, fake.calls, "common card must be sent to the API like any other"
    assert_equal 1, out.size
    assert_equal "TRANSLATED", out[0]["text"]
  end

  test "mixed batch only sends cache misses to the API" do
    fake = FakeClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    cached_card = { "type" => "multiple_choice", "text" => "Hello",
                    "description" => "", "options" => [ "A", "B" ] }
    new_card    = { "type" => "multiple_choice", "text" => "World",
                    "description" => "", "options" => [ "C", "D" ] }

    # Prime the cache with cached_card.
    translator.call(cards: [ cached_card ], target_locale: "es", source_locale: "en")
    assert_equal 1, fake.calls

    # Now mixed: cached_card should come from cache, new_card hits the API.
    out = translator.call(cards: [ cached_card, new_card ], target_locale: "es", source_locale: "en")
    assert_equal 2, fake.calls, "exactly one extra API call for the new card"
    assert_equal 2, out.size
    assert_equal "TRANSLATED", out[0]["text"]
    assert_equal "TRANSLATED", out[1]["text"]
  end

  # Returns fewer cards than it was sent, and says why — the shape of a batch
  # that ran out of output budget. MAX_TOKENS bounds the whole batch, so the
  # bigger the batch the likelier this is.
  class TruncatingClient
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def messages = self

    def create(model:, max_tokens:, system:, tools:, tool_choice:, messages:)
      @calls += 1
      Struct.new(:content, :usage, :stop_reason).new(
        [ Struct.new(:type, :input).new(:tool_use, {
          cards: [ { text: "TRANSLATED", description: "", options: [ "A_T", "B_T" ] } ]
        }) ],
        Struct.new(:input_tokens, :output_tokens,
                   :cache_creation_input_tokens, :cache_read_input_tokens).new(100, 20, 0, 0),
        "max_tokens"
      )
    end
  end

  test "a truncated batch still returns, but is never cached" do
    fake = TruncatingClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    cards = [
      { "type" => "multiple_choice", "text" => "One", "description" => "", "options" => [ "A", "B" ] },
      { "type" => "multiple_choice", "text" => "Two", "description" => "", "options" => [ "C", "D" ] }
    ]

    out = translator.call(cards: cards, target_locale: "es", source_locale: "en")

    # The request still succeeds — a partly translated deck beats none — and the
    # shortfall comes back empty rather than as its own English, which would be
    # stored as the translation and counted as one everywhere downstream.
    assert_equal 2, out.size
    assert_equal "TRANSLATED", out[0]["text"]
    assert_nil out[1], "the truncated tail is untranslated, not translated into English"

    # The important half: source text must NOT be cached as if it were a
    # translation, or the gap becomes permanent and invisible.
    assert_equal 0, TranslationCache.count, "a truncated batch must not poison the cache"

    # And a retry gets a fresh attempt rather than a cache hit.
    translator.call(cards: cards, target_locale: "es", source_locale: "en")
    assert_equal 2, fake.calls, "the retry must reach the API again"
  end
end
