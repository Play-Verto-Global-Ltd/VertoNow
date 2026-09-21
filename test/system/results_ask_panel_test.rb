require "application_system_test_case"

# The results page's Ask Verto chat, which stopped being a permanent 320px
# column and became a floating pill that opens a panel OVER the feed.
#
# Three of the four assertions here exist because nothing else in the suite
# can see them: the panel is positioned (absolute inside the stage below the
# header, so it holds still while the feed scrolls), it is hidden in a way that also takes it out of the tab order
# rather than merely moving it off screen, and the pill has to be clickable on
# a phone — where the consent banner is full width and lands exactly on it.
# The fourth is the guard for the change before it: the global nav is gone
# from this page, and only @hide_main_nav keeps it gone.
class ResultsAskPanelTest < ApplicationSystemTestCase
  # The real banner, not the preset cookie: the phone case below is ABOUT the
  # banner being on screen, and a class attribute is the suite's own way in.
  # The three desktop tests pay one Accept-all click each for it, which is
  # what dismiss_cookie_banner does in this mode anyway.
  self.real_cookie_banner = true

  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "ask-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ask-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Ask panel", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] } ]
    )
  end

  def open_results
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    assert_selector ".results-ask-fab", wait: 5
    # The pill is server-rendered, so finding it says nothing about whether
    # results-chat has been imported and connected — controllers are pinned
    # preload: false and arrive lazily. Every other results system test waits
    # for this before driving anything; this file did not.
    wait_for_stimulus
  end

  # Presses Escape until the panel shuts, or gives up.
  #
  # CI run 35609455398 failed here with the panel still open and the greeting
  # in it, so the click had gone through results-chat and its actions —
  # #toggle on the pill and keydown.esc@window — were bound. closeOnEsc is
  # synchronous and unconditional once it fires, which leaves only one place
  # for that run to have gone wrong: the synthetic keystroke never reached the
  # handler. It did not reproduce in nine full runs of the same CI shard
  # locally, including under twice the worker count, so the mechanism is NOT
  # established — this is written for what is known, which is that one
  # dispatched key was lost somewhere between Ferrum and the page.
  #
  # Retrying the press cannot hide a broken handler: closeOnEsc has no state
  # and no guard beyond "is it open", so a panel that stays open through six
  # seconds of Escapes is a panel whose wiring is wrong, and this still fails
  # — with escape_diagnostics, so the next occurrence costs one look rather
  # than an afternoon of not reproducing it.
  def close_with_escape
    wait_until(timeout: 6) do
      press_keys(:escape)
      page.has_no_selector?("#results-ask-panel", visible: true, wait: 0.3)
    end
  end

  def escape_diagnostics
    evaluate_script(<<~JS)
      (() => {
        const app = window.Stimulus || window.application
        const el  = document.querySelector("[data-controller~='results-chat']")
        const c   = app && el ? app.getControllerForElementAndIdentifier(el, "results-chat") : null
        const a   = document.activeElement
        return JSON.stringify({
          controllerConnected: !!c,
          panelHasIsOpen: document.querySelector("#results-ask-panel")?.classList.contains("is-open"),
          activeElement: a ? (a.className || a.tagName) : null,
          documentHasFocus: document.hasFocus(),
          windowAction: el ? el.getAttribute("data-action") : null
        })
      })()
    JS
  end

  test "the page carries no global nav — its own bar is the whole chrome" do
    open_results

    assert_no_selector ".bottom-bar"
    assert_selector ".results-top-bar .editor-leave-btn", text: I18n.t("results.leave_results")
  end

  test "the pill opens a panel that stays put while the feed scrolls" do
    open_results

    # Shut: visibility:hidden, not merely transparent — an off-screen chat you
    # can still tab into is a trap, and only a real visibility check catches
    # the difference.
    assert_no_selector "#results-ask-panel", visible: true

    find(".results-ask-fab").click
    assert_selector "#results-ask-panel", visible: true
    assert_equal "true", find(".results-ask-fab", visible: :all)["aria-expanded"]

    before = panel_viewport_y
    scroll_feed(600)
    assert_equal before, panel_viewport_y,
      "the panel moved with the feed — it is not anchored to the stage"
  end

  test "Escape closes it and hands focus back to the pill that opened it" do
    open_results

    find(".results-ask-fab").click
    assert_selector "#results-ask-panel", visible: true

    assert close_with_escape, "PANEL STILL OPEN — #{escape_diagnostics}"
    assert evaluate_script("document.activeElement.classList.contains('results-ask-fab')"),
      "focus was left on the page instead of the pill that opened the panel"
  end

  # The consent banner's panel is centred with a 560px cap, so it clears the
  # pill on a desktop and covers it on a phone. The pill docks to the top
  # while the banner is up for exactly this reason; without that rule this
  # click fails with the banner intercepting it.
  test "the pill is clickable on a phone with the consent banner still up" do
    resize_to(390, 844) do
      sign_in_as(@user)
      visit survey_results_path(@survey)
      assert_selector ".cookie-consent-banner", wait: 5
      assert_selector ".results-ask-fab"
      # This is the one test here that keeps the banner, so it never calls
      # dismiss_cookie_banner and never inherits its wait. The pill is
      # server-rendered; the controller that makes it do anything is not.
      wait_for_stimulus

      find(".results-ask-fab").click
      assert_selector "#results-ask-panel", visible: true
    end
  end

  private
    def panel_viewport_y
      evaluate_script("Math.round(document.querySelector('#results-ask-panel').getBoundingClientRect().y)")
    end

    # The stage never scrolls; the feed div inside it does, which is the whole
    # reason the panel is anchored to the stage rather than made sticky.
    def scroll_feed(by)
      evaluate_script(<<~JS)
        (() => {
          const feed = [...document.querySelectorAll("div")].find(d =>
            d.scrollHeight > d.clientHeight + 100 && getComputedStyle(d).overflowY === "auto")
          if (feed) feed.scrollTop = #{by}
        })()
      JS
      # Nothing to wait FOR — the assertion is that a thing does not move.
      sleep 0.3
    end

    # Cuprite, like the rest of the suite's phone-width tests
    # (book_pager_test, brand_logo_absent_test).
    def resize_to(width, height)
      page.driver.browser.resize(width: width, height: height)
      yield
    ensure
      page.driver.browser.resize(width: 1280, height: 900)
    end
end
