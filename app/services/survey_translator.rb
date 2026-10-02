require "anthropic"

# Translates a Verto's cards into another language while preserving structure
# EXACTLY: same number of cards, same option count and order per card. That
# structural invariant is what keeps results aligned across languages — answers
# are stored against the primary-language (canonical) option, and every
# translation is just a parallel label for the same positional option.
#
# Returns an array (aligned to the input cards) of:
#   { "text" => ..., "description" => ..., "options" => [...] }
# which the caller merges into each card's i18n[locale] — or nil for a card
# the model did not return, which the caller leaves untranslated.
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
  # Cards per call. A card's translation is ~100–250 output tokens (more with
  # options, pages or a modal), so twelve leaves MAX_TOKENS room to spare.
  BATCH_SIZE = 12

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
              index: { type: "integer", description: "The source card's `index`, copied exactly — this is how each translation is matched to its card." },
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
              },
              responses: {
                type: "array",
                items: { type: "string" },
                description: "Translated tap-card answer labels in the SAME order and SAME count as the source's `responses`. Keep an empty string empty. Empty array if the source had none."
              }
            },
            required: %w[index text options]
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
    - Translate `responses` (a tap card's answer labels, e.g. "Strongly
      agree") when the source card has them: the SAME number, in the SAME
      order, each as short as its source — they are buttons. Leave an empty
      label empty.
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
                      .each_with_index.map do |hit, i|
                        noted.call(source[i]) || copy_of_source?(source[i], hit, source_locale, target_locale) ? nil : hit
                      end
    end
    misses = source.each_with_index.reject { |_, i| cached[i] }
    return cached if misses.empty?

    miss_cards   = misses.map(&:first)
    miss_indices = misses.map(&:last)

    # In batches, because MAX_TOKENS bounds one reply and a whole deck in one
    # reply ran past it: Unbounded Alliance's Spanish stopped part-way, and
    # every card after that point was stored as its English. Each batch is its
    # own call, so a long deck costs more calls rather than losing its tail.
    translated_misses = miss_cards.each_slice(BATCH_SIZE).flat_map do |batch|
      translate_batch(batch, source_locale, target_locale, target, noted)
    end

    # Merge cache hits + fresh translations into the source-aligned shape.
    result = cached.dup
    miss_indices.each_with_index { |orig_idx, i| result[orig_idx] = translated_misses[i] }
    result
  end

  private

  # One call for up to BATCH_SIZE cards. A card the model did not return comes
  # back nil — never as its own source text — so the caller leaves it
  # untranslated, the Language check screen says so, and asking again fills it.
  # Source text dressed as a translation is the one outcome nothing downstream
  # can see: it counts as translated, it is never re-asked for, and a Spanish
  # respondent reads English with every screen reporting Spanish.
  # A "translation" whose question is the source question word for word, into
  # a different language. Entries like that went into the cache before the
  # translator stopped filling gaps with source text, and a cache hit is
  # exactly what Try again gets — so without this the repair would hand the
  # same English straight back, for ever. Between English variants identical
  # is the right answer; words-free text is the same in every language.
  def copy_of_source?(card, translation, source_locale, target_locale)
    return false unless translation.is_a?(Hash) && card.is_a?(Hash)
    return false if SupportedLocales.english?(source_locale) && SupportedLocales.english?(target_locale)

    text = card["text"].to_s.strip
    text.match?(/\p{L}/) && translation["text"].to_s.strip == text
  end

  # The labels a tap card stores for its answers, in order — "" where an answer
  # carries none and takes the preset's translated label instead. Never seen
  # by the translator before: a creator's "Strongly agree" stayed English in
  # every language.
  def self.response_labels(card)
    return [] unless card.is_a?(Hash) && card["responses"].is_a?(Array)
    card["responses"].map { |r| r.is_a?(Hash) ? r["label"].to_s.strip : "" }
  end

  def translate_batch(batch, source_locale, target_locale, target, noted)
    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [ TOOL ],
      tool_choice: { type: "tool", name: "emit_translation" },
      messages: [ { role: "user", content: user_message(batch, source_locale, target) } ]
    )
    log_usage("SurveyTranslator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    translated = align(batch, Array(deep_stringify(input_of(block))["cards"]))

    # A batch that hit the token ceiling is reported and kept out of the cache:
    # what it did return may stop mid-card, and a cached half-answer would be
    # served to every Verto with these words from now on.
    if truncated?(response)
      ErrorReporting.report(
        "SurveyTranslator",
        RuntimeError.new("translation truncated at #{MAX_TOKENS} output tokens — #{batch.size} cards sent, cache write skipped"),
        target_locale: target_locale.to_s, cards: batch.size
      )
    else
      batch.zip(translated).each do |card, translation|
        next if translation.nil? || noted.call(card) ||
                copy_of_source?(card, translation, source_locale, target_locale)
        TranslationCache.write(card, source_locale: source_locale, target_locale: target_locale, translation: translation)
      end
    end

    translated
  end

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
      labels = self.class.response_labels(card)
      entry[:responses] = labels if labels.any?(&:present?)
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
  # text/labels for anything missing or mis-sized WITHIN a card the model
  # returned. A card it did not return at all is nil.
  def align(source, translated)
    # By the index each entry echoes, not by where it sits in the reply. A
    # model that skips one card in the middle of a batch used to shift every
    # card after it, and card 7 was stored with card 8's question — the one
    # failure here a reviewer could not even see as missing. A reply with no
    # indexes at all (an older cached shape, a model ignoring the field) is
    # still read positionally, which is all there is to go on.
    entries = Array(translated).select { |t| t.is_a?(Hash) }
    by_index = entries.each_with_object({}) do |t, h|
      i = Integer(t["index"], exception: false)
      h[i] = t if i && i.between?(0, source.size - 1) && !h.key?(i)
    end
    by_index = nil unless by_index.size == entries.size

    source.each_with_index.map do |card, i|
      t = by_index ? by_index[i] : translated[i]
      # Not returned at all: nothing to align, and the source words are not a
      # translation of themselves. See translate_batch.
      next nil unless t.is_a?(Hash)

      # Within a returned card, a field or slot the model left out stays BLANK
      # rather than being filled with the source words. The player falls back
      # per field and per slot either way (ApplicationHelper#localized_card),
      # so a respondent reads the same thing — but blank is what the Language
      # check screen can see and Try again can repair, and English stored as
      # the translation is neither.
      src_opts   = Array(card["options"])
      trans_opts = Array(t["options"])
      entry = {
        "text"        => t["text"].to_s.strip,
        "description" => t["description"].to_s.strip,
        "options"     => src_opts.each_index.map { |j| trans_opts[j].to_s.strip }
      }

      pages = align_pages(card, t)
      entry["pages"] = pages if pages.any?

      # A tap card's own answer labels, positional like options. Only when the
      # card stores words of its own: an unlabelled preset answer is translated
      # by the locale files (TapScales.preset_label), not by this.
      src_labels = self.class.response_labels(card)
      if src_labels.any?(&:present?)
        trans_labels = Array(t["responses"])
        labels = src_labels.each_index.map { |j| src_labels[j].present? ? trans_labels[j].to_s.strip : "" }
        entry["responses"] = labels if labels.any?(&:present?)
      end

      (%w[explanation modal_title modal_body] + Survey::NPS_ANCHOR_KEYS).each do |field|
        entry[field] = t[field].to_s.strip if card[field].present? && t[field].present?
      end

      entry
    end
  end

  # Narrative pages align by id, NOT by position — a creator can reorder pages
  # after translating, and the sanitizer already stores them id-keyed for that
  # reason (Survey.sanitize_cards_images!). A page the model dropped, renamed or
  # returned empty comes back blank — the count never drifts, and the player
  # shows that page's source text in its place.
  def align_pages(card, translation)
    src_pages = Array(card["pages"]).select { |p| p.is_a?(Hash) && p["id"].present? }
    return [] if src_pages.empty?

    by_id = Array(translation["pages"]).each_with_object({}) do |p, acc|
      acc[p["id"].to_s] = p["text"] if p.is_a?(Hash) && p["id"].present?
    end

    src_pages.map do |p|
      id = p["id"].to_s
      { "id" => id, "text" => by_id[id].to_s.strip }
    end
  end

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
