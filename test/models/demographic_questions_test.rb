require "test_helper"

class DemographicQuestionsTest < ActiveSupport::TestCase
  test "the age card is a vertical band slider, and stores no date of birth" do
    card = DemographicQuestions.cards.first

    assert_equal "range", card["type"]
    assert_equal "vertical", card["slider_axis"]
    assert_equal DemographicQuestions::AGE_BAND_LABELS, card["options"]
    assert card["demographic"]

    # The point of the card: a band, never a date. "month" was the input that
    # packed "YYYY-MM" into the answer for every respondent of every Verto.
    refute_equal "month", card["input"]
    assert_equal "age", DemographicQuestions.key_for(card)
  end

  test "the age bands carry the thresholds the law draws" do
    keys = DemographicQuestions::AGE_BAND_KEYS
    assert_equal %w[under_16 16_17 18_24 25_34 35_49 50_64 65_plus], keys

    # 16 (EU Article 8 default) and 18 (child/adult, and India's DPDP) are the
    # two boundaries anything downstream gates on, so they must be band edges
    # rather than values that fall inside one.
    assert_equal "under_16", DemographicQuestions.age_band_key_for_age(15)
    assert_equal "16_17",    DemographicQuestions.age_band_key_for_age(16)
    assert_equal "16_17",    DemographicQuestions.age_band_key_for_age(17)
    assert_equal "18_24",    DemographicQuestions.age_band_key_for_age(18)
  end

  test "the age slider keeps all seven bands through range normalisation" do
    # Survey.normalize_range_cards! resizes every range card to RANGE_POINTS
    # (5), sampling evenly when there are more. Run over the age card that
    # would drop two bands — including "16–17", the boundary the account gate
    # reads — so the exemption is pinned rather than incidental.
    card = DemographicQuestions.cards.first
    kept = Survey.normalize_range_cards!([ card ]).first

    assert_equal DemographicQuestions::AGE_BAND_LABELS, kept["options"]
    assert_equal 7, kept["options"].size

    # An ordinary range card is still resized, so the exemption is narrow.
    ordinary = { "type" => "range", "options" => DemographicQuestions::AGE_BAND_LABELS.dup }
    assert_equal Survey::RANGE_POINTS,
                 Survey.normalize_range_cards!([ ordinary ]).first["options"].size
  end

  test "a range index resolves to a band key, and a bad one to nothing" do
    assert_equal "under_16", DemographicQuestions.age_band_key_at(0)
    assert_equal "65_plus",  DemographicQuestions.age_band_key_at(6)
    assert_equal "65_plus",  DemographicQuestions.age_band_key_at("6")

    # A tampered payload, or a deck whose options were edited, records nothing
    # rather than guessing a band.
    assert_nil DemographicQuestions.age_band_key_at(7)
    assert_nil DemographicQuestions.age_band_key_at(-1)
    assert_nil DemographicQuestions.age_band_key_at("banana")
    assert_nil DemographicQuestions.age_band_key_at(nil)
  end

  test "append_to adds the demographic tail once and never duplicates it" do
    cards = [ { "type" => "welcome_card", "text" => "Welcome" } ]
    once  = DemographicQuestions.append_to(cards)
    assert_equal 4, once.size

    twice = DemographicQuestions.append_to(once)
    assert_equal once, twice
  end

  # ── Opt-in questions (OPTIONAL_CARDS) ───────────────────────────────────────

  test "optional_card returns a keyed, flagged card and nil for unknown keys" do
    card = DemographicQuestions.optional_card("heritage")

    assert card["demographic"]
    assert_equal "heritage", card["demographic_key"]
    assert_equal "multiple_choice", card["type"]
    assert_equal 8, card["options"].size, "the vocabulary is 9; the off-list label is not shown"
    assert card["allow_other"], "which is only fair because the free-text box replaced it"
    assert_nil DemographicQuestions.optional_card("astrology")
  end

  test "optional_card resolves a locale and falls back to English" do
    fr = DemographicQuestions.optional_card("neurodiversity", locale: "fr")
    en = DemographicQuestions.optional_card("neurodiversity")

    refute_equal en["text"], fr["text"], "the French Verto must ask in French"
    assert_equal 7, fr["options"].size, "9 vocabulary entries, two retired"
    assert_equal en, DemographicQuestions.optional_card("neurodiversity", locale: "xx-nope")
  end

  test "a wrong-length translated options list is refused — answers are positional" do
    I18n.backend.store_translations(:en, demographics: { optional: { heritage: { options: %w[a b] } } })
    card = DemographicQuestions.optional_card("heritage")

    assert_equal DemographicQuestions.shown_options("heritage").size, card["options"].size
  ensure
    I18n.backend.reload!
  end

  test "optional_card deep-dups — callers can mutate without corrupting the registry" do
    card = DemographicQuestions.optional_card("heritage")
    card["options"] << "tampered"
    card["cid"] = "c_x"

    assert_equal 8, DemographicQuestions.optional_card("heritage")["options"].size
    refute DemographicQuestions::OPTIONAL_CARDS["heritage"].key?("cid")
  end

  test "neuro_exclusive_labels carries the exclusive pair across locales" do
    labels = DemographicQuestions.neuro_exclusive_labels

    assert_includes labels, "None of these"
    assert_includes labels, "Prefer not to say"
    assert_includes labels, "Aucune de ces réponses", "French exclusives must be recognised too"
    refute_includes labels, "ADHD", "a real condition must never be treated as exclusive"
  end

  # ── The country-tailored heritage card ────────────────────────────────────

  # The pin that everything else rests on. OFF_LIST_OPTION_INDEX names a
  # POSITION in each registry list; move an entry without moving the index and
  # a typed answer starts being filed under a real category instead. Nothing
  # else would raise, so this is the alarm.
  test "the retired indexes point at the labels they claim, on both cards" do
    {
      "heritage"       => { 7 => "Another heritage" },
      "neurodiversity" => { 6 => "Another form of neurodivergence", 7 => "None of these" }
    }.each do |key, expected|
      assert_equal expected.keys, DemographicQuestions::RETIRED_OPTION_INDEXES[key],
                   "#{key}: retired list has drifted"
      expected.each do |idx, label|
        assert_equal label, DemographicQuestions::OPTIONAL_CARDS[key]["options"][idx],
                     "#{key}[#{idx}]: RETIRED_OPTION_INDEXES has drifted from the registry list"
        assert_includes DemographicQuestions.translated_options(key), label,
                        "retired entries stay in the vocabulary — older decks still offer them"
        refute_includes DemographicQuestions.shown_options(key), label,
                        "but a new card never offers them"
      end
    end
  end

  test "the off-list label is one of the retired entries, and is recorded not shown" do
    { "heritage" => "Another heritage",
      "neurodiversity" => "Another form of neurodivergence" }.each do |key, label|
      idx = DemographicQuestions::OFF_LIST_OPTION_INDEX[key]
      assert_includes DemographicQuestions::RETIRED_OPTION_INDEXES[key], idx,
                      "#{key}: a label that is still shown cannot also be the typed-answer label"
      assert_equal label, DemographicQuestions.off_list_label(key)
    end
  end

  test "both cards drop their dead ends and take the free-text box instead" do
    {
      "heritage" => 8,        # 9 vocabulary entries, "Another heritage" retired
      "neurodiversity" => 7   # …plus "None of these": ticking nothing already says it
    }.each do |key, shown|
      card = DemographicQuestions.optional_card(key)
      assert_equal shown, card["options"].size
      assert card["allow_other"], "#{key}: nowhere to say 'not on your list' otherwise"
      assert_equal DemographicQuestions.decline_option(key), card["options"].last,
                   "#{key}: declining stays a real choice"
    end
  end

  # The exclusivity rule outlives the option: decks inserted before it was
  # retired still offer "None of these", and their answers still have to sort.
  test "neuro_exclusive_labels still recognises the retired 'None of these'" do
    refute_includes DemographicQuestions.shown_options("neurodiversity"), "None of these"
    assert_includes DemographicQuestions.neuro_exclusive_labels, "None of these"
    assert_includes DemographicQuestions.neuro_exclusive_labels, "Aucune de ces réponses"
  end

  test "the off-list and decline labels resolve per locale and stay distinct" do
    fr_off     = DemographicQuestions.off_list_label("heritage", locale: "fr")
    fr_decline = DemographicQuestions.decline_option("heritage", locale: "fr")

    assert_equal "Autre héritage", fr_off, "a French Verto records the French label"
    refute_equal fr_off, fr_decline
    refute_equal DemographicQuestions.off_list_label("heritage"), fr_off
  end

  # The regression this rebase exists to prevent: read off the CARD instead of
  # the vocabulary and this returns ["Mixed or multiple heritage", ...], so
  # HeritageOptions.sanitize starts rejecting a country's real "Mixed" category.
  test "heritage_tail_options reads the vocabulary, not the card" do
    assert_equal [ "Another heritage", "Prefer not to say" ],
                 DemographicQuestions.heritage_tail_options
    refute_includes DemographicQuestions.heritage_tail_options, "Mixed or multiple heritage"
    assert_equal "Prefer not to say", DemographicQuestions.heritage_decline_option
  end

  test "country_heritage_card swaps the taxonomy and keeps declining a choice" do
    five = [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ]
    card = DemographicQuestions.country_heritage_card(country: "gb", five: five)

    assert_equal five + [ DemographicQuestions.heritage_decline_option ], card["options"]
    assert_equal 6, card["options"].size
    assert card["allow_other"], "five categories will miss people"
    assert_equal "GB", card["heritage_country"], "the code is normalised, not echoed"
    assert_equal "heritage", card["demographic_key"], "it is still the same question"
    assert card["demographic"]
  end

  test "a tailored card offers no 'Another heritage' button — you type it instead" do
    card = DemographicQuestions.country_heritage_card(
      country: "GB", five: %w[a b c d e]
    )

    refute_includes card["options"], DemographicQuestions.off_list_label("heritage"),
                    "a radio reading 'Another heritage' records that someone didn't fit " \
                    "without ever asking what they are; the Other box asks"
    assert card["allow_other"], "which only works because the free-text box is there"
    assert_equal DemographicQuestions.heritage_decline_option, card["options"].last,
                 "declining is a different answer from not fitting, so it stays a choice"
  end

  test "a French Verto's tailored card carries the French question and decline option" do
    card = DemographicQuestions.country_heritage_card(
      country: "FR", five: %w[un deux trois quatre cinq], locale: "fr"
    )

    assert_equal DemographicQuestions.optional_card("heritage", locale: "fr")["text"], card["text"]
    assert_equal DemographicQuestions.heritage_decline_option(locale: "fr"), card["options"].last
    refute_includes card["options"], DemographicQuestions.off_list_label("heritage", locale: "fr")
  end

  test "no usable list means the plain registry card, never a half-tailored one" do
    [ nil, [] ].each do |five|
      card = DemographicQuestions.country_heritage_card(country: "GB", five: five)
      assert_equal 8, card["options"].size
      assert_nil card["heritage_country"], "a fallback must not claim a tailoring it didn't get"
    end

    unknown = DemographicQuestions.country_heritage_card(country: "ZZ", five: %w[a b c d e])
    assert_equal 8, unknown["options"].size
    assert_nil unknown["heritage_country"]
  end

  test "building a tailored card never corrupts the frozen registry" do
    DemographicQuestions.country_heritage_card(country: "GB", five: %w[a b c d e])

    assert_equal 9, DemographicQuestions::OPTIONAL_CARDS["heritage"]["options"].size
    refute DemographicQuestions::OPTIONAL_CARDS["heritage"].key?("allow_other")
    refute DemographicQuestions::OPTIONAL_CARDS["heritage"].key?("heritage_country")
  end

  test "the optional questions never leak into the auto-appended tail" do
    assert_equal 3, DemographicQuestions.cards.size
    assert_equal 3, DemographicQuestions.append_to([]).size
    assert(DemographicQuestions.append_to([]).none? { |c| c.key?("demographic_key") })
  end

  # ── display_answer ─────────────────────────────────────────────────────────
  #
  # The results page shows these to a person, and what is stored is a widget's
  # output: "1977-09", "CC|Region|Postcode". The edges below are the ones real
  # data has — a country picked with no region, a postcode segment the older
  # answers do not carry, and the malformed values that any free-typed column
  # eventually collects.
  #
  # The rule throughout: anything unparseable comes back UNCHANGED. It is
  # still an answer somebody gave.

  def month_card = { "type" => "open_ended", "input" => "month", "demographic" => true }
  def place_card = { "type" => "open_ended", "input" => "location", "demographic" => true }

  test "a birth month reads as a month and a year" do
    assert_equal "September 1977", DemographicQuestions.display_answer(month_card, "1977-09")
    assert_equal "January 2001",   DemographicQuestions.display_answer(month_card, "2001-01")
    # The player pads, but an import need not have.
    assert_equal "March 1984", DemographicQuestions.display_answer(month_card, "1984-3")
  end

  test "a birth month that is not one is left exactly as it was stored" do
    [ "sometime in 1977", "1977", "1977-13", "1977-00", "", "1977-09-04" ].each do |raw|
      assert_equal raw, DemographicQuestions.display_answer(month_card, raw),
        "#{raw.inspect} was rewritten instead of being shown as given"
    end
  end

  test "a location reads as a place" do
    assert_equal "Catalunya, Spain", DemographicQuestions.display_answer(place_card, "ES|Catalunya")
    assert_equal "Greater London, England, United Kingdom · SW1A 1AA",
                 DemographicQuestions.display_answer(place_card, "GB|Greater London, England|SW1A 1AA")
  end

  # The region is optional in the picker, and "DE|" is the commonest shape
  # after the full one — a respondent who named a country and no more.
  test "a country with no region is just the country" do
    assert_equal "Germany", DemographicQuestions.display_answer(place_card, "DE|")
    assert_equal "Nepal",   DemographicQuestions.display_answer(place_card, "NP|")
    assert_equal "Germany", DemographicQuestions.display_answer(place_card, "DE|   ")
  end

  # sync_region_from_answers! refuses an unknown code too — the response keeps
  # the answer without being region-tagged. "XX" is not a place, so it is not
  # printed as one.
  test "an unknown or missing country code is left as it was stored" do
    assert_equal "XX|Somewhere", DemographicQuestions.display_answer(place_card, "XX|Somewhere")
    assert_equal "just a place",  DemographicQuestions.display_answer(place_card, "just a place")
    assert_equal "",              DemographicQuestions.display_answer(place_card, "")
  end

  test "every other card's answer passes straight through" do
    plain = { "type" => "open_ended", "text" => "Why did you come?" }
    assert_equal "ES|Catalunya", DemographicQuestions.display_answer(plain, "ES|Catalunya")
    assert_equal "1977-09",      DemographicQuestions.display_answer(plain, "1977-09")
    assert_equal "1977-09",      DemographicQuestions.display_answer(nil, "1977-09")

    # A demographic card that is neither of these two — the gender pick.
    gender = { "type" => "multiple_choice", "demographic" => true }
    assert_equal "Female", DemographicQuestions.display_answer(gender, "Female")
  end

  # The card's "View all answers (N)" is counted by the aggregator from the
  # RAW values; the panel's "of N" is counted from these formatted ones. If a
  # non-blank answer could format to blank the two would disagree, and the
  # panel would quietly be short.
  test "nothing non-blank ever formats to blank" do
    [ month_card, place_card ].each do |card|
      [ "1977-09", "DE|", "|", "ES|", "x", "0", "GB||" ].each do |raw|
        assert_predicate DemographicQuestions.display_answer(card, raw).strip, :present?,
          "#{raw.inspect} formatted to nothing — the card would count it and the panel would not"
      end
    end
  end
end
