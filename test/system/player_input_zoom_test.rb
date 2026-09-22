require "application_system_test_case"

# Below 16 CSS px, iOS Safari zooms the page when a field takes focus — and
# leaves it zoomed. On a card-per-screen layout that means the question scrolls
# off and the footer goes with it, so a respondent finishes the Verto with the
# page stuck at 1.3x and the Next button somewhere off the right edge.
#
# TWO rules defend this line and they defend different things, which is the
# trap worth writing a test about. `--play-input-fs` is a hand-maintained list
# of CLASSES, and it exists for the textarea-flavoured controls: `textarea` is
# a bare element selector (0,0,1) and loses to any class that names it. The
# INPUTS are carried by a blanket `input[type=...]` rule in the mobile block —
# (0,1,1), so it silently outranks a field's own smaller font-size and no list
# needs updating at all.
#
# Reading either rule alone gives the wrong answer about the other. The
# respondent-code field (15px) looks broken in source and is fine in a
# browser; remove the blanket rule and it drops straight through.
#
# So this checks neither list. It walks the deck, collects every text control a
# respondent can actually focus, and asserts the floor on the COMPUTED value —
# which is the only place the two rules resolve against each other, and means
# an input added next year is covered without anyone remembering this file
# exists.
#
# `max(1rem, 16px)` rather than a flat 16px is deliberate and also pinned here
# (see the shrunk-text test): the threshold is 16 CSS PX, so a respondent who
# has made their browser text smaller gets the zoom handed straight back by a
# hardcoded value.
class PlayerInputZoomTest < ApplicationSystemTestCase
  IOS_ZOOM_FLOOR = 16
  PHONE   = [ 393, 852 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  # One card per text-input shape the player can render. The `input` variants
  # are the open_ended flavours (_card_component.html.erb:757-785); allow_other
  # puts a free-text box on a choice card; respondent_code_enabled adds the
  # screen that runs before any card at all.
  CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "open_ended", "cid" => "o1", "text" => "Tell us more" },
    { "type" => "open_ended", "cid" => "o2", "text" => "When?", "input" => "month" },
    { "type" => "open_ended", "cid" => "o3", "text" => "Born?", "input" => "date" },
    { "type" => "open_ended", "cid" => "o4", "text" => "Where?", "input" => "location" },
    { "type" => "multiple_choice", "cid" => "m1", "text" => "Pick", "allow_other" => true,
      "options" => [ "A", "B" ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "zoom-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Zoom", theme: "T", audience_age: "all",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    # Off by default, and adds a text input a respondent must type in.
    @survey.update_columns(respondent_code_enabled: true,
                           publish_token: SecureRandom.hex(8),
                           published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  # Every text control currently in the DOM, with its computed size. Reads the
  # whole overlay rather than the active card: the "+ Other" panel is hidden
  # until opened, and a font-size does not need the element to be visible to
  # be wrong.
  def input_sizes
    page.evaluate_script(<<~JS)
      (() => {
        const TEXTY = /^(?:text|search|email|tel|url|number|password|date)$/
        const els = Array.from(document.querySelectorAll(".preview-overlay input, .preview-overlay textarea"))
          .filter(el => el.tagName === "TEXTAREA" || TEXTY.test(el.type || "text"))
        return els.map(el => ({
          cls:  el.className || el.type,
          size: parseFloat(getComputedStyle(el).fontSize)
        }))
      })()
    JS
  end

  def open_player
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
  end

  def assert_all_above_floor(found, context)
    assert found.any?, "no text controls found #{context} — the walk is not reaching them"
    under = found.reject { |f| f["size"] >= IOS_ZOOM_FLOOR }
    assert_empty under,
                 "#{context}: #{under.map { |u| "#{u["cls"]} at #{u["size"]}px" }.join(", ")} — " \
                 "under #{IOS_ZOOM_FLOOR}px iOS Safari zooms on focus and stays zoomed.\n" \
                 "For an <input>, the fix is almost never the field's own rule: the blanket " \
                 "`input[type=...] { font-size: max(1rem, 16px) }` in the mobile block is " \
                 "(0,1,1) and already outranks any bare class, so check that rule still exists " \
                 "and still lists this input's type. A <textarea> is the exception — `textarea` " \
                 "is (0,0,1) and loses to its own class, which is what --play-input-fs is for."
  end

  test "every text control on the respondent-code screen clears the iOS zoom floor" do
    open_player
    # This screen runs BEFORE the first card, so it is the one input that can
    # zoom the page before a respondent has seen a single question.
    assert_selector ".respondent-code-input", wait: 5
    assert_all_above_floor(input_sizes, "the respondent-code screen")
  end

  test "every text control in the deck clears the iOS zoom floor" do
    open_player
    fill_in_respondent_code
    agree_to_consent_gate

    seen = []
    8.times do
      seen.concat(input_sizes)
      break unless has_button?("Next", wait: 2)
      click_button "Next"
      sleep 0.4
    end

    assert_all_above_floor(seen.uniq { |f| f["cls"] }, "walking the deck")
  end

  def fill_in_respondent_code
    return unless has_selector?(".respondent-code-input", wait: 3)
    find(".respondent-code-input").fill_in with: "abc123"
    find(".play-consent-agree").click
    sleep 0.5
  end

  # The reason the token is max(1rem, 16px) and not 16px: a respondent who has
  # made their browser text SMALLER must not have the zoom handed back. A flat
  # 16px passes the test above and fails this one.
  test "the floor survives a respondent shrinking their browser text" do
    open_player
    page.execute_script("document.documentElement.style.fontSize = '12px'")
    sleep 0.2

    assert_all_above_floor(input_sizes, "at a 12px root font size")
  end
end
