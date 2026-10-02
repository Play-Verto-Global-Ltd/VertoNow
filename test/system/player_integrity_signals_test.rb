require "application_system_test_case"

# The integrity signals the player sends, measured in a real browser on a
# phone-sized window: a slider left where it opened, a changed mind, and long
# answer lists read to the end or not — with the scroll cue's own movement never
# counted as the respondent's.
class PlayerIntegritySignalsTest < ApplicationSystemTestCase
  PHONE = [ 360, 560 ].freeze # eight long options do not fit
  LONG  = [ "Buy the cold water — it is hot outside and the walk back is long",
            "Use the public fountain — it is free but it is a detour",
            "Wait until you get home and drink there instead of now",
            "Ask a friend to share theirs with you for the walk",
            "Buy a reusable bottle you can refill all week",
            "Skip it entirely and carry on without a drink",
            "Take the bus so the walk is shorter and you need less",
            "Fill up at the school fountain before you leave" ].freeze
  # The scroll cue's whole run (pre-roll, down, hold, up) plus its retry
  # budget. Used only to prove the cue alone records nothing.
  CUE_DONE = 2.6

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "pis-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Signals", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "q0", "text" => "Which would you choose?", "options" => LONG },
               { "type" => "multiple_choice", "cid" => "q1", "text" => "Pick a colour", "options" => %w[Red Green Blue] },
               { "type" => "range", "cid" => "q2", "text" => "How was it?", "options" => %w[Awful Poor Fine Good Great] },
               { "type" => "multiple_choice", "cid" => "q3", "text" => "And next time?", "options" => LONG } ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def player_signals
    page.evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="player"]')
        return app.getControllerForElementAndIdentifier(root, "player")._integrityPayload(null)
      })()
    JS
  end

  def next_card(index)
    click_button "Next"
    assert_selector ".preview-card.active[data-card-index='#{index}']", wait: 5
  end

  test "untouched sliders, changed picks and long lists read to the end reach the server" do
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active[data-card-index='0']", wait: 5

    # Card 0 overflows; the scroll cue nudges it and comes back. The cue's
    # movement is not the respondent reading, so the list stays unread.
    sleep CUE_DONE
    assert_equal({ "0" => 0 }, player_signals["seen"], "an overflowing list is tracked, and the cue alone is not reach")
    find(".preview-card.active .choice-list-item", match: :first).click
    next_card(1)

    # Card 1: a changed mind.
    find(".preview-card.active .choice-list-item", text: "Red").click
    find(".preview-card.active .choice-list-item", text: "Blue").click
    assert wait_until { player_signals["changes"] == { "1" => 1 } }, "replacing Red with Blue is one change"
    next_card(2)

    # Card 2: the slider is left where it opened.
    next_card(3)
    assert_equal [ "2" ], player_signals["untouched"]

    # Card 3: read to the end of the list.
    page.execute_script(<<~JS)
      (() => {
        const list = document.querySelector(".preview-card.active .choice-list")
        let box = list.parentElement
        while (box && !(["auto", "scroll"].includes(getComputedStyle(box).overflowY) && box.scrollHeight > box.clientHeight)) box = box.parentElement
        box.scrollTop = box.scrollHeight
      })()
    JS
    assert wait_until { player_signals["seen"]["3"] == 1 }, "scrolling to the end of the list is recorded"
    find(".preview-card.active .choice-list-item", text: LONG.last).click
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active, [data-player-target='thankyou'].active", wait: 5

    wait_until { @survey.responses.reload.first&.status == "completed" }
    row = @survey.responses.first
    assert_equal 1, row.integrity["v"]
    assert_equal [ "2" ], row.integrity["untouched"]
    assert_equal({ "1" => 1 }, row.integrity["changes"])
    assert_equal({ "0" => 0, "3" => 1 }, row.integrity["seen"])
    assert_equal false, row.integrity["offline"]
    assert_includes ResponseIntegrity::SCORED_BANDS, row.integrity_band
    assert_not_nil row.integrity_score
    assert_empty page.evaluate_script(<<~JS), "and none of it is written to the browser's storage"
      [ ...Object.keys(sessionStorage), ...Object.keys(localStorage) ].filter(k => /integrity|reach|untouched/i.test(k))
    JS
  end
end
