# Every Verto ends with the same three set demographic questions, appended
# automatically at creation (generate, PDF import). They give every Verto a
# comparable demographic tail — birth year, location, gender — powering the
# research collective across the platform. Cards carry "demographic" => true
# so they're identifiable downstream and never appended twice.
module DemographicQuestions
  CARDS = [
    { "type" => "open_ended", "input" => "month", "text" => "When were you born?",
      "demographic" => true },
    { "type" => "open_ended", "input" => "location", "text" => "Where do you live?",
      "description" => "Powered by OpenStreetMap — helps build a map you can explore after finishing.",
      "demographic" => true },
    { "type" => "multiple_choice", "text" => "What gender best describes you?",
      "options" => [ "Male", "Female", "Non-binary", "Other", "Prefer not to say" ],
      "demographic" => true }
  ].freeze

  # The three cards resolved in `locale` (a Verto's default_locale), falling
  # back to the English above. Every Verto used to get the English tail
  # regardless of its language — a French generated Verto ended with "Where do
  # you live?". Translations live under `demographics.cards` in the locale
  # files, merged positionally; an options list is only taken whole and at the
  # registry length, because answers are positional.
  def self.cards(locale: nil)
    translated = Array(I18n.t("demographics.cards", locale: locale.presence || I18n.locale, default: nil))
    CARDS.each_with_index.map do |card, i|
      c = card.dup
      tr = translated[i]
      next c unless tr.is_a?(Hash)
      tr = tr.transform_keys(&:to_s)
      c["text"]        = tr["text"].to_s        if tr["text"].to_s.strip.present?
      c["description"] = tr["description"].to_s if tr["description"].to_s.strip.present?
      opts = tr["options"]
      c["options"] = opts.map(&:to_s) if opts.is_a?(Array) && opts.size == Array(c["options"]).size
      c
    end
  rescue I18n::InvalidLocale
    CARDS.map(&:dup)
  end

  def self.append_to(cards, locale: nil)
    list = Array(cards)
    return list if list.any? { |c| c.is_a?(Hash) && c["demographic"] }
    list + cards(locale: locale)
  end

  # ── Opt-in demographic questions ───────────────────────────────────────────
  # Unlike CARDS, never auto-appended: a creator adds these per-Verto from the
  # add-question modal's Demographics tiles. Keyed by `demographic_key` — the
  # discriminator the answer sync (PlayerController#sync_demographics_from_answers!)
  # and results segmentation slice on, and the reason two multiple-choice
  # demographic cards can coexist with the Gender tail card (which has no key).
  OPTIONAL_CARDS = {
    "heritage" => {
      "type" => "multiple_choice",
      "text" => "Which of these best reflects your heritage?",
      "description" => "Your ethnic or cultural background.",
      "options" => [ "Asian heritage", "Black, African or Caribbean heritage",
                     "Hispanic or Latino/a", "Middle Eastern or North African heritage",
                     "White or European heritage", "Indigenous heritage",
                     "Mixed or multiple heritage", "Another heritage", "Prefer not to say" ],
      "demographic" => true, "demographic_key" => "heritage"
    },
    # Deliberately framed around how people think and process information —
    # many neurodivergent respondents don't describe themselves as disabled or
    # having a disability, and a disability-framed question would undercount
    # exactly the people it is trying to understand.
    "neurodiversity" => {
      "type" => "select_many",
      "text" => "Do any of these describe you?",
      "description" => "About how you think and process information — choose any that apply.",
      "options" => [ "ADHD", "Autism", "Dyslexia", "Dyspraxia", "Dyscalculia",
                     "Tourette's", "Another form of neurodivergence",
                     "None of these", "Prefer not to say" ],
      "demographic" => true, "demographic_key" => "neurodiversity"
    }
  }.freeze

  # The core tail trio, addable one at a time from the add-question modal's
  # Demographics tiles — for a creator who deleted one and wants it back, or
  # who removed the tail for the contact form and later flipped back. Keys map
  # into CARDS positionally; cards inserted this way CARRY their key, while
  # the auto-appended tail predates keys and stays keyless — key_for below is
  # the one place that reads both generations.
  CORE_KEYS = { "age" => 0, "location" => 1, "gender" => 2 }.freeze

  # One core tail card, localised, tagged with its key. Same shape as
  # optional_card so the modal's insert endpoint can serve either.
  def self.core_card(key, locale: nil)
    idx = CORE_KEYS[key.to_s]
    return nil unless idx

    cards(locale: locale)[idx].merge("demographic_key" => key.to_s)
  end

  # The registry card behind any Demographics tile — opt-in or core.
  def self.card_for_key(key, locale: nil)
    optional_card(key, locale: locale) || core_card(key, locale: locale)
  end

  # The demographic identity of a card, across both generations: an explicit
  # demographic_key where one is stored, else inferred the way the answer sync
  # infers (PlayerController#sync_demographics_from_answers! matches birth by
  # input "month" and gender as the keyless demographic multiple_choice —
  # sync_region_from_answers! matches location by input). Nil for a card that
  # isn't a demographic question at all.
  def self.key_for(card)
    return nil unless card.is_a?(Hash) && card["demographic"]
    return card["demographic_key"].to_s if card["demographic_key"].to_s.strip.present?

    case
    when card["input"] == "month"            then "age"
    when card["input"] == "location"         then "location"
    when card["type"] == "multiple_choice"   then "gender"
    end
  end

  # ── Reading a demographic answer back ──────────────────────────────────────
  #
  # The month and location cards are open_ended, so their answers are stored
  # as strings — but they are STRUCTURED strings written by the player's own
  # widgets rather than sentences somebody typed: "1977-09" from the
  # month/year pair (player_controller.js pads the month), and
  # "CC|Region|Postcode" from the location picker, the last two segments
  # optional (PlayerController#sync_region_from_answers! parses the same
  # shape and is the definition of it).
  #
  # Rendered raw on the results page they read as storage rather than as
  # answers: "DE|" is a person who lives in Germany. So every surface that
  # shows one to a human goes through here — the result card's preview and
  # the "View all answers" panel alike, which is also what keeps the panel's
  # SEARCH honest: it filters what it displays, so typing "Germany" finds the
  # people in Germany rather than nothing.
  #
  # Anything this can't parse comes back unchanged. A value that doesn't fit
  # the shape is still an answer somebody gave, and hiding it behind a dash
  # would be worse than showing it as it was stored.
  def self.display_answer(card, value)
    text = value.to_s
    return text unless card.is_a?(Hash) && card["demographic"]

    # key_for rather than card["input"] directly, so this agrees with the
    # answer sync about what a card IS across both card generations — an
    # explicit demographic_key where one is stored, the input otherwise.
    case key_for(card)
    when "age"      then month_answer(text)
    when "location" then location_answer(text)
    else text
    end
  end

  # "1977-09" → "September 1977". English, like the rest of this page's own
  # chrome ("Card 3", "answers", the header's publish date) — localising this
  # one string and nothing around it would read as a bug rather than a
  # translation.
  def self.month_answer(text)
    m = text.match(/\A(\d{4})-(\d{1,2})\z/)
    return text unless m

    month = m[2].to_i
    return text unless month.between?(1, 12)

    "#{Date::MONTHNAMES[month]} #{m[1]}"
  end

  # "ES|Catalunya" → "Catalunya, Spain"; "DE|" → "Germany";
  # "GB|London|SW1A 1AA" → "London, United Kingdom · SW1A 1AA".
  #
  # An unknown country code falls through to the raw value rather than being
  # printed as a code: sync_region_from_answers! refuses those too, so the
  # response carries the answer without being region-tagged, and "XX" is not
  # a place.
  def self.location_answer(text)
    sep = text.index("|")
    return text unless sep

    code = text[0...sep].to_s.upcase
    return text unless WorldRegions.valid?(code)

    rest     = text[(sep + 1)..].to_s
    sep2     = rest.index("|")
    label    = (sep2 ? rest[0...sep2] : rest).strip
    postcode = sep2 ? rest[(sep2 + 1)..].to_s.strip : nil

    place = [ label.presence, WorldRegions.name_for(code) ].compact.join(", ")
    postcode.present? ? "#{place} · #{postcode}" : place
  end

  # Every key Survey.sanitize_cards_images! will accept. CORE_KEYS supplies
  # "gender" — the reservation the old comment promised — plus "age" and
  # "location" now that the tail trio is insertable from the modal.
  DEMOGRAPHIC_KEYS = (OPTIONAL_CARDS.keys + CORE_KEYS.keys).freeze

  # Registry entries the card no longer OFFERS. They stay in the list because
  # the list is the translated vocabulary, not the card:
  #
  #   · decks inserted before they were retired still carry them as real
  #     options, and their stored answers still have to validate;
  #   · one of them is still the label a typed answer is recorded as
  #     (OFF_LIST_OPTION_INDEX below);
  #   · neuro_exclusive_labels reads "None of these" positionally across every
  #     locale, and must keep recognising it for those older decks.
  #
  # Retired so far:
  #   heritage       7 "Another heritage"
  #   neurodiversity 6 "Another form of neurodivergence"
  #                    — both dead ends: a button recording that someone didn't
  #                      fit the list without ever asking what they are. The
  #                      free-text box (optional_card sets allow_other) asks.
  #   neurodiversity 7 "None of these"
  #                    — the card is a select-many asking "choose any that
  #                      apply", so ticking nothing already says none of them do.
  #
  # Pinned by INDEX, because the locale merge is positional and the parity test
  # compares translated lists to the registry by length. Reorder a list without
  # moving these and the registry guard in
  # test/models/demographic_questions_test.rb fails.
  RETIRED_OPTION_INDEXES = { "heritage" => [ 7 ], "neurodiversity" => [ 6, 7 ] }.freeze

  # Which retired entry a typed answer is recorded as — never the respondent's
  # own words, which would put respondent-authored text into the creator's
  # dashboard as a segment pill.
  OFF_LIST_OPTION_INDEX = { "heritage" => 7, "neurodiversity" => 6 }.freeze

  # One optional card resolved in `locale`, or nil for an unknown key. Deep
  # dup (options array included) — callers mutate the hash (cid stamping,
  # i18n prefill). Same translation posture as `cards`: text/description only
  # when present, options only whole and at registry length, English on an
  # invalid locale.
  #
  # What the card SHOWS is the registry vocabulary minus its off-list label,
  # plus the free-text box that replaced it — see OFF_LIST_OPTION_INDEX.
  def self.optional_card(key, locale: nil)
    spec = OPTIONAL_CARDS[key.to_s]
    return nil unless spec

    card = spec.dup
    card["options"] = shown_options(key, locale: locale)
    # A short list will always miss someone. The box is the difference between
    # a respondent being filed under "another" and being able to say what they
    # actually are.
    card["allow_other"] = true

    tr = I18n.t("demographics.optional.#{key}", locale: locale.presence || I18n.locale, default: nil)
    return card unless tr.is_a?(Hash)

    tr = tr.transform_keys(&:to_s)
    card["text"]        = tr["text"].to_s        if tr["text"].to_s.strip.present?
    card["description"] = tr["description"].to_s if tr["description"].to_s.strip.present?
    card
  rescue I18n::InvalidLocale
    card
  end

  # The FULL registry list for `key`, resolved in `locale` — the translated
  # vocabulary, off-list label included. This is the positional source of truth
  # every helper below reads; only optional_card narrows it to what a card
  # displays.
  #
  # A translated list is taken only whole and at registry length, because
  # answers are stored as positional canonical labels: a short list would
  # silently re-point every entry after the gap.
  def self.translated_options(key, locale: nil)
    spec = OPTIONAL_CARDS[key.to_s]
    return [] unless spec

    opts = I18n.t("demographics.optional.#{key}.options", locale: locale.presence || I18n.locale, default: nil)
    return opts.map(&:to_s) if opts.is_a?(Array) && opts.size == spec["options"].size

    spec["options"].dup
  rescue I18n::InvalidLocale
    spec["options"].dup
  end

  # The options a card actually offers: the vocabulary minus whatever has been
  # retired from it. A key with nothing retired shows the list whole.
  def self.shown_options(key, locale: nil)
    retired = RETIRED_OPTION_INDEXES[key.to_s] || []
    translated_options(key, locale: locale).reject.with_index { |_, i| retired.include?(i) }
  end

  # The label a typed answer on `key`'s card is recorded as — "Another
  # heritage", "Another form of neurodivergence" — in `locale`. Never shown to
  # a respondent; see OFF_LIST_OPTION_INDEX for why it still exists.
  def self.off_list_label(key, locale: nil)
    idx = OFF_LIST_OPTION_INDEX[key.to_s]
    idx && translated_options(key, locale: locale)[idx]
  end

  # "Prefer not to say" — the LAST entry of both registry lists. Declining is a
  # different answer from not fitting the list, so unlike the off-list label it
  # stays a real choice on every card.
  def self.decline_option(key, locale: nil)
    translated_options(key, locale: locale).last
  end

  # The two heritage labels a generated country list must never duplicate:
  # "Another heritage" and "Prefer not to say", in `locale`.
  #
  # Reads the VOCABULARY, not the card. Rebasing this onto optional_card would
  # return ["Mixed or multiple heritage", "Prefer not to say"] — so
  # HeritageOptions.sanitize would start rejecting a country's real "Mixed"
  # category (Brazil's largest) while no longer guarding against the label it
  # exists to guard against, silently and for months.
  def self.heritage_tail_options(locale: nil)
    [ off_list_label("heritage", locale: locale), decline_option("heritage", locale: locale) ].compact
  end

  # Kept as the readable name at the two heritage-specific call sites.
  def self.heritage_decline_option(locale: nil)
    decline_option("heritage", locale: locale)
  end

  # The heritage card with `five` country-specific categories in place of the
  # global nine — so the card asks about Kenyan or Brazilian heritage, while a
  # respondent who fits none of it, or would rather not say, still has
  # somewhere to go.
  #
  # Pure: `five` arrives already generated and sanitised (HeritageOptions), so
  # nothing here calls a service or can fail. A blank list returns the plain
  # registry card, which is what makes "Claude was unreachable" degrade to the
  # global taxonomy rather than to an error.
  #
  # Six options: the five categories plus "Prefer not to say". Anyone the five
  # miss types it into the box optional_card already switched on — the same
  # shape as the global card, just a shorter and more local list.
  def self.country_heritage_card(country:, five:, locale: nil)
    card = optional_card("heritage", locale: locale)
    return card if card.nil? || Array(five).empty?

    code = country.to_s.upcase
    return card unless WorldRegions.valid?(code)

    card["options"]          = Array(five).map(&:to_s) + [ heritage_decline_option(locale: locale) ]
    card["heritage_country"] = code
    card
  end

  # The neurodiversity card's two mutually-exclusive options ("None of these",
  # "Prefer not to say") in EVERY available locale. Stored answers are
  # canonical primary-language labels, so a French Verto stores the French
  # pair — the sync's exclusivity rule has to recognise them all. Identified
  # positionally as the LAST TWO registry options, mirroring optional_card's
  # whole-list-only translation guard.
  def self.neuro_exclusive_labels
    @neuro_exclusive_labels ||= begin
      size = OPTIONAL_CARDS["neurodiversity"]["options"].size
      labels = OPTIONAL_CARDS["neurodiversity"]["options"].last(2)
      I18n.available_locales.each do |loc|
        opts = I18n.t("demographics.optional.neurodiversity.options", locale: loc, default: nil)
        labels += opts.last(2).map(&:to_s) if opts.is_a?(Array) && opts.size == size
      end
      labels.to_set.freeze
    end
  end
end
