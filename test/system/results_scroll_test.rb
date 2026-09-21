require "application_system_test_case"

# The two things results_outline_controller does with the feed's scroll
# position: condense the header, and mark where the reader is in the rail.
#
# Both need a browser and neither has any other coverage — they are pure
# client behaviour on a page whose scrolling element is a div rather than the
# window, which is exactly the kind of thing that breaks silently when someone
# later reaches for `window.scrollY`.
#
# Each test below was checked by breaking the code under it, not assumed.
class ResultsScrollTest < ApplicationSystemTestCase
  # The rail is only drawn where there is a margin to draw it in.
  WIDE = 1440

  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "rs-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "rs-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    # Enough cards that the feed is several screens tall — the spy has nothing
    # to say about a page that fits.
    cards = (1..16).map { |n| { "type" => "multiple_choice", "text" => "Question #{n}", "options" => %w[A B] } }
    @survey = @org.surveys.create!(
      title: "Scroll", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current, cards: cards
    )
    3.times do
      answers = (0...16).to_h { |i| [ i.to_s, { "value" => "A" } ] }
      @survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                                status: "completed", answers: answers)
    end
  end

  def open_results
    page.driver.browser.resize(width: WIDE, height: 900)
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    assert_selector ".ro-item", minimum: 16, wait: 5
    wait_for_stimulus
  end

  def scroll_feed_to(y)
    execute_script("document.querySelector('.results-stage > div').scrollTop = #{y}")
  end

  def scroll_top
    evaluate_script("document.querySelector('.results-stage > div').scrollTop")
  end

  def header_height
    evaluate_script("Math.round(document.querySelector('.results-header').getBoundingClientRect().height)")
  end

  def top_bar_height
    evaluate_script("Math.round(document.querySelector('.results-top-bar').getBoundingClientRect().height)")
  end

  # Waits for the fold to be COMPLETELY over. Two separate traps here, both of
  # which turned the suite red before this said what it says now:
  #
  #   * settle_box on the header says nothing about it. The header's own box
  #     is stable long before the bar above it has finished collapsing.
  #   * Height reaching zero is not the end either. The bar's visibility is
  #     transitioned with a 0.2s delay, deliberately — it must stay visible
  #     while it collapses — so for one window it is 0px tall and still
  #     `visibility: visible`, and its children are merely CLIPPED rather than
  #     hidden. A clipped child still reports its own height, which is how
  #     "exactly one way out" counted two.
  def wait_for_fold
    wait_until do
      evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector(".results-top-bar")
          return Math.round(el.getBoundingClientRect().height) === 0 &&
                 getComputedStyle(el).visibility === "hidden"
        })()
      JS
    end
  end

  # Everything above the feed: the title bar and the header together.
  def chrome_height
    evaluate_script(<<~JS)
      (() => {
        const h = s => document.querySelector(s).getBoundingClientRect().height
        return Math.round(h(".results-top-bar") + h(".results-header"))
      })()
    JS
  end

  def visible_leave_pills
    evaluate_script(<<~JS)
      [...document.querySelectorAll(".editor-leave-btn")].filter(e => {
        const c = getComputedStyle(e)
        return c.display !== "none" && c.visibility !== "hidden" && e.getBoundingClientRect().height > 0
      }).length
    JS
  end

  def condensed?
    evaluate_script("document.querySelector('.results-header').classList.contains('is-condensed')")
  end

  def current_row
    evaluate_script("document.querySelector('.ro-item.is-current')?.textContent.replace(/\\s+/g,' ').trim() || null")
  end

  # Opens a <details> in the header, and keeps trying until it is open.
  #
  # The header is mid-animation for 200ms after it condenses — the title bar
  # collapsing 54px to nothing moves everything below it — and Cuprite clicks
  # by COORDINATE, computed one round-trip before the click lands. settle_box
  # on the summary was not enough: CI 35616357129 lost the click anyway and
  # Main went red on it.
  #
  # Clicking a toggle twice would close it again, so this checks the state
  # between attempts and only clicks while it is shut. That is why it cannot
  # hide a summary that does not open its details: a <details> that stays
  # closed through six seconds of clicks still fails here.
  def open_menu(selector)
    settle_box(find("#{selector} summary"))
    opened = wait_until(timeout: 6) do
      find("#{selector} summary").click unless page.has_selector?("#{selector}[open]", wait: 0)
      page.has_selector?("#{selector}[open]", wait: 0.3)
    end
    assert opened, "#{selector} did not open"
  end

  # Two boxes are on the same line iff their vertical spans overlap. Comparing
  # `top` would fail on anything the header centres, which is everything in it.
  def same_line?(a, b)
    evaluate_script(<<~JS)
      (() => {
        const x = document.querySelector("#{a}").getBoundingClientRect()
        const y = document.querySelector("#{b}").getBoundingClientRect()
        return x.bottom > y.top + 1 && x.top < y.bottom - 1
      })()
    JS
  end

  # A smooth scroll takes a few hundred milliseconds, so "it has started
  # moving" is not "it has arrived" — measuring at the first non-zero
  # scrollTop reads a position mid-animation. Waits for two consecutive
  # identical readings instead of a fixed sleep.
  def wait_for_scroll_settle
    last = nil
    wait_until do
      now = scroll_top
      settled = last == now
      last = now
      settled
    end
  end

  test "the header gives back its space once you have scrolled, and takes it back at the top" do
    open_results
    tall = header_height
    assert_not condensed?, "the header starts condensed — nothing has been scrolled yet"

    scroll_feed_to(600)
    assert wait_until { condensed? }, "scrolling the feed did not condense the header"
    short = header_height
    assert short < tall,
      "the header still measures #{short}px after condensing (was #{tall}px) — the class landed but bought nothing"

    scroll_feed_to(0)
    assert wait_until { !condensed? },
      "scrolling back to the top left the header condensed"
  end

  # The point of condensing: the filters join the actions' row instead of
  # costing a row of their own, and each collapses to the one option in force.
  # All of it is CSS ordering and display, which is exactly the kind of thing
  # that regresses without any test noticing.
  test "condensed, the filters join the actions' row and show only what is selected" do
    open_results
    assert_selector ".rh-when .rh-when-btn", count: 4, visible: true
    assert_no_selector ".rh-when-menu", visible: true

    scroll_feed_to(600)
    assert wait_until { condensed? }

    refute page.has_selector?(".rh-when", visible: true),
      "the four-option segmented control is still drawn on the condensed header"
    assert_selector ".rh-when-menu summary", visible: true
    assert_equal "All time", find(".rh-when-menu summary .rh-picker-active").text.strip

    assert same_line?(".results-header-filters", ".results-header-actions"),
      "the filters are still on a row of their own next to a condensed header"

    # …and the options are one click away.
    open_menu(".rh-when-menu")
    assert_selector ".rh-when-menu-panel .rh-menu-item", count: 4, visible: true
    assert_selector ".rh-when-menu-panel .rh-menu-item", text: "Last 30 days"
  end

  # The title bar is what you need on arrival and 54px of a page you are now
  # reading. It folds, and the way out moves into the header's row rather than
  # folding with it.
  test "condensed, the title bar folds away and the way out joins the actions' row" do
    open_results
    chrome_before = chrome_height
    assert_selector ".results-top-bar .editor-verto-title", visible: true

    scroll_feed_to(600)
    assert wait_until { condensed? }
    wait_for_fold

    refute page.has_selector?(".results-top-bar .editor-verto-title", visible: true),
      "the Verto's name is still drawn on a header that has condensed"
    assert_selector ".rh-leave", visible: true
    assert same_line?(".rh-leave", ".results-header-actions"),
      "the way out is not on the same row as Export / Share / AI Report"

    assert chrome_height < chrome_before / 2,
      "the chrome is #{chrome_height}px condensed against #{chrome_before}px open — the fold bought almost nothing"
  end

  # The pill is rendered twice and CSS picks one. Two of them is a duplicated
  # control; none of them is a reader with no way off the page. Both failures
  # are silent, and the second is the one that matters.
  test "there is exactly one way out, whatever the header is doing" do
    open_results
    assert_equal 1, visible_leave_pills, "expected one way out on an open header"

    scroll_feed_to(600)
    assert wait_until { condensed? }
    wait_for_fold
    assert_equal 1, visible_leave_pills, "expected one way out on a condensed header"

    # The hidden one must be out of the tab order, not merely invisible — a
    # link you can still tab to but cannot see is a trap. Asked the way a
    # keyboard user asks it, by trying to focus each one, rather than by
    # checking for a particular CSS property: the header's copy is hidden with
    # display:none and the top bar's by an inherited visibility:hidden, and
    # both are correct answers to "can I reach this".
    assert_equal 1, evaluate_script(<<~JS), "a hidden way out can still be tabbed to"
      [...document.querySelectorAll(".editor-leave-btn")].filter(e => {
        e.focus()
        const got = document.activeElement === e
        e.blur()
        return got
      }).length
    JS
  end

  test "scrolling back to the top brings the title bar back" do
    open_results
    scroll_feed_to(600)
    assert wait_until { condensed? }

    scroll_feed_to(0)
    assert wait_until { !condensed? }
    settle_box(find(".results-top-bar"))

    assert_selector ".results-top-bar .editor-verto-title", visible: true
    assert_equal 1, visible_leave_pills
  end

  # Two dropdowns open over each other is what you get from four independent
  # <details>. They share a `name`, which makes the browser treat them as one
  # exclusive group — no controller, and it degrades to the old behaviour
  # rather than breaking anywhere that doesn't support it.
  test "opening one header menu closes the others" do
    open_results
    scroll_feed_to(600)
    assert wait_until { condensed? }

    open_menu(".rh-when-menu")
    assert_selector ".rh-when-menu[open]"

    find(".results-header-actions details:first-of-type summary").click
    assert_selector ".results-header-actions details[open]"
    refute page.has_selector?(".rh-when-menu[open]", wait: 1),
      "the date menu stayed open behind the export menu"
  end

  # The point of the rail: it says where you are. Two different scroll
  # positions must mark two different questions, and the one marked has to be
  # the one on screen.
  test "the rail marks the question you are reading, and moves as you scroll" do
    open_results
    wait_until { current_row.present? }
    first = current_row

    scroll_feed_to(evaluate_script("document.querySelector('.results-stage > div').scrollHeight") / 2)
    assert wait_until { current_row != first }, "the marked question did not change when the feed scrolled"
    middle = current_row

    # …and it is a question actually in view, not merely a different one.
    n = middle.to_s[/\A(\d+)/, 1].to_i
    assert n.positive?
    in_view = evaluate_script(<<~JS)
      (() => {
        const card = document.getElementById("rc-card-#{n - 1}")
        const box  = document.querySelector(".results-stage > div").getBoundingClientRect()
        const r    = card.getBoundingClientRect()
        return r.bottom > box.top && r.top < box.bottom
      })()
    JS
    assert in_view, "the rail marks question #{n}, which is not on screen"
  end

  # The rail holds still. It is `position: sticky` inside the scrolling div,
  # which is the part that would break if the layout around it changed — a
  # sticky element inside an `overflow: hidden` ancestor silently scrolls away.
  test "the rail stays put while the feed moves under it" do
    open_results
    rail_top = -> { evaluate_script("Math.round(document.querySelector('.results-outline').getBoundingClientRect().top)") }
    top_before = rail_top.call
    chrome_before = chrome_height

    scroll_feed_to(1500)
    assert wait_until { condensed? }
    settle_box(find(".results-outline"))

    # It rises by however much the CHROME above it gave back — the title bar
    # and the header together — and no further. Stated against the measured
    # shrink rather than a number, so tuning either one doesn't quietly turn
    # this into a test of nothing. (It already earned that: the title bar
    # learning to fold took the give-back from 27px to 113px, and this said so
    # rather than passing.)
    gave_back = chrome_before - chrome_height
    moved = top_before - rail_top.call
    assert moved.between?(0, gave_back + 4),
      "the rail moved #{moved}px up the screen while the chrome gave back #{gave_back}px — " \
      "it is scrolling with the feed, not sticking to it"
  end

  test "clicking a question scrolls the feed to it" do
    open_results
    assert_equal 0, scroll_top

    find(".ro-item", text: /\A\s*5\b/, match: :first).click

    assert wait_until { scroll_top > 0 }, "clicking a row did not scroll the feed"
    wait_for_scroll_settle
    landed = evaluate_script(<<~JS)
      (() => {
        const box = document.querySelector(".results-stage > div").getBoundingClientRect()
        const r   = document.getElementById("rc-card-4").getBoundingClientRect()
        return Math.round(r.top - box.top)
      })()
    JS
    assert landed.abs < 60,
      "clicked question 5 and its card landed #{landed}px from the top of the feed"
  end
end
