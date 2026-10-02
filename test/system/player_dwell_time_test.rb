require "application_system_test_case"

# Dwell time measured in the real player: the clock runs while a card is on
# screen, adds up over a return visit, and reaches the server with each save —
# so the figure the results page reports is one a respondent actually spent.
class PlayerDwellTimeTest < ApplicationSystemTestCase
  def setup
    super
    @org = Organisation.create!(name: "O", slug: "dwl-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Timing", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "cid" => "q1", "text" => "First question", "options" => [ "Alpha", "Beta" ] },
        { "type" => "multiple_choice", "cid" => "q2", "text" => "Second question", "options" => [ "Gamma", "Delta" ] },
        { "type" => "multiple_choice", "cid" => "q3", "text" => "Third question", "options" => [ "Eps", "Zeta" ] }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # The player's own running totals, in ms — what the next save will carry.
  def client_dwell
    page.evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="player"]')
        return app.getControllerForElementAndIdentifier(root, "player")._dwellPayload()
      })()
    JS
  end

  test "time on each card is measured, summed over a return visit, and stored with the answers" do
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_text "First question"

    # A fixed wait is right here: the thing being measured IS the passage of
    # time on a card where nothing else happens.
    sleep 0.6
    find(".choice-list-item", text: "Alpha").click
    find(".preview-btn-next").click
    assert_text "Second question"

    first_visit = client_dwell
    assert_operator first_visit["0"], :>=, 600, "the first card was on screen for at least the wait"
    # The second card's clock started the moment it arrived, so it already
    # holds the few hundred milliseconds this script took to ask. A loose
    # bound: this documents that the clock started on arrival, and a stalled
    # CI shard must not be able to fail it.
    assert_operator first_visit.fetch("1", 0), :<, 10_000, "the second card has only just arrived"
    assert_nil first_visit["2"], "a card never shown has no time"

    # Back onto the first card, then forward again: the second visit adds.
    sleep 0.3
    find(".preview-btn-back").click
    assert_text "First question"
    sleep 0.4
    find(".preview-btn-next").click
    assert_text "Second question"

    revisited = client_dwell
    assert_operator revisited["0"], :>=, first_visit["0"] + 400, "a return visit adds to the card's total"
    assert_operator revisited["1"], :>=, 300, "the time spent on the second card before going back was banked"

    find(".choice-list-item", text: "Gamma").click
    find(".preview-btn-next").click
    assert_text "Third question"
    find(".choice-list-item", text: "Eps").click
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active, [data-player-target='thankyou'].active", wait: 5

    row = wait_for_completed
    stored = row.dwell_ms
    assert_operator stored["0"], :>=, revisited["0"], "the server holds the first card's full total"
    assert_operator stored["1"], :>=, 300
    assert_operator stored["2"], :>, 0, "the last card's time rode the submit"
    assert stored.values.all? { |ms| ms.is_a?(Integer) }, "whole milliseconds"
    assert_equal "Alpha", row.answers.dig("0", "value")
    assert_equal 3, row.answers.size
  end

  # Dwell is kept exactly the way the answers are: in memory, sent with the
  # saves, never written to the device. The Privacy Notice tells respondents
  # the player keeps no analytics storage, and for a day it did — the totals
  # were mirrored into sessionStorage so a reload could resume them.
  test "timings stay off the device, and a reload starts them over just as it starts the answers over" do
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_text "First question"

    sleep 0.5
    find(".choice-list-item", text: "Alpha").click
    find(".preview-btn-next").click
    assert_text "Second question"
    # The first answered card registers the respondent, carrying its time.
    wait_until { @survey.responses.reload.first&.answers&.key?("0") }
    saved = @survey.responses.first.dwell_ms
    assert_operator saved["0"], :>=, 500, "the first save carried the first card's time"

    sleep 0.4
    assert_operator client_dwell.fetch("1", 0), :>=, 400, "the second card is being timed"
    assert_empty stored_dwell_keys, "nothing about timing is written to the browser's storage"

    page.refresh
    assert_selector ".preview-card.active", wait: 5
    assert_text "First question"

    state = page.evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="player"]')
        const c    = app.getControllerForElementAndIdentifier(root, "player")
        return { answers: Object.keys(c._answers), dwell: Object.keys(c._dwellPayload()) }
      })()
    JS
    assert_empty state["answers"], "a reload starts the answers over"
    assert_equal [ "0" ], state["dwell"], "and the timings: only the card on screen now has any"
    assert_equal saved["0"], @survey.responses.first.reload.dwell_ms["0"],
                 "what already reached the server stays there"
    assert_empty stored_dwell_keys
  end

  private

  # Every storage key on the page that names timing, in either store.
  def stored_dwell_keys
    page.evaluate_script(<<~JS)
      [ ...Object.keys(sessionStorage), ...Object.keys(localStorage) ].filter(k => /dwell/i.test(k))
    JS
  end

  def wait_for_completed
    deadline = Time.current + 8
    loop do
      row = @survey.responses.reload.first
      return row if row&.status == "completed"
      raise "no completed response after 8s" if Time.current > deadline
      sleep 0.2
    end
  end
end
