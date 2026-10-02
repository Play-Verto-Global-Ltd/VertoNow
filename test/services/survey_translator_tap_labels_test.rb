require "test_helper"

# A tap card's answer labels are the creator's own words once kept ("Strongly
# agree"), and they were never sent to the translator: every tap card read
# Spanish above English buttons. And since "Translated" came to mean every
# worded field, such a card could never be finished — Try again asked for it
# and got nothing back for the labels.
class SurveyTranslatorTapLabelsTest < ActiveSupport::TestCase
  class LabelClient
    attr_reader :payloads

    def initialize
      @payloads = []
    end

    def messages = self

    def create(messages:, **)
      sent = JSON.parse(messages.first[:content][/\[.*\]/m])
      @payloads << sent
      cards = sent.map do |c|
        { index: c["index"], text: "es:#{c['text']}", options: [],
          responses: Array(c["responses"]).map { |l| l.empty? ? "" : "es:#{l}" } }
      end
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

  def tap_card
    { "type" => "tap_card", "cid" => "c_tap", "text" => "How do you feel about school?",
      "options" => [ "Teachers listen" ],
      "responses" => [ { "key" => "disagree", "label" => "Strongly disagree" },
                       { "key" => "unsure" },
                       { "key" => "agree", "label" => "Strongly agree" } ] }
  end

  def translate(card)
    client = LabelClient.new
    translator = SurveyTranslator.new(api_key: "x").tap { |t| t.instance_variable_set(:@client, client) }
    [ translator.call(cards: [ card ], target_locale: "es", source_locale: "en").first, client ]
  end

  test "a tap card's own answer labels are sent and come back in place" do
    out, client = translate(tap_card)

    assert_equal [ "Strongly disagree", "", "Strongly agree" ], client.payloads.first.first["responses"]
    assert_equal [ "es:Strongly disagree", "", "es:Strongly agree" ], out["responses"],
                 "positional, and an unlabelled preset answer stays blank for the locale files"
  end

  test "the Spanish card shows Spanish buttons" do
    out, = translate(tap_card)
    card = Survey.merge_card_translations([ tap_card ], "es", [ out ]).first
    labels = TapScales.for_card(card, locale: "es", default_locale: "en").map { |r| r["label"] }

    assert_equal "es:Strongly disagree", labels.first
    assert_equal "es:Strongly agree", labels.last
  end

  test "a translated tap card counts as done, so Try again stops asking for it" do
    out, = translate(tap_card)
    card = Survey.merge_card_translations([ tap_card ], "es", [ out ]).first
    card["i18n"]["es"]["options"] = [ "es:Teachers listen" ]

    assert_not LanguageCheckLines.needs_translation?(card, "es", "en")
  end

  test "a card with no labels of its own sends none and hashes as it always did" do
    plain = tap_card.merge("responses" => [ { "key" => "no" }, { "key" => "unsure" }, { "key" => "yes" } ])
    _, client = translate(plain)
    assert_nil client.payloads.first.first["responses"]
    assert_equal TranslationCache.source_hash_for(plain.except("responses")),
                 TranslationCache.source_hash_for(plain),
                 "every cached translation of an unlabelled card stays warm"
  end
end
