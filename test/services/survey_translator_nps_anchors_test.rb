require "test_helper"

# The NPS scale's end captions (nps_low_label / nps_high_label) through the
# translation pipeline, which is more places than it looks: the tool schema, the
# prompt, the source payload, the alignment, the merge, the primary-language
# swap, the player's per-field fallback, the editor's store, the Language check
# screen — and the CACHE KEY, which is the one that decides whether any of the
# rest ever runs.
#
# Modelled on survey_translator_card_modal_test, because the captions are the
# same shape of field as the intro modal's words: optional, scalar,
# respondent-facing, and carried only for the cards that have them.
class SurveyTranslatorNpsAnchorsTest < ActiveSupport::TestCase
  LOW  = "I have no say at all".freeze
  HIGH = "I am a decision maker".freeze

  def anchored_card
    { "type" => "nps", "cid" => "n1", "text" => "How much say do you have?",
      "nps_low_label" => LOW, "nps_high_label" => HIGH }
  end

  def plain_card
    { "type" => "nps", "cid" => "n1", "text" => "How much say do you have?" }
  end

  # The one that makes the whole pipeline moot if it is wrong. A Verto that has
  # already been translated has a warm cache entry per card; if the key does not
  # move when a card gains captions, Claude is never called for that card again
  # and the captions stay in the source language in every other language, with
  # nothing on any screen to say why.
  test "adding captions misses the translation cache" do
    assert_not_equal TranslationCache.source_hash_for(plain_card),
                     TranslationCache.source_hash_for(anchored_card),
                     "a warm entry that predates the captions would keep them English forever"
  end

  test "changing one caption misses the cache too" do
    reworded = anchored_card.merge("nps_low_label" => "I have no influence")

    assert_not_equal TranslationCache.source_hash_for(anchored_card),
                     TranslationCache.source_hash_for(reworded)
  end

  # The other half of that: every card WITHOUT captions has to keep hashing
  # exactly as it did, or adding this feature would have cold-started the cache
  # for every deck in the product.
  test "a card with no captions hashes as it did before they existed" do
    before = Digest::SHA256.hexdigest({
      "text" => "How much say do you have?", "description" => "", "options" => []
    }.to_json)

    assert_equal before, TranslationCache.source_hash_for(plain_card)
  end

  test "the translator asks for both captions and aligns what comes back" do
    props = SurveyTranslator::TOOL.dig(:input_schema, :properties, :cards, :items, :properties)
    assert_includes props.keys.map(&:to_s), "nps_low_label"
    assert_includes props.keys.map(&:to_s), "nps_high_label"

    # A model that skipped one leaves it untranslated rather than storing the
    # source words as the translation; the player shows the source caption there,
    # so the scale is never unlabelled.
    aligned = SurveyTranslator.new(api_key: "x").send(
      :align, [ anchored_card ], [ { "text" => "Quel pouvoir ?", "options" => [],
                                     "nps_low_label" => "Aucun pouvoir" } ]
    ).first

    assert_equal "Aucun pouvoir", aligned["nps_low_label"]
    assert_nil aligned["nps_high_label"], "an unanswered caption is not stored as its English"
  end

  test "a merged translation lands in the card's own i18n entry" do
    cards = Survey.merge_card_translations([ anchored_card ], "fr", [
      { "text" => "Quel pouvoir ?", "options" => [],
        "nps_low_label" => "Aucun pouvoir", "nps_high_label" => "Je décide" }
    ])

    assert_equal "Aucun pouvoir", cards.first.dig("i18n", "fr", "nps_low_label")
    assert_equal "Je décide", cards.first.dig("i18n", "fr", "nps_high_label")
    assert_equal LOW, cards.first["nps_low_label"], "the primary is untouched"
  end

  # Promoting a language to primary moves every respondent-facing field with it.
  test "the captions move when a translation is promoted to primary" do
    card = anchored_card.merge("i18n" => { "fr" => {
      "text" => "Quel pouvoir ?", "nps_low_label" => "Aucun pouvoir", "nps_high_label" => "Je décide"
    } })
    out = Survey.swap_card_primary(card, "en", "fr")

    assert_equal "Aucun pouvoir", out["nps_low_label"]
    assert_equal "Je décide", out["nps_high_label"]
    assert_equal LOW, out.dig("i18n", "en", "nps_low_label"), "English keeps its own words"
  end

  # ── The Language check screen ─────────────────────────────────────────
  test "the screen reviews both captions, and labels them" do
    assert_includes LanguageCheckLines::SCALAR_FIELDS, "nps_low_label"
    assert_includes LanguageCheckLines::SCALAR_FIELDS, "nps_high_label"
    assert I18n.exists?("language_check.field.nps_low_label")
    assert I18n.exists?("language_check.field.nps_high_label")
  end

  test "a caption with no translation falls back to the primary wording" do
    card = anchored_card.merge("i18n" => { "es" => { "text" => "¿Cuánta voz?",
                                                     "nps_low_label" => "Ninguna voz" } })
    content = LanguageCheckLines.translated_content(card, "es",
                                                    LanguageCheckLines.canonical_content(card))

    assert_equal "Ninguna voz", content["nps_low_label"]
    assert_equal HIGH, content["nps_high_label"],
                 "the player renders the primary caption here, so the reviewer must see it"
    assert_includes content["untranslated"], "nps_high_label"
  end

  # Adding a field to SCALAR_FIELDS gives EVERY card of EVERY type a blank entry
  # for it, and the digest is what an approval is an approval OF — so hashing
  # the blanks would have made every approval in the product read "Approved,
  # then edited" on a line whose words had not changed.
  # The digest is what an approval is an approval OF, so this asserts the hash
  # a line HAD before the captions existed — reproduced, not approximated.
  # Every card of every type gained two blank keys when they were added to
  # SCALAR_FIELDS, and any change to the hashed payload lapses every approval
  # in the product at once. Dropping every blank (the first thing I wrote) does
  # that too: a card with no sub-text has always hashed one as "".
  test "adding the captions left every existing approval digest untouched" do
    lines = LanguageCheckLines
    plain = { "cid" => "c1", "type" => "yes_no", "text" => "Agree?", "options" => %w[Yes No] }

    before_captions = %w[modal_title modal_body text description explanation]
      .index_with { |f| plain[f].to_s }
      .merge("options" => %w[Yes No], "responses" => [], "pages" => [])

    assert_equal Digest::SHA256.hexdigest(before_captions.to_json),
                 lines.digest(lines.canonical_content(plain)),
                 "the hash of a line with no captions has to be the hash it already had, or " \
                 "every approval anyone has given reads 'Approved, then edited' on a line " \
                 "whose words have not changed"
  end

  test "a blank field that is NOT a caption still counts, as it always did" do
    lines = LanguageCheckLines
    content = lines.canonical_content({ "cid" => "c1", "type" => "yes_no", "text" => "Agree?" })

    refute_equal lines.digest(content.except("description")), lines.digest(content),
                 "dropping every blank would have moved the digest of every line with no " \
                 "sub-text — the same damage, one step quieter"
  end

  test "a caption that IS filled in moves the digest, because the words moved" do
    lines = LanguageCheckLines
    base  = lines.canonical_content(plain_card.merge("cid" => "n1"))
    with  = lines.canonical_content(anchored_card)

    assert_not_equal lines.digest(base), lines.digest(with)
  end

  # ── The write paths, which skip the cards sanitiser ───────────────────
  test "a reviewer's edit to a caption is capped, like the editor's is" do
    long = "z" * (NpsHelper::NPS_ANCHOR_MAX + 30)
    out  = Survey.apply_canonical_edit(anchored_card, { "nps_low_label" => long }, structural: true)

    assert_equal NpsHelper::NPS_ANCHOR_MAX, out["nps_low_label"].length
  end

  test "a caption cannot be written onto a card that is not an nps" do
    out = Survey.apply_canonical_edit(
      { "type" => "yes_no", "cid" => "c1", "text" => "Agree?" },
      { "nps_low_label" => "No say" }, structural: true
    )

    refute out.key?("nps_low_label"), "only a liquid scale has ends to caption"
  end

  test "a translated caption is capped and type-gated the same way" do
    long = "y" * (NpsHelper::NPS_ANCHOR_MAX + 30)
    out  = Survey.apply_translation_edit(anchored_card, "fr", { "nps_low_label" => long })
    assert_equal NpsHelper::NPS_ANCHOR_MAX, out.dig("i18n", "fr", "nps_low_label").length

    bare = Survey.apply_translation_edit({ "type" => "yes_no", "cid" => "c1", "text" => "Agree?" },
                                         "fr", { "nps_low_label" => "Aucun" })
    refute bare.dig("i18n", "fr")&.key?("nps_low_label")
  end
end
