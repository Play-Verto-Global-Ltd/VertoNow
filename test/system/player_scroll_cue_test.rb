require "application_system_test_case"

# The answer list teaches itself to scroll, once, by moving.
#
# Reported from a study run on students' own phones: on a long list the first
# option is the only one on screen, so it is the one that gets picked, and the
# answer distribution becomes a property of the viewport rather than of the
# question. That is a measurement defect, not a cosmetic one — "the RAs will
# remind them to scroll" was not an acceptable answer to it.
#
# The fade (is-scrollable) says there is more below. It is not enough on its
# own, and it stays: this adds one option's worth of travel and a return, so
# the list says it MOVES. Not a scroll to the bottom, which was the other
# candidate — on a list long enough to need this, travelling to the end takes
# the question off screen with it.
#
# Most of what is below is about when the cue must NOT run, because every one
# of those cases was a way of getting it wrong:
#
#   * it spent its one showing at SCHEDULING rather than on movement, and
#     listened for interruptions on `window` — so the tap that dismissed the
#     cookie banner cancelled a cue that had not moved anything yet, and
#     nothing brought it back. Measured: armed on every viewport, peak 0 on all
#     of them. The two tests naming furniture below are that bug.
#   * it armed behind the consent banner, which dims the deck and marks
#     .preview-body inert — motion on a list the respondent can neither read
#     properly nor touch.
class PlayerScrollCueTest < ApplicationSystemTestCase
  PHONE   = [ 360, 560 ].freeze   # eight options do not fit
  DESKTOP = [ 1440, 700 ].freeze  # nor here — the panel is short, not narrow
  ROOMY   = [ 1024, 1290 ].freeze # iPad upright: three options with room to spare

  # Long enough to wrap, because a one-word option list is not the shape that
  # was reported and fits where the real one does not.
  LONG = [ "Buy the cold water — it is hot outside and the walk back is long",
           "Use the public fountain — it is free but it is a detour",
           "Wait until you get home and drink there instead of now",
           "Ask a friend to share theirs with you for the walk",
           "Buy a reusable bottle you can refill all week",
           "Skip it entirely and carry on without a drink",
           "Take the bus so the walk is shorter and you need less",
           "Fill up at the school fountain before you leave" ].freeze
  SHORT = LONG.first(3).freeze

  # Long enough for the whole cue (520 pre-roll + 420 down + 460 hold + 380 up)
  # plus the six-look retry budget (~720ms) to have run and finished. Only ever
  # used to prove that nothing happens — for anything that does happen there is
  # a wait_until below.
  QUIET = 2.6

  # Sampled every frame from before the cue can start, rather than polled from
  # Ruby: the travel is 420ms and a round-trip poll that lands either side of it
  # would report a cue that ran as one that did not.
  RECORDER = <<~JS
    window.__cue = { peak: 0, last: 0 }
    window.__box = () => {
      const card = document.querySelector(".preview-card.active")
      const list = card && card.querySelector(".choice-list, .pick-list, .choice-grid")
      for (let el = list && list.parentElement; el && el !== document.body; el = el.parentElement) {
        const oy = getComputedStyle(el).overflowY
        if ((oy === "auto" || oy === "scroll") && el.scrollHeight - el.clientHeight > 1) return el
      }
      return null
    }
    const tick = () => {
      const box = window.__box()
      if (box) {
        window.__cue.last = Math.round(box.scrollTop)
        window.__cue.peak = Math.max(window.__cue.peak, window.__cue.last)
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  JS

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "cue-#{SecureRandom.hex(3)}")
  end

  def teardown
    page.driver.browser.resize(width: 1400, height: 900)
    super
  end

  def build_verto(options: LONG, consent: nil)
    survey = @org.surveys.create!(
      title: "Cue", theme: "Climate", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], consent_text: consent,
      cards: [ { "type" => "multiple_choice", "cid" => "q1", "text" => "Which would you choose?",
                 "description" => "Read on, then choose", "options" => options },
               { "type" => "multiple_choice", "cid" => "q2", "text" => "And which next time?",
                 "description" => "Read on, then choose", "options" => options } ])
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  # The recorder goes in immediately after the visit and BEFORE the cookie
  # banner is dealt with — dismiss_cookie_banner waits for every controller on
  # the page to connect, which is roughly when the cue arms, so a recorder
  # installed after it can miss the whole thing.
  def open_player(survey, width, height, consent: false)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{survey.publish_token}"
    page.execute_script(RECORDER)
    dismiss_cookie_banner
    agree_to_consent_gate if consent
  end

  def cue          = page.evaluate_script("window.__cue")
  def reset_cue    = page.execute_script("window.__cue.peak = 0")
  def scroller?    = page.evaluate_script("!!window.__box()")
  def fade?        = page.evaluate_script("!!document.querySelector('.preview-card.active .split-right > .mt-2.is-scrollable')")

  # Fire on the given element every 40ms for 600ms. The cue's pre-roll is
  # 520ms and starts at a moment no test can name (it arms a frame after the
  # card settles, and looks again up to six times if the panel has not settled
  # yet), so a single dispatch at a guessed instant proves nothing either way.
  # Blanketing the window is deterministic and is what a respondent tapping
  # their way past a banner actually does.
  def pelt(target, event)
    page.execute_script(<<~JS)
      (() => {
        const at = #{target}
        let n = 0
        const fire = () => {
          if (!at || n++ > 15) return
          at.dispatchEvent(new (#{event == "wheel" ? "WheelEvent" : "PointerEvent"})("#{event}", { bubbles: true }))
          setTimeout(fire, 40)
        }
        fire()
      })()
    JS
  end

  def answer_and_advance
    find(".preview-card.active .choice-list-item", match: :first).click
    click_button "Next"
    assert_selector ".preview-card.active[data-card-index='1']", wait: 5
  end

  test "a list with more options than screen shows itself moving, then puts itself back" do
    open_player(build_verto, *PHONE)

    assert wait_until(timeout: 8, interval: 0.02) { cue["peak"] > 2 },
      "the answer list never moved — a respondent on a 360px phone is left with the fade alone, " \
      "which is the cue that was already there and already not enough"
    assert wait_until(timeout: 8, interval: 0.02) { cue["last"] <= 2 },
      "the list travelled and stayed there. The cue has to come back: it is teaching that the " \
      "list moves, not answering the question by scrolling past the first option"
    assert_operator cue["peak"], :<, 120,
      "the cue ran the list instead of nudging it — one option's worth of travel is the point, " \
      "and anything longer takes the question off the screen with it"
  end

  test "the same respondent is only shown it once" do
    open_player(build_verto, *DESKTOP)
    assert wait_until(timeout: 8, interval: 0.02) { cue["peak"] > 2 }
    assert wait_until(timeout: 8, interval: 0.02) { cue["last"] <= 2 }

    answer_and_advance
    reset_cue
    sleep QUIET

    assert_equal 0, cue["peak"],
      "the second long list nudged too. Being shown the same thing on every card is a tic, not a " \
      "cue — once a play is the whole design"
  end

  test "an answer that fits is left alone" do
    open_player(build_verto(options: SHORT), *ROOMY)
    sleep QUIET

    assert_not scroller?, "three options overflowed an iPad — the fixture, not the cue, is wrong"
    assert_equal 0, cue["peak"], "a list with nothing below the fold moved anyway, which reads as a glitch"
  end

  test "reduced motion keeps the fade and loses the movement" do
    emulate_reduced_motion do
      open_player(build_verto, *PHONE)
      sleep QUIET

      assert_equal 0, cue["peak"], "prefers-reduced-motion asked for no motion and got some"
      assert fade?, "the fade went with it — reduced motion removes the movement, not the only " \
                    "other thing telling this respondent there is more below"
    end
  end

  # ── The two that are the bug ────────────────────────────────────────────

  test "tapping the furniture on the way in does not spend the cue" do
    open_player(build_verto, *PHONE)
    pelt("document.body", "pointerdown")

    assert wait_until(timeout: 8, interval: 0.02) { cue["peak"] > 2 },
      "a tap somewhere that is not the answer list killed the cue. Accept all, Agree & continue " \
      "and an intro modal's button are all of them taps a first-time respondent makes before they " \
      "have looked at the options — which is exactly who this is for"
  end

  test "it waits for the consent banner rather than running behind it" do
    open_player(build_verto(consent: "We record your answers for this study."), *PHONE)
    assert_selector "[data-consent-pending]", visible: :all
    sleep QUIET

    assert_equal 0, cue["peak"],
      "the list moved under the consent banner, which dims the deck and marks it inert — motion " \
      "on something the respondent cannot read properly or touch, spent before they arrive"

    reset_cue
    click_button "Agree & continue"

    assert wait_until(timeout: 8, interval: 0.02) { cue["peak"] > 2 },
      "the deck went live and the cue never came. _dismissConsentBanner re-runs _update, which is " \
      "what is meant to hand it its first real chance"
  end

  # ── Interruption ────────────────────────────────────────────────────────

  test "a hand on the list stops it where they put it" do
    open_player(build_verto, *PHONE)
    assert wait_until(timeout: 8, interval: 0.02) { cue["last"] > 2 }
    page.execute_script("window.__box().dispatchEvent(new WheelEvent('wheel', { bubbles: true }))")
    sleep QUIET

    assert_operator cue["last"], :>, 0,
      "the cue carried on past a hand on the list and put it back where IT wanted. A cue that " \
      "fights the person it is teaching is a bug report"
  end

  test "a touch before it starts leaves the next card free to teach it" do
    open_player(build_verto, *PHONE)
    pelt("window.__box()", "pointerdown")
    sleep QUIET

    assert_equal 0, cue["peak"], "the pre-roll was interrupted and it ran anyway"

    answer_and_advance
    reset_cue

    assert wait_until(timeout: 8, interval: 0.02) { cue["peak"] > 2 },
      "a cue cancelled before it moved anything still counted as shown. Nothing was shown — the " \
      "one showing is spent by movement, so the next long list still owes them one"
  end

  private

  def emulate_reduced_motion
    page.driver.browser.page.command("Emulation.setEmulatedMedia",
                                     features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    yield
  ensure
    page.driver.browser.page.command("Emulation.setEmulatedMedia", features: [])
  end
end
