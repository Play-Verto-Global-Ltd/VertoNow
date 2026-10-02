require "test_helper"

# What the creation / import translation pass does with what it could not
# finish. It used to write an error report and stop, leaving a language whose
# cards were English until somebody noticed — now TranslateLocalesJob is asked
# for exactly the languages still missing words.
class VertoGenerationFollowUpTest < ActiveJob::TestCase
  def setup
    @org = Organisation.create!(name: "G", slug: "g-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: %w[en es fr],
      cards: [ { "type" => "open_ended", "cid" => "c1", "text" => "Why?" } ]
    )
  end

  def translator(failing: [])
    fake = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, **|
      raise "boom" if failing.include?(target_locale.to_s)
      cards.map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => [] } }
    end
    fake
  end

  test "a language whose call failed is handed to the job" do
    fake = translator(failing: [ "fr" ])
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { fake }) do
      assert_enqueued_with(job: TranslateLocalesJob, args: [ @survey.id, [ "fr" ] ]) do
        VertoGeneration.translate_survey!(@survey)
      end
    end
    assert_equal "es:Why?", @survey.reload.cards.first.dig("i18n", "es", "text")
  end

  test "a pass the deck moved under is handed to the job whole" do
    fake = translator
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { fake }) do
      assert_enqueued_jobs 2, only: TranslateLocalesJob do
        VertoGeneration.translate_survey!(@survey, if_unchanged: "a-digest-the-deck-no-longer-has")
      end
    end
  end

  test "a finished pass asks for nothing" do
    fake = translator
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { fake }) do
      assert_no_enqueued_jobs(only: TranslateLocalesJob) { VertoGeneration.translate_survey!(@survey) }
    end
  end
end
