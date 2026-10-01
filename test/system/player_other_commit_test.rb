require "application_system_test_case"

# The "Other" write-in, as a respondent meets it.
#
# The box used to be a textarea with no way out: Enter added a line, nothing
# said the answer was taken, the typed words never showed among the answers,
# and tapping "＋ Other" again threw them away. Worse, typing replaced the
# ticks — a respondent who picked two and wrote a third sent only the third.
# Now Enter, the Add button and tapping away all commit; the words fold into a
# selected-looking row under the options; the row re-opens for editing and its
# × clears; and the picks travel with the write-in.
#
# Every one of these is browser behaviour (other_controller.js) and most of
# them are about focus and the order events arrive in, which is exactly what a
# unit of Ruby cannot see.
class PlayerOtherCommitTest < ApplicationSystemTestCase
  OPTIONS = %w[Jobs Housing Climate].freeze

  def setup
    super
    @org = Organisation.create!(name: "Other", slug: "oth-#{SecureRandom.hex(3)}")
  end

  # ── Commit ────────────────────────────────────────────────────────────────

  test "Enter commits the write-in into a row under the options, and never a new line" do
    play(survey_with(type: "multiple_choice"))

    open_other
    # The list stays live while the box is open — it used to dim and go inert,
    # which is what made "tick two and write a third" impossible.
    assert_equal "1", computed(".preview-card.active .mt-2", "opacity")
    refute_equal "none", computed(".preview-card.active .mt-2", "pointerEvents")

    type_other "Teal"
    press_keys(:Enter)

    assert_committed "Teal"
    assert_equal "Teal", textarea.value, "the textarea is the answer; the row only shows it"
    refute_includes textarea.value, "\n", "Enter must commit, not break the line"
  end

  test "the Add button commits without losing the text to the blur it would cause" do
    play(survey_with(type: "multiple_choice"))

    open_other
    type_other "Teal"
    find(".preview-card.active .other-add-btn").click

    assert_committed "Teal"
  end

  test "tapping an option while the box is open commits the words AND lands the tap" do
    play(survey_with(type: "multiple_choice"))

    open_other
    type_other "Teal"
    pick "Jobs"

    assert_committed "Teal"
    assert_equal "true", item("Jobs")[:"data-selected"],
                 "folding the panel moves the list; the pick must not be lost to that"
  end

  test "losing focus with no tap at all still commits" do
    play(survey_with(type: "multiple_choice"))

    open_other
    type_other "Teal"
    # Tab away, or the phone keyboard's Done: a blur that no click follows.
    page.execute_script("document.querySelector('.preview-card.active .other-textarea').blur()")

    assert_committed "Teal"
  end

  test "an empty commit goes back to the CTA rather than recording a blank row" do
    play(survey_with(type: "multiple_choice"))

    open_other
    press_keys(:Enter)

    assert_idle
  end

  # ── Edit and clear ────────────────────────────────────────────────────────

  test "the row re-opens the box with the words intact, and × takes them away" do
    play(survey_with(type: "multiple_choice"))

    open_other
    type_other "Teal"
    press_keys(:Enter)
    assert_committed "Teal"

    find(".preview-card.active .other-chip-main").click
    assert_selector ".preview-card.active .other-panel:not([hidden])"
    assert_equal "Teal", textarea.value
    assert_equal 4, evaluate_script("document.querySelector('.preview-card.active .other-textarea').selectionStart"),
                 "editing resumes at the end of what was written"

    press_keys(:Enter)
    assert_committed "Teal"

    find(".preview-card.active .other-chip-clear").click
    assert_idle
    assert_equal "", textarea.value
    assert_selector ".preview-card.active .freeform-counter",
                    text: "0/#{Survey::DEFAULT_FREE_TEXT_LIMIT} #{I18n.t('card.characters')}", visible: :all
  end

  # ── What is sent ──────────────────────────────────────────────────────────

  test "a pick and a write-in are both recorded, on a single-choice card" do
    survey = survey_with(type: "multiple_choice")
    play(survey)

    pick "Jobs"
    open_other
    type_other "Teal"
    press_keys(:Enter)
    assert_committed "Teal"

    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8

    stored = stored_answer(survey)
    assert_equal({ "type" => "multiple_choice", "value" => "Jobs", "other" => "Teal" },
                 stored.slice("type", "value", "other"),
                 "the write-in used to null the pick on its way out")
  end

  test "the row is not a tick: it never counts toward the cap" do
    survey = survey_with(type: "select_many", max_choices: 2)
    play(survey)

    open_other
    type_other "Teal"
    press_keys(:Enter)
    assert_committed "Teal"

    pick "Jobs"
    pick "Housing"
    assert_selector ".preview-card.active .choice-list[data-at-cap='true']"
    assert_no_selector ".preview-card.active .other-chip[data-picker-target]", visible: :all
    assert_equal 2, evaluate_script("document.querySelectorAll(\".preview-card.active [data-picker-target='item'][data-selected='true']\").length")

    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8

    stored = stored_answer(survey)
    assert_equal %w[Housing Jobs], Array(stored["value"]).sort
    assert_equal "Teal", stored["other"]
  end

  # ── A phone ───────────────────────────────────────────────────────────────

  test "the same flow on a phone" do
    survey = survey_with(type: "multiple_choice")
    with_viewport(393, 852) do
      play(survey)

      open_other
      type_other "Teal"
      press_keys(:Enter)
      assert_committed "Teal"

      pick "Housing"
      assert_equal "true", item("Housing")[:"data-selected"]

      chip = find(".preview-card.active .other-chip-main")
      settle_box(chip)
      chip.click
      assert_selector ".preview-card.active .other-panel:not([hidden])"
      type_other " and more"
      find(".preview-card.active .other-add-btn").click
      assert_committed "Teal and more"

      find(".preview-btn-finish").click
      assert_selector ".preview-thankyou.active", wait: 8
    end

    stored = stored_answer(survey)
    assert_equal "Housing", stored["value"]
    assert_equal "Teal and more", stored["other"]
  end

  private

  def survey_with(type:, max_choices: nil)
    card = { "type" => type, "cid" => "q1", "text" => "What is on your mind most right now?",
             "options" => OPTIONS.dup, "allow_other" => true }
    card["max_choices"] = max_choices if max_choices
    survey = @org.surveys.create!(
      title: "Minds", theme: "Community", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: [ card ]
    )
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  def play(survey)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
  end

  def item(label)
    find(".preview-card.active .choice-list-item", text: label)
  end

  def pick(label)
    item(label).click
  end

  def open_other
    find(".preview-card.active .other-cta-btn").click
    assert_selector ".preview-card.active .other-panel:not([hidden])"
  end

  def textarea
    find(".preview-card.active .other-textarea", visible: :all)
  end

  # Types at the focused box. The CTA's open() focused it; `set` on a hidden-
  # by-fold box would miss, so this always goes through the visible one.
  def type_other(text)
    box = find(".preview-card.active .other-textarea")
    box.send_keys(text)
  end

  def assert_committed(text)
    assert_selector ".preview-card.active .other-chip:not([hidden]) .other-chip-text", text: text
    assert_no_selector ".preview-card.active .other-panel:not([hidden])"
    assert_no_selector ".preview-card.active .other-cta-btn:not([hidden])"
  end

  def assert_idle
    assert_selector ".preview-card.active .other-cta-btn:not([hidden])"
    assert_no_selector ".preview-card.active .other-panel:not([hidden])"
    assert_no_selector ".preview-card.active .other-chip:not([hidden])"
  end

  def computed(selector, property)
    evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).#{property}")
  end

  def stored_answer(survey)
    answer = nil
    wait_until { answer = survey.responses.reload.first&.answers&.dig("0"); answer.present? }
    answer
  end
end
