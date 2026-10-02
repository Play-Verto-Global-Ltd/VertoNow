require "test_helper"

# The intro modal is respondent-facing copy, so it has to travel the whole
# translation path the question itself does: sent to the model, aligned back,
# merged into i18n, cache-keyed so a card that GAINS one misses. A field that
# stops anywhere along that road leaves a Spanish respondent reading a Spanish
# question under an English pop-up.
class SurveyTranslatorCardModalTest < ActiveSupport::TestCase
  def setup
    TranslationCache.delete_all
  end

  class RecordingClient
    attr_reader :calls, :last_message

    def initialize(cards_payload)
      @cards_payload = cards_payload
      @calls = 0
    end

    def messages = self

    def create(model:, max_tokens:, system:, tools:, tool_choice:, messages:)
      @calls += 1
      @last_message = messages.first[:content]
      Struct.new(:content, :usage).new(
        [ Struct.new(:type, :input).new(:tool_use, { cards: @cards_payload }) ],
        Struct.new(:input_tokens, :output_tokens,
                   :cache_creation_input_tokens, :cache_read_input_tokens).new(10, 5, 0, 0)
      )
    end
  end

  def translator_with(client)
    t = SurveyTranslator.new(api_key: "x")
    t.instance_variable_set(:@client, client)
    t
  end

  def modal_card
    { "type" => "yes_no", "text" => "Did you use it?", "options" => %w[Yes No],
      "modal_title" => "Before you answer", "modal_body" => "We mean in the last year." }
  end

  test "the tool schema exposes both modal fields" do
    props = SurveyTranslator::TOOL[:input_schema][:properties][:cards][:items][:properties]

    assert props.key?(:modal_title)
    assert props.key?(:modal_body)
  end

  test "they are sent only for the cards that have one" do
    client = RecordingClient.new([ { text: "x", options: [] } ])
    translator_with(client).call(
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      target_locale: "fr"
    )

    assert_not_includes client.last_message, "modal_title"
    assert_not_includes client.last_message, "modal_body"
  end

  test "a translated modal comes back aligned" do
    client = RecordingClient.new([
      { text: "L'as-tu utilisé ?", options: %w[Oui Non],
        modal_title: "Avant de répondre", modal_body: "Sur la dernière année." }
    ])
    out = translator_with(client).call(cards: [ modal_card ], target_locale: "fr").first

    assert_equal "Avant de répondre", out["modal_title"]
    assert_equal "Sur la dernière année.", out["modal_body"]
  end

  # A skipped modal is left untranslated rather than stored as its English —
  # English stored as the French is invisible to every screen that checks. The
  # respondent still gets the English pop-up, never an empty one: the player
  # falls back per field.
  test "a modal the model skipped is left untranslated, and the player shows the source" do
    client = RecordingClient.new([ { text: "L'as-tu utilisé ?", options: %w[Oui Non] } ])
    out = translator_with(client).call(cards: [ modal_card ], target_locale: "fr").first

    assert_nil out["modal_title"]
    assert_nil out["modal_body"]

    card  = Survey.merge_card_translations([ modal_card ], "fr", [ out ]).first
    shown = ApplicationController.helpers.localized_card(card, "fr", "en")
    assert_equal "Before you answer", shown["modal_title"], "never an empty pop-up"
    assert_equal "We mean in the last year.", shown["modal_body"]
  end

  test "adding a modal misses the translation cache" do
    plain = { "type" => "yes_no", "text" => "Did you use it?", "options" => %w[Yes No] }

    assert_not_equal TranslationCache.source_hash_for(plain),
                     TranslationCache.source_hash_for(modal_card),
                     "a warm cache entry that predates the modal would keep it English forever"
  end

  test "the Language check screen reviews both fields" do
    assert_includes LanguageCheckLines::SCALAR_FIELDS, "modal_title"
    assert_includes LanguageCheckLines::SCALAR_FIELDS, "modal_body"
  end

  test "a modal line falls back to the primary wording, like every other field" do
    card = modal_card.merge(
      "cid" => "c1",
      "i18n" => { "es" => { "text" => "¿Lo usaste?", "modal_title" => "Antes de responder" } }
    )
    content = LanguageCheckLines.translated_content(card, "es",
                                                    LanguageCheckLines.canonical_content(card))

    assert_equal "Antes de responder", content["modal_title"]
    assert_equal "We mean in the last year.", content["modal_body"],
                 "the player renders the primary body here, so the reviewer must see it"
    assert_includes content["untranslated"], "modal_body"
  end

  test "an edit to one language's modal writes only that language's entry" do
    card = Survey.apply_translation_edit(modal_card.merge("cid" => "c1"), "es",
                                         { "modal_body" => "Del último año." })

    assert_equal "Del último año.", card.dig("i18n", "es", "modal_body")
    assert_equal "We mean in the last year.", card["modal_body"], "the primary is untouched"
  end

  test "clearing a translated modal removes the override rather than storing a blank" do
    card = modal_card.merge("i18n" => { "es" => { "modal_body" => "Del último año." } })
    out  = Survey.apply_translation_edit(card, "es", { "modal_body" => "  " })

    refute out.dig("i18n", "es")&.key?("modal_body"),
           "blank means 'show the original', which is what the player already does"
  end
end
