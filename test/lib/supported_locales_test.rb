require "test_helper"

class SupportedLocalesTest < ActiveSupport::TestCase
  SOUTHERN_AFRICA = %w[af zu xh st tn sn].freeze

  test "the southern Africa batch is registered in the full locale list" do
    SOUTHERN_AFRICA.each do |code|
      assert SupportedLocales.supported?(code), "#{code} should be a known locale"
      loc = SupportedLocales.find(code)
      assert loc.native_name.present?, "#{code} needs a native_name"
      assert loc.english_name.present?, "#{code} needs an english_name"
      assert_equal "ltr", loc.dir, "#{code} is left-to-right"
    end
  end

  # The picker only shows a locale once its UI translation covers enough of
  # en.yml to not read as mostly-English — see SupportedLocales::COVERAGE_THRESHOLD.
  # This is the actual acceptance bar for "the batch shipped", not just "the
  # files exist": a locale.yml that parses but is 20% translated would pass
  # the structural parity test (which only checks a curated namespace slice)
  # while still failing this, which checks coverage against ALL of en.yml.
  test "each southern Africa locale is translated enough to appear in the picker" do
    ready = SupportedLocales.ui_ready.map(&:code)
    SOUTHERN_AFRICA.each do |code|
      assert_includes ready, code,
        "#{code}.yml exists but doesn't cover enough of en.yml's keys yet (80% threshold)"
    end
  end

  test "Verto content-language pickers (SupportedLocales.all) include the batch even independent of UI coverage" do
    SOUTHERN_AFRICA.each { |code| assert_includes SupportedLocales.codes, code }
  end

  # Czech shipped with a full cs.yml rather than as a registry-only entry like
  # `zh`, so it belongs in the platform switcher as well as the content
  # pickers — the same acceptance bar as the batch above.
  test "Czech is registered and translated enough to appear in the picker" do
    loc = SupportedLocales.find("cs")
    assert loc, "cs is not in config/supported_locales.yml"
    assert_equal "Czech", loc.english_name
    assert_equal "Čeština", loc.native_name
    assert_equal "ltr", loc.dir
    assert_includes SupportedLocales.ui_ready.map(&:code), "cs",
      "cs.yml exists but doesn't cover enough of en.yml's keys yet (80% threshold)"
    assert_equal "cs", SupportedLocales.coerce_tag("cs-CZ"),
      "a Czech browser sends cs-CZ and must land on the bare language subtag"
  end
end
