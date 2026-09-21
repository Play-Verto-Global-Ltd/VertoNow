require "application_system_test_case"

# The results page's Ask Verto chat, which stopped being a permanent 320px
# column and became a floating pill that opens a panel OVER the feed.
#
# Three of the four assertions here exist because nothing else in the suite
# can see them: the panel is positioned (fixed, so it holds still while the
# feed scrolls), it is hidden in a way that also takes it out of the tab order
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
      "the panel moved with the feed — it is not fixed to the viewport"
  end

  test "Escape closes it and hands focus back to the pill that opened it" do
    open_results

    find(".results-ask-fab").click
    assert_selector "#results-ask-panel", visible: true

    press_keys(:escape)
    assert_no_selector "#results-ask-panel", visible: true
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

    # The shell itself never scrolls; the feed div inside it does, which is the
    # whole reason the panel has to be fixed rather than sticky.
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
