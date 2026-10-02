require "application_system_test_case"

# Show/Hide on every password field in the app.
#
# There are four of them now — the creator's sign-in and sign-up, the
# respondent's sign-in, and the end-of-Verto card — and until this file none of
# them had a test. They share one Stimulus controller, one helper for its four
# labels and one partial for the button, so what is worth holding is that the
# shared thing actually works and actually speaks the reader's language.
#
# The language half is not decoration. hideLabel was never passed from
# anywhere, so every one of these read "Afficher" and then, on the second tap,
# "Hide" — and both aria-labels were English no matter what. The respondent
# card is drawn in 26 languages, which is what made it worth fixing rather than
# noting.
class PasswordVisibilityTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "open_ended", "cid" => "c1", "text" => "Anything else?" }
  ].freeze

  def setup
    super
    @org = Organisation.create!(name: "PW Co", slug: "pw-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Password", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      thankyou_title: "Thanks!", join_prompt_enabled: true
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def play_to_the_end
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active .freeform-wrap", wait: 5
    find("[data-player-target='finishBtn']").click
    assert_selector ".preview-thankyou.active", wait: 8
    open_the_ask
  end

  # The card opens collapsed — its pitch and one button — and the password
  # field is inside the form that button reveals.
  def open_the_ask
    assert_selector "[data-player-target='joinReveal'] .join-btn", wait: 5
    find("[data-player-target='joinReveal'] .join-btn").click
    assert_selector ".join-card .password-field", wait: 5
  end

  # What the field is actually doing, read off the DOM rather than inferred
  # from the button's word.
  def field_state(scope)
    page.evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector('#{scope}')
        const input = wrap.querySelector('input')
        const btn = wrap.querySelector('.password-field__toggle')
        return { type: input.type, value: input.value,
                 label: btn.textContent.trim(),
                 pressed: btn.getAttribute('aria-pressed'),
                 aria: btn.getAttribute('aria-label') }
      })()
    JS
  end

  # ── The end-of-Verto card, which is where this was asked for ─────────────

  test "the card's password can be revealed and hidden again" do
    play_to_the_end
    assert_selector ".join-card .password-field", wait: 5

    find("[data-player-target='joinPassword']").fill_in with: "correct-horse-battery"
    before = field_state(".join-card .password-field")
    assert_equal "password", before["type"], "it must start hidden — this is a signup, not a reveal"
    assert_equal "Show", before["label"]
    assert_equal "false", before["pressed"]
    assert_equal "Show password", before["aria"]

    find(".join-card .password-field__toggle").click
    shown = field_state(".join-card .password-field")
    assert_equal "text", shown["type"], "the characters have to actually become readable"
    assert_equal "correct-horse-battery", shown["value"], "and the typing must survive the toggle"
    assert_equal "Hide", shown["label"]
    assert_equal "true", shown["pressed"]
    assert_equal "Hide password", shown["aria"]

    find(".join-card .password-field__toggle").click
    assert_equal "password", field_state(".join-card .password-field")["type"]
  end

  # It sits in the same row as "Create my account". A button with no explicit
  # type is a submit button, and one there would send a half-typed signup.
  test "revealing the password does not submit the card" do
    play_to_the_end
    assert_selector ".join-card .password-field", wait: 5

    find("[data-player-target='joinEmail']").fill_in with: "someone@example.com"
    find("[data-player-target='joinPassword']").fill_in with: "correct-horse-battery"

    assert_no_difference [ "Player.count", "PlayerSignInLink.count" ] do
      find(".join-card .password-field__toggle").click
      assert_equal "text", field_state(".join-card .password-field")["type"]
    end
    # Still on the card, with the form intact rather than swapped for the
    # "taking you to your account" state.
    assert_selector "[data-player-target='joinAsk']", visible: true
  end

  # ── The respondent's sign-in page ────────────────────────────────────────

  test "the respondent sign-in field reveals too" do
    visit new_player_session_path
    assert_selector ".password-field", wait: 5

    find("input[type=password]").fill_in with: "correct-horse-battery"
    find(".password-field__toggle").click

    state = field_state(".password-field")
    assert_equal "text", state["type"]
    assert_equal "correct-horse-battery", state["value"]
  end

  # ── The creator's, which had the controller first and the labels never ───

  test "the creator sign-in field reveals too" do
    visit new_session_path
    assert_selector ".password-field", wait: 5

    find("input[type=password]").fill_in with: "verylongpassword"
    find(".password-field__toggle").click
    assert_equal "text", field_state(".password-field")["type"]
  end

  # The bug this change fixed, held where it broke: the second label. A reader
  # who taps Show in French got "Hide" back, because hideLabel was never passed
  # and the controller's English default won.
  test "both labels and both aria-labels are in the reader's language" do
    visit new_player_session_path(locale: "fr")
    assert_selector ".password-field", wait: 5
    # The aria-label is the controller's to set; read it before the controller
    # connects and it is nil (gate run, 2 October).
    wait_for_stimulus

    before = field_state(".password-field")
    assert_equal I18n.t("auth.show", locale: :fr), before["label"]
    assert_equal I18n.t("auth.show_password", locale: :fr), before["aria"]

    find(".password-field__toggle").click
    after = field_state(".password-field")
    assert_equal I18n.t("auth.hide", locale: :fr), after["label"],
                 "the SECOND label is the one that was English for everybody"
    assert_equal I18n.t("auth.hide_password", locale: :fr), after["aria"]
    # And the French words are really different from the English ones, or this
    # test would pass on a page that never localised anything.
    refute_equal I18n.t("auth.hide"), after["label"]
  end

  # An Arabic or Hebrew field starts on the right, so a physically-right toggle
  # sits on top of the first characters typed instead of after the last.
  test "the toggle follows the writing direction" do
    ltr = nil
    visit new_player_session_path(locale: "en")
    assert_selector ".password-field", wait: 5
    ltr = toggle_offset

    visit new_player_session_path(locale: "ar")
    assert_selector ".password-field", wait: 5
    rtl = toggle_offset

    assert_operator ltr, :>, 0.5, "in English the toggle sits in the right-hand half of the field"
    assert_operator rtl, :<, 0.5, "in Arabic it has to move to the left-hand half"
  end

  # The reveal is only worth anything if you can read what it revealed. The
  # toggle floats over the end of the input, so the input reserves padding for
  # it — and that reservation was sized for "Show"/"Hide" while the label is
  # drawn in 26 languages. Indonesian's "Sembunyikan" is eleven characters, and
  # a password long enough to be worth checking ran underneath the button that
  # revealed it.
  #
  # Measured against the real labels rather than asserted as a number, so the
  # next language added is checked by the same rule.
  test "the field reserves room for the longest label in every language" do
    worst = LOCALES_WITH_LONGEST_LABELS
    assert_operator worst.size, :>=, 2, "this test proves nothing without a spread of labels"

    # Both shapes of the field: the full-width one on /you/sign-in, and the
    # cramped one on the card, which shares its row with "Create my account"
    # and has a smaller toggle to suit. They reserve different amounts, so
    # checking one proves nothing about the other.
    surfaces = {
      "/you/sign-in" => ->(code) { visit new_player_session_path(locale: code) },
      "the card"     => ->(code) { visit_card(locale: code) }
    }

    worst.product(surfaces.to_a).each do |code, (where, go)|
      go.call(code)
      assert_selector ".password-field", wait: 8

      # Both states: the label changes when it is pressed, and in several
      # languages the HIDE word is the longer of the two.
      2.times do |i|
        room = page.evaluate_script(<<~JS)
          (() => {
            const wrap = document.querySelector('.password-field')
            const input = wrap.querySelector('input')
            const btn = wrap.querySelector('.password-field__toggle')
            const cs = getComputedStyle(input), bs = getComputedStyle(btn)
            const b = btn.getBoundingClientRect()
            return { reserved: parseFloat(cs.paddingInlineEnd),
                     needed: b.width + parseFloat(bs.insetInlineEnd || 0),
                     label: btn.textContent.trim() }
          })()
        JS

        assert_operator room["reserved"], :>=, room["needed"],
                        "#{where}, #{code}: the #{i.zero? ? 'show' : 'hide'} label " \
                        "#{room['label'].inspect} needs #{room['needed'].round}px but the input " \
                        "reserves only #{room['reserved'].round}px — the end of the password " \
                        "renders under the button that just revealed it"
        find(".password-field__toggle").click
      end
    end
  end

  # The end-of-Verto card in a given language. The Verto itself is English —
  # the toggle's words come from `auth`, which resolve_locale serves from
  # ?locale= whatever the deck is written in.
  def visit_card(locale:)
    visit "/play/#{@survey.publish_token}?locale=#{locale}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active .freeform-wrap", wait: 8
    find("[data-player-target='finishBtn']").click
    open_the_ask
  end

  # The locales whose Show/Hide words are longest, read from the files rather
  # than listed here: a language added tomorrow is covered without anyone
  # remembering to add it.
  LOCALES_WITH_LONGEST_LABELS = Dir[Rails.root.join("config/locales/*.yml")].filter_map { |f|
    code = File.basename(f, ".yml")
    auth = (YAML.load_file(f)[code] || {})["auth"]
    next unless auth && auth["show"] && auth["hide"]

    [ code, [ auth["show"].length, auth["hide"].length ].max ]
  }.max_by(3) { |_, len| len }.map(&:first).freeze

  # Where the toggle's centre sits across the field, 0 (start) to 1 (end).
  def toggle_offset
    page.evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector('.password-field')
        const btn = wrap.querySelector('.password-field__toggle')
        const w = wrap.getBoundingClientRect(), b = btn.getBoundingClientRect()
        return ((b.left + b.width / 2) - w.left) / w.width
      })()
    JS
  end
end
