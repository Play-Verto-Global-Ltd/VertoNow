require "application_system_test_case"

# The results header's Share button — the dashboard's Share panel, opened from
# the page the creator is on when they decide to send the Verto out.
#
# Worth a browser: the markup wiring is covered in
# test/integration/results_tally_test.rb, but two of the ways this breaks are
# invisible to it. The panel is fetched into a Turbo frame on open, so a
# controller that is on the page but never registered leaves a button that
# does nothing; and the modal is a fixed-position child of a page whose shell
# is overflow:hidden, which is the classic way a correct modal renders
# somewhere nobody can see it.
class ResultsShareButtonTest < ApplicationSystemTestCase
  MODAL = "[data-share-modal-target='modal']".freeze
  OPEN  = "[data-share-modal-target='modal']:not(.hidden)".freeze

  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "rsb-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "rsb-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Share me", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "yes_no", "text" => "Well?", "options" => %w[Yes No] } ]
    )
    6.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                                status: "completed", answers: { "0" => { "value" => "Yes" } })
    end
  end

  def open_results
    page.driver.browser.resize(width: 1440, height: 900)
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    wait_for_stimulus
  end

  test "it opens the Verto's own share panel, in view, and Escape closes it" do
    open_results

    click_settled(find(".rh-pill--share"), until_selector: OPEN)
    assert_selector OPEN, wait: 5

    # The panel itself, not just the shell: its content arrives over Turbo from
    # SurveyLinksController, so an empty modal is a real failure the class
    # assertion above would miss. The address is an input's value, not text.
    within(MODAL) do
      assert_selector "input[value*='#{@survey.publish_token}']", wait: 10
    end

    box = evaluate_script(<<~JS)
      (() => {
        const p = document.querySelector("#{MODAL} .app-modal__panel").getBoundingClientRect()
        return { top: Math.round(p.top), left: Math.round(p.left),
                 width: Math.round(p.width),
                 vw: window.innerWidth, vh: window.innerHeight }
      })()
    JS
    assert_operator box["width"], :>, 100, "the panel rendered with no width"
    assert_operator box["top"], :>=, 0, "the panel is above the top of the window"
    assert_operator box["left"], :>=, 0
    assert_operator box["left"] + box["width"], :<=, box["vw"]

    press_keys(:escape)
    assert_selector "#{MODAL}.hidden", visible: :all, wait: 5
  end

  # Reopening refetches — the controller clears the frame's src on close so a
  # link created in one panel is not what the next one shows.
  test "closing clears the frame so the next open is a fresh fetch" do
    open_results

    click_settled(find(".rh-pill--share"), until_selector: OPEN)
    within(MODAL) { assert_selector "input[value*='#{@survey.publish_token}']", wait: 10 }
    press_keys(:escape)

    assert_equal "", evaluate_script(<<~JS)
      (document.querySelector("#{MODAL} turbo-frame").getAttribute("src") || "")
    JS
  end
end
