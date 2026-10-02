require "anthropic"

# Translates a Verto's cards into another language while preserving structure
# EXACTLY: same number of cards, same option count and order per card. That
# structural invariant is what keeps results aligned across languages — answers
# are stored against the primary-language (canonical) option, and every
# translation is just a parallel label for the same positional option.
#
# Returns an array (aligned to the input cards) of:
#   { "text" => ..., "description" => ..., "options" => [...] }
# which the caller merges into each card's i18n[locale].
#
# Common Question cards are deliberately NOT skipped — a French Verto must
# present its common cards in French alongside the rest of the deck. The
# verbatim guarantee on Common Questions applies to the SOURCE language only
# (enforced by SurveyGenerator#reconcile_common_cards!); per-locale i18n
# entries are normal translations cached via TranslationCache for reuse
# across every Verto that attaches the same set into the same locale.
class SurveyTranslator
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 4096

  TOOL = {
    name: "emit_translation",
    description: "Emit translations for every card, preserving order and option counts exactly.",
    input_schema: {
      type: "object",
      properties: {
        cards: {
          type: "array",
          description: "One entry per source card, in the SAME order, with the SAME number of entries.",
          items: {
            type: "object",
            properties: {
              text: { type: "string", description: "Translated card/question text." },
              description: { type: "string", description: "Translated sub-text. Empty string if the source had none." },
              options: {
                type: "array",
                items: { type: "string" },
                description: "Translated option labels in the SAME order and SAME count as the source card. Empty array if the source had none."
              },
              pages: {
                type: "array",
                description: "Translated scenario narrative pages. One entry per source page, echoing its id EXACTLY. Empty array if the source had none.",
                items: {
                  type: "object",
                  properties: {
                    id:   { type: "string", description: "The source page's id, copied verbatim — never invent or renumber." },
                    text: { type: "string", description: "That page's translated narrative text." }
                  },
                  required: %w[id text]
                }
              },
              explanation: {
                type: "string",
                description: "Translated quiz answer explanation, shown after the respondent answers. Empty string if the source had none."
              },
              modal_title: {
                type: "string",
                description: "Translated heading of the intro modal shown over this card. Empty string if the source had none."
              },
              modal_body: {
                type: "string",
                description: "Translated body of the intro modal shown over this card — the creator's explanation of what the question is asking. Empty string if the source had none."
              },
              nps_low_label: {
                type: "string",
                description: "Translated caption beside the LOWEST point of an NPS/liquid scale (e.g. 'I have no say at all'). Empty string if the source had none."
              },
              nps_high_label: {
                type: "string",
                description: "Translated caption beside the HIGHEST point of an NPS/liquid scale (e.g. 'I am a decision maker'). Empty string if the source had none."
              }
            },
            required: %w[text options]
          }
        }
      },
      required: %w[cards]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You are an expert localiser for survey ("Verto") experiences. Translate the
    provided cards into the target language so they read as if originally written
    by a native speaker — natural, idiomatic, and every bit as clear and engaging
    as the source. This is not a literal word-for-word translation.

    Hard rules (these keep response data aligned across languages):
    - Output EXACTLY one entry per source card, in the SAME order.
    - For each card, output the SAME number of options, in the SAME order. Never
      add, drop, merge, split or reorder options.
    - Translate the meaning of each option faithfully; option N in your output
      must correspond to option N in the source.
    - For a card with narrative `pages`, output the SAME number of pages and
      copy each page's `id` EXACTLY as given. Match pages by id, never by
      position, and never invent, drop, merge or renumber one.
    - Translate `explanation` (the after-the-answer quiz feedback) when the
      source card has one; omit it otherwise.
    - Translate `modal_title` and `modal_body` (the pop-up shown over the card
      before it is answered) when the source card has them; omit them
      otherwise. This is the creator explaining the question in their own
      voice — keep that voice, not a formal register.
    - Translate `nps_low_label` and `nps_high_label` (the short captions beside
      the lowest and highest points of a scale) when the source card has them;
      omit them otherwise. Keep them as short as the source — they sit in a
      narrow column beside the scale.
    - Keep translations concise to fit UI constraints: question text short
      (aim under ~70 characters), option labels short (aim under ~20 characters).
    - Preserve numbers, and leave proper nouns / brand names untranslated.
    - For scale labels (e.g. 0–10, "Not likely"…"Very likely") translate the
      words but keep any numerals as-is.
    - A card may carry a `note` from its author saying what a word or phrase
      means there (e.g. "power" as in motivation, not authority). Use it to
      choose the meaning you translate. It is guidance, not copy: never
      translate it, quote it or put any of it in your output.

    Output via the emit_translation tool.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # cards: array of card hashes (string keys). Returns the aligned translation
  # array described above. Falls back to source content per field/slot if the
  # model returns a malformed or mis-sized response, so the alignment invariant
  # always holds.
  #
  # `notes` is { cid => the author's note on what the card means } (see
  # LanguageCheck#translator_note). A noted card never touches the cache in
  # either direction: the cache is keyed by the words alone, so a hit would
  # hand back the translation made before anyone said what "power" meant, and
  # a write would serve the note's reading to every other Verto with the same
  # sentence. `fresh:` skips the lookup for everything — somebody pressing
  # Re-translate is asking for a new translation, not the one they just read.
  def call(cards:, target_locale:, source_locale: SupportedLocales::DEFAULT, notes: {}, fresh: false)
    source = Array(cards)
    return [] if source.empty?

    target = SupportedLocales.find(target_locale)
    raise ArgumentError, "Unsupported locale: #{target_locale}" unless target

    @notes = Hash(notes).transform_keys(&:to_s).transform_values { |v| v.to_s.strip }.reject { |_, v| v.blank? }
    noted  = ->(card) { card.is_a?(Hash) && @notes.key?(card["cid"].to_s) }

    # Cache lookup: cards we've already translated with the same source
    # content for this target skip Claude entirely.
    cached = if fresh
      Array.new(source.size)
    else
      TranslationCache.lookup_many(source, source_locale: source_locale, target_locale: target_locale)
                      .each_with_index.map { |hit, i| noted.call(source[i]) ? nil : hit }
    end
    misses = source.each_with_index.reject { |_, i| cached[i] }
    return cached if misses.empty?

    miss_cards   = misses.map(&:first)
    miss_indices = misses.map(&:last)

    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [ TOOL ],
      tool_choice: { type: "tool", name: "emit_translation" },
      messages: [ { role: "user", content: user_message(miss_cards, source_locale, target) } ]
    )
    log_usage("SurveyTranslator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    translated_misses = align(miss_cards, Array(deep_stringify(input_of(block))["cards"]))

    # A batch whose output hit the token ceiling returns fewer cards than it was
    # given, and `align` backfills the shortfall with SOURCE-language text rather
    # than failing. That is the right call for a live request — a partly
    # translated deck beats none — but caching it would make the gap permanent
    # and invisible. So on truncation: report it, and skip the cache write so the
    # next attempt gets a clean run at these cards.
    if truncated?(response)
      ErrorReporting.report(
        "SurveyTranslator",
        RuntimeError.new("translation truncated at #{MAX_TOKENS} output tokens — #{miss_cards.size} cards sent, cache write skipped"),
        target_locale: target_locale.to_s, cards: miss_cards.size
      )
    else
      # Write each miss back to the cache so the next call hits it.
      miss_cards.zip(translated_misses).each do |card, translation|
        next if noted.call(card)
        TranslationCache.write(card, source_locale: source_locale, target_locale: target_locale, translation: translation)
      end
    end

    # Merge cache hits + fresh translations into the source-aligned shape.
    result = cached.dup
    miss_indices.each_with_index { |orig_idx, i| result[orig_idx] = translated_misses[i] }
    result
  end

  private

  def user_message(source, source_locale, target)
    payload = source.each_with_index.map do |card, i|
      entry = {
        index: i,
        type: card["type"],
        text: card["text"].to_s,
        description: card["description"].to_s,
        options: Array(card["options"]).map(&:to_s)
      }
      # Only sent for the cards that have them, so a deck of ordinary questions
      # doesn't pay for two empty fields on every card.
      pages = Array(card["pages"]).filter_map do |p|
        { id: p["id"].to_s, text: p["text"].to_s } if p.is_a?(Hash) && p["id"].present?
      end
      entry[:pages] = pages if pages.any?
      entry[:explanation] = card["explanation"].to_s if card["explanation"].present?
      entry[:modal_title] = card["modal_title"].to_s if card["modal_title"].present?
      entry[:modal_body]  = card["modal_body"].to_s  if card["modal_body"].present?
      Survey::NPS_ANCHOR_KEYS.each { |k| entry[k.to_sym] = card[k].to_s if card[k].present? }
      note = @notes.to_h[card["cid"].to_s]
      entry[:note] = note if note.present?
      entry
    end

    <<~MSG
      Source language: #{SupportedLocales.english_name(source_locale) || source_locale}
      Target language: #{target.english_name} (#{target.native_name})

      Translate every card below into #{target.english_name}. Return exactly
      #{source.size} card entries in order, each with the same option count as
      its source.
      #{variant_note(source_locale, target.code)}
      Source cards (JSON):

      #{JSON.pretty_generate(payload)}
    MSG
  end

  # A Verto can carry BOTH English variants as content languages, in which case
  # this "translation" is a respelling and nothing else. Saying so is cheaper
  # than letting a model decide how much licence "translate into English (US)"
  # gives it — the answer we want is colour→color and not one word more.
  def variant_note(source_locale, target_locale)
    return "" unless SupportedLocales.english?(source_locale) && SupportedLocales.english?(target_locale)

    "Both languages are English: change ONLY the spelling to the target " \
    "variant (e.g. colour/color, organise/organize). Keep every other word, " \
    "the punctuation and the phrasing exactly as they are."
  end

  # Did the model run out of output budget mid-batch? `try` rather than a direct
  # read because the suite's client fakes are minimal Structs that carry only
  # the fields they need — an absent stop_reason simply means "not truncated".
  def truncated?(response)
    response.try(:stop_reason).to_s == "max_tokens"
  end

  # Force the output to match the source's shape exactly, falling back to source
  # text/labels for anything missing or mis-sized.
  def align(source, translated)
    source.each_with_index.map do |card, i|
      t          = translated[i].is_a?(Hash) ? translated[i] : {}
      src_opts   = Array(card["options"])
      trans_opts = Array(t["options"])
      entry = {
        "text"        => t["text"].presence || card["text"].to_s,
        "description" => t["description"].presence || card["description"].to_s,
        "options"     => src_opts.each_with_index.map { |o, j| trans_opts[j].presence || o.to_s }
      }

      pages = align_pages(card, t)
      entry["pages"] = pages if pages.any?

      if card["explanation"].present?
        entry["explanation"] = t["explanation"].presence || card["explanation"].to_s
      end

      # Same shape as `explanation`: carried only for the cards that have one,
      # falling back to the source words so a modal is never blank in a
      # language the model skipped — blank here would mean a respondent gets an
      # empty pop-up, not the English one.
      (%w[modal_title modal_body] + Survey::NPS_ANCHOR_KEYS).each do |field|
        entry[field] = t[field].presence || card[field].to_s if card[field].present?
      end

      entry
    end
  end

  # Narrative pages align by id, NOT by position — a creator can reorder pages
  # after translating, and the sanitizer already stores them id-keyed for that
  # reason (Survey.sanitize_cards_images!). A page the model dropped, renamed or
  # returned empty falls back to its source text, so the page count never drifts.
  def align_pages(card, translation)
    src_pages = Array(card["pages"]).select { |p| p.is_a?(Hash) && p["id"].present? }
    return [] if src_pages.empty?

    by_id = Array(translation["pages"]).each_with_object({}) do |p, acc|
      acc[p["id"].to_s] = p["text"] if p.is_a?(Hash) && p["id"].present?
    end

    src_pages.map do |p|
      id = p["id"].to_s
      { "id" => id, "text" => by_id[id].presence || p["text"].to_s }
    end
  end

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
