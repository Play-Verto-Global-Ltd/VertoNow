require "application_system_test_case"

# The "over time" tab on the results page (answer_timeline_controller): a
# click on an answer row opens it beside the feed with every answer's line
# and the clicked one emphasised, the legend moves the emphasis and the row
# highlight with it, the range asks the server again, and Escape closes it.
# The endpoint's own contract is test/integration/results_timeline_test.rb;
# this is the browser half.
class ResultsTimelineTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "tls-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "tls-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "member")
    @survey = @org.surveys.create!(
      title: "TLS", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green Red] } ]
    )
    # Three weeks, six answers a day — enough in every day for a daily view
    # to show every point, so the shape is there to click on.
    21.times do |d|
      6.times do |i|
        at = Time.current.utc.change(hour: 12) - d.days
        @survey.responses.create!(
          session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
          created_at: at, updated_at: at,
          answers: { "0" => { "type" => "multiple_choice", "value" => %w[Blue Blue Blue Green Green Red][i] } }
        )
      end
    end
  end

  def open_results
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    assert_selector "button.rc-row", minimum: 3, wait: 5
  end

  def panel
    find("#results-timeline", visible: :all)
  end

  test "a row opens the tab on its answer, the legend moves the emphasis, Escape closes it" do
    open_results
    assert_selector "#results-timeline", visible: :hidden

    click_button "Blue"
    assert_selector "#results-timeline", visible: :visible, wait: 5
    within("#results-timeline") do
      assert_text "Blue"
      assert_text "Colour?"
      assert_selector ".rc-timeline-legend .rc-timeline-lg", count: 3, wait: 10
      assert_selector ".rc-timeline-lg.is-on", text: "Blue"
      assert_selector ".rc-timeline-chart svg path", minimum: 3, wait: 10
      assert_selector ".rc-timeline-segbtn.is-on", text: "All time"
      assert_no_text "Loading"
    end
    assert_selector "button.rc-row.is-picked", count: 1
    assert_selector "button.rc-row.is-picked", text: "Blue"

    within("#results-timeline") { click_button "Green" }
    assert_selector "#results-timeline .rc-timeline-title", text: "Green", wait: 5
    assert_selector "#results-timeline .rc-timeline-lg.is-on", text: "Green"
    assert_selector "button.rc-row.is-picked", text: "Green", wait: 5
    assert_selector "button.rc-row.is-picked", count: 1

    press_keys(:escape)
    assert_selector "#results-timeline", visible: :hidden, wait: 5
    assert_no_selector "button.rc-row.is-picked"
  end

  test "the range asks the server again, and Custom takes a From and To" do
    open_results
    click_button "Red"
    within("#results-timeline") do
      assert_selector ".rc-timeline-lg", count: 3, wait: 10
      first_labels = all(".rc-timeline-chart svg text").map(&:text)

      click_button "7d"
      assert_selector ".rc-timeline-segbtn.is-on", text: "7d"
      assert_selector ".rc-timeline-chart svg path", minimum: 3, wait: 10
      assert wait_until { all(".rc-timeline-chart svg text").map(&:text) != first_labels },
        "the window changed and the chart's axis did not"

      click_button "Custom"
      assert_selector ".rc-timeline-custom input[type=date]", count: 2
      from = find("[data-answer-timeline-target='from']")
      to   = find("[data-answer-timeline-target='to']")
      assert_equal 7.days.ago.to_date.iso8601, from.value, "the custom window starts from the one just shown"
      assert_equal Date.current.iso8601, to.value
    end

    # Ten days back — a window the 7d preset never shows — set the way a
    # browser sets a date input, with the change event the tab listens for.
    execute_script(<<~JS, 10.days.ago.to_date.iso8601)
      const el = document.querySelector("[data-answer-timeline-target='from']")
      el.value = arguments[0]
      el.dispatchEvent(new Event("change", { bubbles: true }))
    JS
    within("#results-timeline") do
      assert_selector ".rc-timeline-chart svg text", text: 10.days.ago.to_date.strftime("%-d %b"), wait: 10
    end
  end
end
