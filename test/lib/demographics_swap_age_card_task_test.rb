require "test_helper"
require "rake"

# The one-off swap of a live Verto's retired birth-date card for the age-band
# slider. What matters is what it does NOT touch: card positions and stored
# answers, which are keyed by index and would re-point if anything moved.
class DemographicsSwapAgeCardTaskTest < ActiveSupport::TestCase
  MONTH_CARD = { "type" => "open_ended", "input" => "month", "text" => "When were you born?",
                 "demographic" => true, "cid" => "c_birth1" }.freeze

  def setup
    unless Rake::Task.task_defined?("demographics:swap_age_card")
      Rake::Task.define_task(:environment)
      load Rails.root.join("lib/tasks/demographics.rake")
    end
    @task = Rake::Task["demographics:swap_age_card"]

    @org    = Organisation.create!(name: "O", slug: "swap-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                                   default_locale: "en", locales: [ "en", "fr" ], cards: [])
    @cards = [
      { "type" => "multiple_choice", "text" => "Q1", "options" => [ "A", "B" ], "cid" => "c_q1" },
      MONTH_CARD.dup,
      { "type" => "open_ended", "input" => "location", "text" => "Where do you live?", "demographic" => true, "cid" => "c_loc" },
      { "type" => "multiple_choice", "text" => "What gender best describes you?",
        "options" => [ "Male", "Female", "Non-binary", "Other", "Prefer not to say" ], "demographic" => true, "cid" => "c_g" }
    ]
    @survey.update_columns(cards: @cards, publish_token: "tok#{SecureRandom.hex(4)}")
    @answers = { "0" => { "value" => "A" }, "1" => { "value" => "1990-04" },
                 "2" => { "value" => "GB|London" }, "3" => { "value" => "Female" } }
    @response = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                                          answers: @answers, demographic_birth_year: 1990,
                                          demographic_gender: "Female")
  end

  def run_task(env)
    old = env.keys.index_with { |k| ENV[k] }
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  test "a dry run writes nothing" do
    out, = run_task("TOKEN" => @survey.publish_token, "APPLY" => nil)

    assert_match(/DRY RUN/, out)
    assert_equal @cards, @survey.reload.cards
  end

  test "swaps the card in place and leaves every other card and every answer alone" do
    run_task("TOKEN" => "https://app.playverto.com/play/#{@survey.publish_token}", "APPLY" => "1")

    cards = @survey.reload.cards
    assert_equal 4, cards.size
    assert_equal [ @cards[0], @cards[2], @cards[3] ], cards.values_at(0, 2, 3)

    age = cards[1]
    assert_equal "range", age["type"]
    assert_equal "age", DemographicQuestions.key_for(age)
    assert_equal DemographicQuestions::AGE_BAND_LABELS, age["options"]
    assert_equal "c_birth1", age["cid"], "the cid is kept so cid-addressed references still resolve"
    assert_equal 7, age.dig("i18n", "fr", "options").size, "the Verto's other language gets the slider too"

    @response.reload
    assert_equal @answers, @response.answers
    assert_equal 1990, @response.demographic_birth_year
    assert_equal "Female", @response.demographic_gender
  end

  test "a Verto without the birth-date card is left alone" do
    @survey.update_columns(cards: [ @cards[0] ])

    out, = run_task("TOKEN" => @survey.publish_token, "APPLY" => "1")

    assert_match(/nothing to do/, out)
    assert_equal [ @cards[0] ], @survey.reload.cards
  end
end
