require "test_helper"

# The respondent account shipped English-only across three pushes, and the
# comment recording that decision (en.yml, above `player_sign_in`) was half
# wrong: it said the strings a respondent sees *inside* the player were
# translated everywhere. Only the five client-rendered `js.player.join_*` keys
# were. The seven SERVER-rendered `player.join_*` keys sat in en.yml alone, on
# the end screen of every join-enabled Verto.
#
# `config.i18n.fallbacks` means a gap here renders English rather than a raw
# dotted key, which is exactly why nothing caught it for three pushes: no test
# failed, no error was raised, and the only symptom was a French respondent
# reading English. LocaleStructureParityTest now covers these namespaces for
# key parity; this file covers the properties a key-set comparison cannot see.
class LocaleRespondentParityTest < ActiveSupport::TestCase
  LOCALES = Dir[Rails.root.join("config/locales/*.yml")]
              .map { |f| File.basename(f, ".yml") }.sort.freeze

  # Whole namespaces, plus the seven join keys, which live inside `player.*`
  # alongside 54 others that are not this feature's.
  # player_session is the password form a respondent comes back through. It
  # joined this list in the same commit that created it, rather than three
  # pushes later — which is the whole lesson of the note above.
  # The two player_email_confirmation namespaces joined in the commit that
  # created them, for the same reason.
  NAMESPACES = %w[you player_sign_in player_session player_sign_in_mailer
                  player_notification_mailer player_unsubscribe
                  player_email_confirmation player_email_confirmation_mailer].freeze
  JOIN_KEYS = %w[join_eyebrow join_title join_body join_cta
                 join_email_placeholder join_fine join_fine_confirm join_embedded].freeze

  # A floor, not an exact count — new copy should land without editing this
  # test. But every assertion below is a comparison against the English set, so
  # an empty or truncated one would make all of them pass vacuously. 98 keys
  # shipped; allow a little removal before this stops being a real guard.
  MINIMUM_KEYS = 90

  def tree_for(locale)
    root = I18n.backend.send(:translations)[locale.to_sym] || {}
    out  = {}
    NAMESPACES.each { |ns| leaves(root[ns.to_sym] || {}, [ ns ], out) }
    join = root.dig(:player) || {}
    JOIN_KEYS.each do |key|
      value = join[key.to_sym]
      out["player.#{key}"] = value unless value.nil?
    end
    out
  end

  # Every leaf as { "dot.path" => value }, where value is a String or, for a
  # pluralized entry, a Hash of CLDR category => String.
  def leaves(node, prefix = [], out = {})
    node.each do |key, value|
      path = prefix + [ key.to_s ]
      if value.is_a?(Hash) &&
         value.keys.map(&:to_s).any? { |k| LocaleProperties::CONSULTED_PLURAL_FORMS.include?(k) }
        out[path.join(".")] = value
      elsif value.is_a?(Hash)
        leaves(value, path, out)
      else
        out[path.join(".")] = value
      end
    end
    out
  end

  def texts(value)
    value.is_a?(Hash) ? value.values.map(&:to_s) : [ value.to_s ]
  end

  setup do
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    @en = tree_for("en")
  end

  test "the respondent namespaces exist and are substantially populated" do
    assert_operator @en.size, :>=, MINIMUM_KEYS,
                    "expected at least #{MINIMUM_KEYS} respondent-account keys in en.yml; found " \
                    "#{@en.size}. Every other test here compares against this set, so a truncated " \
                    "en.yml would make them all pass while proving nothing."
    JOIN_KEYS.each do |key|
      assert @en.key?("player.#{key}"),
             "player.#{key} is gone from en.yml — it is the server-rendered join block, and it " \
             "went untranslated for three pushes precisely because nothing looked for it."
    end
  end

  test "every locale has every key" do
    missing = {}
    LOCALES.each do |locale|
      next if locale == "en"

      gap = @en.keys - tree_for(locale).keys
      missing[locale] = gap if gap.any?
    end
    assert_empty missing,
                 "locales missing respondent keys. These fall back to English rather than " \
                 "raising, so the only symptom is a respondent reading the wrong language: #{missing}"
  end

  test "no locale has a key English does not" do
    extra = {}
    LOCALES.each do |locale|
      next if locale == "en"

      gap = tree_for(locale).keys - @en.keys
      extra[locale] = gap if gap.any?
    end
    assert_empty extra, "locales with unknown respondent keys: #{extra}"
  end

  test "placeholders match English exactly in every locale" do
    problems = []
    LOCALES.each do |locale|
      next if locale == "en"

      tree_for(locale).each do |key, value|
        expected = @en[key]
        next if expected.nil?

        want = LocaleProperties.placeholders(texts(expected).join(" "))
        got  = LocaleProperties.placeholders(texts(value).join(" "))
        next if want == got

        problems << "#{locale}/#{key}: expected #{want.to_a.sort.inspect}, got #{got.to_a.sort.inspect}"
      end
    end
    assert_empty problems,
                 "placeholder mismatches raise I18n::MissingInterpolationArgument at render time, " \
                 "in that locale only:\n" + problems.join("\n")
  end

  # `you.wallet_across` is "Across %{vertos} and %{organisations}." — a
  # British-spelled interpolation NAME, and the key EnglishSpellings::PLACEHOLDER
  # exists because of. A translator, or a generator, that "corrects" it to
  # %{organizations} takes the wallet down in that language alone. The test
  # above would catch it; this one says why out loud, at the one key where the
  # mistake is inviting.
  test "the British-spelled interpolation name survives everywhere" do
    problems = LOCALES.reject { |locale| @en["you.wallet_across"].nil? }.filter_map do |locale|
      value = tree_for(locale)["you.wallet_across"]
      next if value.nil?

      "#{locale}: #{value.inspect}" unless value.to_s.include?("%{organisations}")
    end
    assert_empty problems,
                 "%{organisations} is a keyword argument the view passes, not prose. " \
                 "Respelling it is a 500 in that locale:\n" + problems.join("\n")
  end

  # `pluralization_key` in I18n::Backend::Simple consults `one` and `other`
  # (and `zero`, only at count 0). There is no rails-i18n gem and no
  # Pluralization backend here, so `few`/`many`/`two` would never be read and a
  # locale-specific `zero` would change rendering at count 0 in that language
  # and nowhere else. Mirror en.yml — see LocaleProperties.
  test "pluralized entries mirror en.yml's categories exactly" do
    plural_keys = @en.select { |_k, v| v.is_a?(Hash) }.keys
    refute_empty plural_keys, "expected pluralized respondent keys (you.kept and friends)"

    problems = []
    LOCALES.each do |locale|
      tree = tree_for(locale)
      plural_keys.each do |key|
        value = tree[key]
        next if value.nil?

        unless value.is_a?(Hash)
          problems << "#{locale}/#{key}: bare string where plural categories are required"
          next
        end

        forms = value.keys.map(&:to_s).sort
        next if forms == LocaleProperties::DEFAULT_PLURAL_FORMS.sort

        problems << "#{locale}/#{key}: has #{forms.inspect}, " \
                    "expected #{LocaleProperties::DEFAULT_PLURAL_FORMS.sort.inspect}"
      end
    end
    assert_empty problems, "plural form problems:\n" + problems.join("\n")
  end

  test "every pluralized form interpolates the counts English interpolates" do
    problems = []
    LOCALES.each do |locale|
      tree_for(locale).each do |key, value|
        next unless value.is_a?(Hash) && @en[key].is_a?(Hash)

        @en[key].each do |form, english|
          next unless english.to_s.include?("%{count}")

          theirs = value[form] || value[form.to_s] || value[form.to_sym]
          problems << "#{locale}/#{key}.#{form}: no %{count}" unless theirs.to_s.include?("%{count}")
        end
      end
    end
    assert_empty problems, problems.join("\n")
  end

  test "no non-English locale left the English text verbatim" do
    suspicious = []
    LOCALES.each do |locale|
      next if SupportedLocales.english?(locale)

      tree_for(locale).each do |key, value|
        english = @en[key]
        next unless english.is_a?(String) && value.is_a?(String)
        next if english.length < LocaleProperties::VERBATIM_MIN_LENGTH

        suspicious << "#{locale}/#{key}" if english == value
      end
    end
    assert_empty suspicious,
                 "identical to the English source, so probably untranslated: #{suspicious}"
  end

  test "non-Latin locales are written in their own script" do
    problems = []
    LocaleProperties::SCRIPTS.each do |locale, script|
      next unless LOCALES.include?(locale)

      tree_for(locale).each do |key, value|
        texts(value).each do |text|
          next if LocaleProperties.bare_prose(text).length < 10 || text.match?(script)

          problems << "#{locale}/#{key}: no #{locale} script in #{text.first(60).inspect}"
        end
      end
    end
    assert_empty problems,
                 "these read as transliteration or untranslated source:\n" + problems.join("\n")
  end

  test "the product name is never translated" do
    problems = []
    LOCALES.each do |locale|
      next if locale == "en"

      tree = tree_for(locale)
      @en.each do |key, english|
        next unless english.is_a?(String) && english.include?("Verto")

        value = tree[key]
        next unless value.is_a?(String)

        problems << "#{locale}/#{key}: lost the product name" unless value.include?("Verto")
      end
    end
    assert_empty problems, problems.join("\n")
  end

  # The other half of the contract, and the half that failed here: that the
  # keys English defines are the keys the code asks for. Scoped to the seven
  # join keys — `player.*` is 61 keys, a curated slice of which is reached from
  # JS via _i18n_js.html.erb rather than a `t(` call, so "defined but never
  # called" would be false across the namespace as a whole.
  SOURCE_DIRS = %w[app/controllers app/models app/views app/helpers app/mailers].freeze

  test "every server-rendered join key is actually called" do
    source = Dir[*SOURCE_DIRS.map { |d| Rails.root.join(d, "**/*.{rb,erb}").to_s }]
               .map { |f| File.read(f) }.join("\n")

    uncalled = JOIN_KEYS.reject { |key| source.include?("player.#{key}") }
    assert_empty uncalled,
                 "defined but never called — dead copy carried in all #{LOCALES.size} locale " \
                 "files: #{uncalled.inspect}"
  end
end
