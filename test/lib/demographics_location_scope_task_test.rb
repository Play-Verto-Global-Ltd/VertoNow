require "test_helper"
require "rake"

# The one-off narrowing of a live Verto's location-card search (LocationScope).
# What matters, as with swap_age_card, is what it does NOT touch: card
# positions and stored answers, which are keyed by index.
class DemographicsLocationScopeTaskTest < ActiveSupport::TestCase
  LONDON = { "name" => "London", "country_code" => "GB", "bbox" => [ 51.28, 51.69, -0.51, 0.33 ] }.freeze

  def setup
    unless Rake::Task.task_defined?("demographics:location_scope")
      Rake::Task.define_task(:environment)
      load Rails.root.join("lib/tasks/demographics.rake")
    end
    @task = Rake::Task["demographics:location_scope"]

    @org    = Organisation.create!(name: "O", slug: "locs-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ], cards: [])
    @cards = [
      { "type" => "multiple_choice", "text" => "Q1", "options" => [ "A", "B" ], "cid" => "c_q1" },
      { "type" => "open_ended", "input" => "location", "text" => "Where do you live?", "demographic" => true,
        "cid" => "c_loc", "location_places" => [ "city" ], "location_cities" => [ LONDON ] },
      { "type" => "multiple_choice", "text" => "What gender best describes you?",
        "options" => [ "Male", "Female" ], "demographic" => true, "cid" => "c_g" }
    ]
    @survey.update_columns(cards: @cards, publish_token: "tok#{SecureRandom.hex(4)}", published_at: Time.current)
    @answers = { "0" => { "value" => "A" }, "1" => { "value" => "GB|London" }, "2" => { "value" => "Female" } }
    @response = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: @answers)
  end

  def run_task(env)
    keys = %w[TOKEN PLACES COUNTRIES CARD CLEAR APPLY]
    old  = keys.index_with { |k| ENV[k] }
    keys.each { |k| ENV[k] = env[k] }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  test "a dry run writes nothing" do
    out, = run_task("TOKEN" => @survey.publish_token, "PLACES" => "country")

    assert_match(/DRY RUN/, out)
    assert_match(/city, in cities London  →  country/, out)
    assert_equal @cards, @survey.reload.cards
  end

  test "APPLY sets countries only on the location card, drops its city limit, and moves nothing" do
    out, = run_task("TOKEN" => "https://app.playverto.com/play/#{@survey.publish_token}?x=1",
                    "PLACES" => "Country", "APPLY" => "1")

    assert_match(/Applied/, out)
    cards = @survey.reload.cards
    assert_equal %w[country], cards[1]["location_places"]
    refute cards[1].key?("location_cities"), "a country can't be inside a city"
    assert_equal "c_loc", cards[1]["cid"]
    assert_equal @cards[0], cards[0]
    assert_equal @cards[2], cards[2]
    assert_equal @answers, @response.reload.answers
  end

  test "countries narrow alongside places, and CLEAR takes it all off" do
    run_task("TOKEN" => @survey.publish_token, "PLACES" => "country", "COUNTRIES" => "ke, gb", "APPLY" => "1")
    assert_equal %w[KE GB], @survey.reload.cards[1]["location_countries"]

    run_task("TOKEN" => @survey.publish_token, "CLEAR" => "1", "APPLY" => "1")
    card = @survey.reload.cards[1]
    %w[location_places location_countries location_cities].each { |k| refute card.key?(k), k }
  end

  test "a typo is refused rather than quietly becoming any place" do
    assert_raises(SystemExit) do
      run_task("TOKEN" => @survey.publish_token, "PLACES" => "countrys", "APPLY" => "1")
    end
    assert_raises(SystemExit) do
      run_task("TOKEN" => @survey.publish_token, "COUNTRIES" => "XX", "APPLY" => "1")
    end
    assert_equal @cards, @survey.reload.cards
  end

  test "several location cards need CARD to say which" do
    extra = { "type" => "open_ended", "input" => "location", "text" => "Where do you work?", "cid" => "c_work" }
    extra2 = extra.merge("text" => "Where did you grow up?", "cid" => "c_grew")
    @survey.update_columns(cards: [ @cards[0], extra, extra2 ])

    assert_raises(SystemExit) { run_task("TOKEN" => @survey.publish_token, "PLACES" => "country", "APPLY" => "1") }

    run_task("TOKEN" => @survey.publish_token, "PLACES" => "country", "CARD" => "3", "APPLY" => "1")
    cards = @survey.reload.cards
    assert_equal %w[country], cards[2]["location_places"]
    refute cards[1].key?("location_places")
  end
end
