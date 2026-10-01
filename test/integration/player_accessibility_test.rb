require "test_helper"

# P2-4. The player's answer options were `<li>` elements with a click handler:
# fine with a mouse or a thumb, unusable with a keyboard or a screen reader.
# They weren't focusable, and nothing announced them as choices or said which
# one was chosen. That covers multiple_choice, select_many, yes_no and both
# grids — most of what a respondent is ever asked — so a keyboard-only or
# screen-reader respondent could not answer at all.
#
# The same partial renders the editor, where those elements hold contenteditable
# option text, so the semantics are applied only outside it. Both halves are
# asserted here: a missing role in the player is the bug, and a stray role in
# the editor would announce edit fields as form controls.
class PlayerAccessibilityTest < ActionDispatch::IntegrationTest
  def setup
    @org = Organisation.create!(name: "O", slug: "a11y-#{SecureRandom.hex(3)}")
  end

  def render_card(card, mode:)
    survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults",
                                  key_insight: "k", default_locale: "en", locales: [ "en" ],
                                  cards: [ card ])
    ApplicationController.render(partial: "shared/card_component",
                                 locals: { card: survey.cards.first, mode: mode,
                                           survey: survey, index: 0 })
  end

  CARDS = {
    "multiple_choice" => { "type" => "multiple_choice", "cid" => "c", "text" => "Pick one",
                           "options" => %w[Red Blue] },
    "select_many"     => { "type" => "select_many", "cid" => "c", "text" => "Pick some",
                           "options" => %w[Red Blue] },
    "yes_no"          => { "type" => "yes_no", "cid" => "c", "text" => "Agree?",
                           "options" => %w[Yes No] },
    "select_one_grid" => { "type" => "select_one_grid", "cid" => "c", "text" => "Pick one",
                           "options" => %w[Red Blue] },
    "select_many_grid" => { "type" => "select_many_grid", "cid" => "c", "text" => "Pick some",
                            "options" => %w[Red Blue] }
  }.freeze

  SINGLE = %w[multiple_choice yes_no select_one_grid].freeze

  test "every choice option is focusable in the player" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      assert_equal 2, html.scan(/tabindex="0"/).size,
                   "#{name}: both options should be reachable by keyboard"
    end
  end

  test "options carry the role that matches the card's selection mode" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      expected = SINGLE.include?(name) ? "radio" : "checkbox"
      assert_equal 2, html.scan(/role="#{expected}"/).size,
                   "#{name}: options should be announced as #{expected}"
    end
  end

  test "options start unchecked and say so" do
    # A radio a screen reader can focus but never hear the state of is barely
    # better than none, so the attribute has to be present from the start —
    # not added on first selection.
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      assert_equal 2, html.scan(/aria-checked="false"/).size, "#{name}"
    end
  end

  test "the option set is announced as one group" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      expected = SINGLE.include?(name) ? "radiogroup" : "group"
      assert_includes html, %(role="#{expected}"), "#{name}: options should form a #{expected}"
    end
  end

  test "options bind a keyboard activator" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      assert_includes html, "keydown->picker#pickOnKey", "#{name}"
    end
  end

  test "the decorative tile is hidden from assistive tech" do
    # The icon tile repeats the option label visually; announcing it would read
    # every choice twice.
    html = render_card(CARDS["multiple_choice"], mode: :player)
    assert_includes html, 'class="choice-list-tile choice-bg-1" aria-hidden="true"'
  end

  # ── The editor must NOT get any of it ───────────────────────────────────

  test "the editor keeps plain list items" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :editor)
      assert_equal 0, html.scan(/role="radio"/).size,    "#{name}: editor options must not be radios"
      assert_equal 0, html.scan(/role="checkbox"/).size, "#{name}: editor options must not be checkboxes"
      assert_equal 0, html.scan(/tabindex="0"/).size,    "#{name}: editor options must not be focusable"
      assert_equal 0, html.scan(/aria-checked/).size,    "#{name}"
    end
  end

  test "the editor does not bind the keyboard activator" do
    # Not shipping the binding at all there is one fewer thing that can misfire
    # while someone is typing an option label.
    CARDS.each do |name, card|
      assert_not_includes render_card(card, mode: :editor), "pickOnKey", "#{name}"
    end
  end

  test "the editor still binds the click picker" do
    # The guard must not have cost the editor its own behaviour.
    CARDS.each do |name, card|
      assert_includes render_card(card, mode: :editor), "click->picker#pick", "#{name}"
    end
  end

  # ── Controls that were already right ────────────────────────────────────

  test "the tap-card actions keep their labels" do
    html = render_card({ "type" => "tap_card", "cid" => "c", "text" => "Statements",
                         "options" => [ "One" ] }, mode: :player)
    assert_equal 3, html.scan(/aria-label=/).size,
                 "the three swipe actions should stay labelled"
  end

  # The strip is 2-6 wide now (TapScales), and the case above keeps passing on a
  # card that never left the default three — so it would not have noticed a
  # fifth response shipping with no accessible name on it.
  test "every response on a wider scale is labelled and reachable" do
    html = render_card({ "type" => "tap_card", "cid" => "c", "text" => "Statements",
                         "options" => [ "One" ],
                         "responses" => TapScales.preset(5) }, mode: :player)

    assert_equal 5, html.scan(/data-tap-response\b/).size
    assert_equal 5, html.scan(/aria-label=/).size, "a pill with no accessible name is unusable by screen reader"
    TapScales.preset(5).each do |r|
      assert_includes html, %(aria-label="#{r["label"]}")
    end
    assert_equal 5, html.scan(/<button type="button" class="rotate-action/).size,
                 "each response must be a real button, not a div with a click handler"
  end

  test "the editor's response strip is editable and not announced as a control" do
    html = render_card({ "type" => "tap_card", "cid" => "c", "text" => "Statements",
                         "options" => [ "One" ],
                         "responses" => TapScales.preset(5) }, mode: :editor)

    assert_equal 5, html.scan(/data-tap-response-label/).size, "each label must hold a caret in the editor"
    refute_match(/<button type="button" class="rotate-action[" ]/, html,
                 "a contenteditable inside a <button> does not reliably take a caret")
  end

  # ── The other answer controls (P2-4, second pass) ───────────────────────

  RANGE  = { "type" => "range", "cid" => "c", "text" => "How confident?",
             "options" => %w[Low Mid High] }.freeze
  RATING = { "type" => "rating", "cid" => "c", "text" => "Rate it",
             "options" => [ "Poor", "Great" ] }.freeze

  test "the range slider is focusable and announces its bounds" do
    # It was drag-only: pointerdown was the sole way to answer, which locks out
    # anyone not using a pointer.
    html = render_card(RANGE, mode: :player)
    assert_includes html, 'role="slider"'
    assert_includes html, 'tabindex="0"'
    assert_includes html, 'aria-valuemin="0"'
    assert_match(/aria-valuemax="\d+"/, html)
    assert_includes html, "aria-orientation="
  end

  test "the range slider binds arrow keys" do
    assert_includes render_card(RANGE, mode: :player), "keydown->slider#key"
  end

  test "rating stars are radios in a group, each individually labelled" do
    html = render_card(RATING, mode: :player)
    assert_equal 5, html.scan(/class="rating-star"/).size
    assert_equal 5, html.scan(/role="radio"/).size
    assert_equal 5, html.scan(/aria-checked="false"/).size
    assert_includes html, 'role="radiogroup"'
    # Individually labelled, so "3 of 5" is announced rather than five
    # identical unlabelled controls.
    (1..5).each { |i| assert_includes html, %(aria-label="#{i} of 5") }
  end

  test "rating stars bind a keyboard activator" do
    assert_includes render_card(RATING, mode: :player), "keydown->rating#pickOnKey"
  end

  test "the star label is translated, not hardcoded" do
    html = render_card(RATING, mode: :player)
    assert_includes html, I18n.t("card.rating_star", number: 3, total: 5)
  end

  test "neither control gets the treatment in the editor" do
    [ RANGE, RATING ].each do |card|
      html = render_card(card, mode: :editor)
      assert_not_includes html, 'role="slider"'
      assert_not_includes html, 'role="radio"'
      assert_not_includes html, "aria-checked"
      # The two controls' own activators. The Other box's Enter-commits binding
      # (keydown->other#keydown) is deliberately in every mode: the Preview
      # overlay is a clone of the editor DOM, and a respondent previewing there
      # presses Enter like any other.
      assert_not_includes html, "keydown->slider#"
      assert_not_includes html, "keydown->rating#"
      assert_equal 0, html.scan(/tabindex="0"/).size
    end
  end

  test "the NPS slider keeps the semantics it already had" do
    # It was the one control already doing this properly, and is the pattern
    # the range slider now follows — so a regression there matters.
    html = render_card({ "type" => "nps", "cid" => "c", "text" => "Recommend?" }, mode: :player)
    assert_includes html, 'role="slider"'
    assert_includes html, 'tabindex="0"'
    assert_includes html, "keydown->nps-slider#key"
  end

  # ── Scenario's answer page (P2-4, the arm that was missed) ──────────────
  # The scenario answer list is a hand-copied multiple_choice block that
  # predates the a11y helpers, so it shipped pointer-only and role-less while
  # every sibling type got the treatment. These are the MC section's
  # assertions, pointed at the copy.

  SCENARIO = { "type" => "scenario", "cid" => "c", "text" => "What would you do?",
               "pages" => [ { "id" => "pg_1", "text" => "Your laptop dies." },
                            { "id" => "pg_2", "text" => "A new one costs $600." } ],
               "options" => [ "Use savings", "Use credit" ] }.freeze

  test "scenario options are radios in a radiogroup, focusable and keyboard operable" do
    html = render_card(SCENARIO, mode: :player)

    assert_includes html, 'role="radiogroup"'
    assert_equal 2, html.scan(/role="radio"/).size
    assert_equal 2, html.scan(/tabindex="0"/).size
    assert_equal 2, html.scan(/aria-checked="false"/).size
    assert_includes html, "keydown->picker#pickOnKey"
  end

  test "scenario option tiles are hidden from assistive tech" do
    html = render_card(SCENARIO, mode: :player)
    assert_equal 2, html.scan(/class="choice-list-tile choice-bg-\d" aria-hidden="true"/).size
  end

  test "the scenario editor keeps plain, non-focusable list items" do
    html = render_card(SCENARIO, mode: :editor)

    assert_equal 0, html.scan(/role="radio"/).size
    assert_equal 0, html.scan(/role="radiogroup"/).size
    assert_equal 0, html.scan(/tabindex="0"/).size
    assert_equal 0, html.scan(/aria-checked/).size
    assert_not_includes html, "pickOnKey"
    assert_includes html, "click->picker#pick", "the guard must not cost the editor its click behaviour"
  end

  # ── Focus management ────────────────────────────────────────────────────

  test "the player moves focus when the card changes" do
    # Honest about what this is: a smoke guard, not a behavioural test. Focus
    # management is JS with no browser-test harness in this repo — which is
    # exactly the gap P2-5 describes — so the real verification was driving
    # Chromium: focus lands on the newly active card when the deck advances,
    # stays on the Next button when a required card refuses to advance, and is
    # not stolen on first load.
    #
    # What this pins is that the call still exists and is still conditional on
    # the card having actually changed, so it can't be quietly dropped.
    js = File.read(Rails.root.join("app/javascript/controllers/player_controller.js"))

    assert_includes js, "_focusCard(card)"
    assert_match(/if \(changed && !first\) this\._focusCard\(card\)/, js,
                 "focus must move only on a real card change, and never on first render")
    assert_match(/tabindex", "-1"/, js,
                 "the card must be programmatically focusable without entering the tab order")
    assert_includes js, "preventScroll: true"
  end
end
