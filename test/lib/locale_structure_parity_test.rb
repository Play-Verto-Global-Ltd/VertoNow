require "test_helper"

# The 25 locale files are documented as mirroring en.yml's structure, but
# nothing enforced it — which is how the `welcome_mailer` and new `js.*`
# namespaces could drift (a review finding). A key missing from one locale
# doesn't raise; it silently falls back to English (or renders a raw dotted
# key from JS), so the only reliable guard is structural.
#
# Scoped to the namespaces the browser depends on — `js` (window.I18N),
# `defaults` (placeholder card content, resolved per Verto locale) and `card`
# (curated into window.I18N by _i18n_js) — plus `ask`, whose 45 server-rendered
# strings were complete in every locale file only by discipline until they were
# guarded here. A hole in any of these is user-visible English in a
# non-English UI, the exact defect this pass removed.
#
# The five respondent-account namespaces joined the list once their backfill
# landed (98 keys × 24 locales). They are the same class of defect seen from
# the other side: everything a respondent reads after finishing a Verto, on a
# page and in an inbox where nobody on the team is looking. The seven
# server-rendered `player.join_*` keys are guarded by
# LocaleRespondentParityTest instead — `player` as a whole is 61 keys, and not
# all of them are this feature's.
#
# `language_check` joined on the same terms (80 keys × 24 locales, backfilled
# with the namespace). It has the strongest claim of any of them: the Language
# check screen is handed to people OUTSIDE the account through a share link,
# who have never seen this product, and half of them are there precisely
# because they do not read English. A hole in this namespace shows a French
# reviewer an English button — on the one page whose entire subject is whether
# the words are right in their language.
#
# Widening this to EVERY namespace is still desirable and still needs the
# remaining backfill first: `editor.*` carries a handful of keys missing from
# 18-24 locales, left by other work.
class LocaleStructureParityTest < ActiveSupport::TestCase
  NAMESPACES = %w[js defaults card templates demographics ask unsubscribe
                  you player_join player_sign_in player_session
                  player_sign_in_mailer
                  player_notification_mailer player_unsubscribe
                  player_email_confirmation player_email_confirmation_mailer
                  language_check].freeze

  def locale_files
    Dir[Rails.root.join("config/locales/*.yml")]
  end

  def load_locale(path)
    data = YAML.load_file(path)
    [ data.keys.first, data.values.first ]
  end

  def deep_keys(node, prefix = nil)
    return [ prefix ] unless node.is_a?(Hash)
    node.flat_map { |k, v| deep_keys(v, prefix ? "#{prefix}.#{k}" : k.to_s) }
  end

  test "every locale mirrors en.yml's browser-facing namespaces" do
    en = load_locale(Rails.root.join("config/locales/en.yml").to_s).last
    en_keys = NAMESPACES.index_with { |ns| deep_keys(en[ns], ns).sort }

    problems = []
    locale_files.each do |path|
      code, data = load_locale(path)
      next if code == "en"

      NAMESPACES.each do |ns|
        missing = en_keys[ns] - deep_keys(data[ns], ns)
        extra   = deep_keys(data[ns], ns) - en_keys[ns]
        problems << "#{File.basename(path)}: missing #{missing.take(8).inspect}#{"…" if missing.size > 8}" if missing.any?
        problems << "#{File.basename(path)}: extra #{extra.take(8).inspect}#{"…" if extra.size > 8}" if extra.any?
      end
    end

    assert_empty problems,
                 "locale files out of step with en.yml — a missing key here renders as " \
                 "English (or a raw dotted key) in that language:\n  #{problems.join("\n  ")}"
  end

  # The defaults lists are POSITIONAL content (a range scale's stop 3 must stay
  # stop 3 in every language), so same keys isn't enough — same shape is the
  # contract.
  test "every locale's defaults lists match en.yml's lengths" do
    en = load_locale(Rails.root.join("config/locales/en.yml").to_s).last["defaults"]
    assert en.is_a?(Hash), "en.yml lost its defaults: namespace"

    problems = []
    locale_files.each do |path|
      code, data = load_locale(path)
      next if code == "en"
      d = data["defaults"]
      next unless d.is_a?(Hash) # the key-parity test above reports the hole

      en.each do |type, list|
        theirs = d[type]
        unless theirs.is_a?(Array) && theirs.size == list.size
          problems << "#{File.basename(path)}: defaults.#{type} is #{theirs.class}/#{theirs.respond_to?(:size) ? theirs.size : '-'}, en has #{list.size}"
        end
      end
    end

    assert_empty problems, "positional defaults out of shape:\n  #{problems.join("\n  ")}"
  end

  # en.yml's template/demographic content mirrors the Ruby registries
  # (SurveyTemplates::ALL, DemographicQuestions::CARDS) — the registries are
  # canonical, the locale entry is what actually renders, and nothing else
  # ties them together. Text equality, not just shape: an edit to one that
  # skips the other silently forks the English copy.
  test "en.yml's template content mirrors the SurveyTemplates registry" do
    en = load_locale(Rails.root.join("config/locales/en.yml").to_s).last

    SurveyTemplates.all.each do |tpl|
      entry = en.dig("templates", tpl[:id])
      assert entry, "en.yml has no templates.#{tpl[:id]} entry"
      assert_equal tpl[:name],    entry["name"],    "templates.#{tpl[:id]}.name"
      assert_equal tpl[:tagline], entry["tagline"], "templates.#{tpl[:id]}.tagline"

      cards = entry["cards"]
      assert_equal tpl[:cards].size, Array(cards).size, "templates.#{tpl[:id]}.cards count"
      tpl[:cards].each_with_index do |card, i|
        assert_equal card["text"], cards[i]["text"], "templates.#{tpl[:id]}.cards[#{i}].text"
        if cards[i].key?("options")
          assert_equal card["options"], cards[i]["options"], "templates.#{tpl[:id]}.cards[#{i}].options"
        end
      end
    end

    demo = en.dig("demographics", "cards")
    assert_equal DemographicQuestions::CARDS.size, Array(demo).size
    DemographicQuestions::CARDS.each_with_index do |card, i|
      assert_equal card["text"], demo[i]["text"], "demographics.cards[#{i}].text"
      assert_equal card["options"], demo[i]["options"], "demographics.cards[#{i}].options" if demo[i].key?("options")
    end

    # The opt-in questions mirror their registry the same way — map-shaped by
    # demographic_key rather than positional.
    DemographicQuestions::OPTIONAL_CARDS.each do |key, card|
      entry = en.dig("demographics", "optional", key)
      assert entry, "en.yml has no demographics.optional.#{key} entry"
      assert_equal card["text"], entry["text"], "demographics.optional.#{key}.text"
      assert_equal card["description"], entry["description"], "demographics.optional.#{key}.description"
      assert_equal card["options"], entry["options"], "demographics.optional.#{key}.options"
    end
  end

  # Template/demographic card lists are POSITIONAL content in every language:
  # card i must stay card i, and a translated options list must keep the
  # English length — the merge in cards_for/DemographicQuestions.cards refuses
  # a wrong-length list (falling back to English), so a shape hole here means
  # a half-translated deck, not a crash. Surface it at build time instead.
  test "every locale's template and demographic card lists keep en's shape" do
    problems = []
    locale_files.each do |path|
      code, data = load_locale(path)
      next if code == "en"

      SurveyTemplates.all.each do |tpl|
        cards = data.dig("templates", tpl[:id], "cards")
        unless cards.is_a?(Array) && cards.size == tpl[:cards].size
          problems << "#{code}: templates.#{tpl[:id]}.cards count #{cards.is_a?(Array) ? cards.size : 'missing'} != #{tpl[:cards].size}"
          next
        end
        tpl[:cards].each_with_index do |card, i|
          en_opts = card["options"]
          next unless en_opts.is_a?(Array) && en_opts.any? { |o| o.to_s =~ /[a-z]/i } # numeral scales aren't translated
          theirs = cards[i].is_a?(Hash) ? cards[i]["options"] : nil
          unless theirs.is_a?(Array) && theirs.size == en_opts.size
            problems << "#{code}: templates.#{tpl[:id]}.cards[#{i}].options #{theirs.is_a?(Array) ? theirs.size : 'missing'} != #{en_opts.size}"
          end
        end
      end

      demo = data.dig("demographics", "cards")
      unless demo.is_a?(Array) && demo.size == DemographicQuestions::CARDS.size
        problems << "#{code}: demographics.cards count #{demo.is_a?(Array) ? demo.size : 'missing'}"
        next
      end
      DemographicQuestions::CARDS.each_with_index do |card, i|
        next unless card["options"].is_a?(Array)
        theirs = demo[i].is_a?(Hash) ? demo[i]["options"] : nil
        unless theirs.is_a?(Array) && theirs.size == card["options"].size
          problems << "#{code}: demographics.cards[#{i}].options #{theirs.is_a?(Array) ? theirs.size : 'missing'} != #{card['options'].size}"
        end
      end

      # Opt-in questions: options must keep the registry length in every
      # language — DemographicQuestions.optional_card refuses a wrong-length
      # list (English fallback), and neuro_exclusive_labels reads the LAST TWO
      # positionally, so a short list would silently break exclusivity too.
      DemographicQuestions::OPTIONAL_CARDS.each do |key, card|
        theirs = data.dig("demographics", "optional", key, "options")
        unless theirs.is_a?(Array) && theirs.size == card["options"].size
          problems << "#{code}: demographics.optional.#{key}.options #{theirs.is_a?(Array) ? theirs.size : 'missing'} != #{card['options'].size}"
        end
      end
    end

    assert_empty problems, "positional template content out of shape:\n  #{problems.join("\n  ")}"
  end
end
