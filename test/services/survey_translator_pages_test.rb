require "test_helper"

# Scenario narrative pages and quiz answer explanations were respondent-facing
# copy the translator never carried, so they stayed in the source language in
# every secondary locale. These cover the whole path: translate → merge → read.
class SurveyTranslatorPagesTest < ActiveSupport::TestCase
  def setup
    TranslationCache.delete_all
  end

  # Records what it was asked to translate and replays a canned translation, so
  # the assertions can be about the request as well as the response.
  class RecordingClient
    attr_reader :calls, :last_message, :last_tool

    def initialize(cards_payload)
      @cards_payload = cards_payload
      @calls = 0
    end

    def messages = self

    def create(model:, max_tokens:, system:, tools:, tool_choice:, messages:)
      @calls += 1
      @last_message = messages.first[:content]
      @last_tool    = tools.first
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

  def scenario_card
    {
      "type" => "scenario", "text" => "A dilemma", "description" => "",
      "options" => [ "Stay", "Go" ],
      "pages" => [ { "id" => "pg_a", "text" => "It was raining." },
                   { "id" => "pg_b", "text" => "You had no coat." } ]
    }
  end

  test "the tool schema exposes pages and explanation" do
    props = SurveyTranslator::TOOL[:input_schema][:properties][:cards][:items][:properties]
    assert props.key?(:pages), "pages must be translatable"
    assert props.key?(:explanation), "explanation must be translatable"
  end

  test "pages and explanation are sent to the model only when the card has them" do
    client = RecordingClient.new([ { text: "x", options: [] } ])
    translator_with(client).call(
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ],
      target_locale: "fr"
    )
    assert_not_includes client.last_message, "pages"
    assert_not_includes client.last_message, "explanation"
  end

  test "scenario pages round-trip and align by id, not position" do
    # Deliberately returned in the OPPOSITE order to the source: alignment must
    # follow the ids, because a creator can reorder pages after translating.
    client = RecordingClient.new([
      { text: "Un dilemme", description: "", options: [ "Rester", "Partir" ],
        pages: [ { id: "pg_b", text: "Tu n'avais pas de manteau." },
                 { id: "pg_a", text: "Il pleuvait." } ] }
    ])

    out = translator_with(client).call(cards: [ scenario_card ], target_locale: "fr")

    assert_includes client.last_message, "pg_a"
    assert_equal [ "pg_a", "pg_b" ], out.first["pages"].map { |p| p["id"] }
    assert_equal "Il pleuvait.", out.first["pages"][0]["text"]
    assert_equal "Tu n'avais pas de manteau.", out.first["pages"][1]["text"]
  end

  test "a page the model dropped comes back blank, keeping the page count" do
    client = RecordingClient.new([
      { text: "Un dilemme", options: [ "Rester", "Partir" ],
        pages: [ { id: "pg_a", text: "Il pleuvait." } ] } # pg_b missing
    ])

    out = translator_with(client).call(cards: [ scenario_card ], target_locale: "fr")

    assert_equal 2, out.first["pages"].size, "page count must never drift"
    assert_equal "", out.first["pages"][1]["text"], "the player shows the source page there"
  end

  test "a quiz explanation round-trips, and is left untranslated when absent" do
    client = RecordingClient.new([
      { text: "Q", options: [ "A", "B" ], explanation: "Parce que." }
    ])
    card = { "type" => "multiple_choice", "text" => "Q", "options" => [ "A", "B" ],
             "explanation" => "Because." }

    out = translator_with(client).call(cards: [ card ], target_locale: "fr")
    assert_equal "Parce que.", out.first["explanation"]

    # Clear the cache first — otherwise this second call legitimately hits the
    # entry the first one just wrote, and never reaches the client at all.
    TranslationCache.delete_all
    blank = RecordingClient.new([ { text: "Q", options: [ "A", "B" ] } ])
    out2  = translator_with(blank).call(cards: [ card ], target_locale: "fr")
    assert_nil out2.first["explanation"], "an unreturned explanation is not stored as its English"
  end

  test "the cache key includes pages, so editing one re-translates" do
    base    = scenario_card
    edited  = base.merge("pages" => [ base["pages"][0], { "id" => "pg_b", "text" => "The sun was out." } ])

    assert_not_equal TranslationCache.source_hash_for(base),
                     TranslationCache.source_hash_for(edited)
  end

  test "the cache key includes explanation" do
    card = { "text" => "Q", "options" => [ "A" ] }
    assert_not_equal TranslationCache.source_hash_for(card),
                     TranslationCache.source_hash_for(card.merge("explanation" => "Because."))
  end

  test "an ordinary card's cache key is unchanged, so warm entries stay warm" do
    # Guards the other side of the invalidation: adding these fields must not
    # bust the cache for the cards that don't have them.
    card = { "text" => "Hello", "description" => "", "options" => [ "A", "B" ] }
    legacy = Digest::SHA256.hexdigest(
      { "text" => "Hello", "description" => "", "options" => [ "A", "B" ] }.to_json
    )
    assert_equal legacy, TranslationCache.source_hash_for(card)
  end

  test "merge_card_translations writes pages and explanation into i18n" do
    merged = Survey.merge_card_translations(
      [ scenario_card.merge("explanation" => "Because.") ],
      "fr",
      [ { "text" => "Un dilemme", "options" => [ "Rester", "Partir" ],
          "pages" => [ { "id" => "pg_a", "text" => "Il pleuvait." } ],
          "explanation" => "Parce que." } ]
    )

    entry = merged.first["i18n"]["fr"]
    assert_equal "Parce que.", entry["explanation"]
    assert_equal "Il pleuvait.", entry["pages"].first["text"]
  end

  test "an ordinary card's i18n entry gains no empty keys" do
    merged = Survey.merge_card_translations(
      [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ],
      "fr",
      [ { "text" => "Q_fr", "options" => [ "Oui", "Non" ] } ]
    )

    entry = merged.first["i18n"]["fr"]
    assert_not entry.key?("pages")
    assert_not entry.key?("explanation")
  end

  test "localized_card serves the translated pages and explanation" do
    card = scenario_card.merge(
      "explanation" => "Because.",
      "i18n" => { "fr" => { "text" => "Un dilemme", "options" => [ "Rester", "Partir" ],
                            "pages" => [ { "id" => "pg_b", "text" => "Pas de manteau." } ],
                            "explanation" => "Parce que." } }
    )

    view = ApplicationController.helpers.localized_card(card, "fr", "en")

    assert_equal "Parce que.", view["explanation"]
    # pg_b translated, pg_a untranslated and so falling back — in source order.
    assert_equal [ "It was raining.", "Pas de manteau." ], view["pages"].map { |p| p["text"] }
  end
end
