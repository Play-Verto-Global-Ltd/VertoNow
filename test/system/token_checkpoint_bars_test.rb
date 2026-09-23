require "application_system_test_case"

# The Points Checkpoint, the milestone screen partway through a tokenised Verto
# that shows what a player has collected so far.
#
# It used to be four numbers in a column. Four totals within a few points of
# each other read as a table you have to compare by eye, which is the one
# question the screen exists to answer — so each row now carries a bar, drawn
# against whichever token is ahead. There is no ceiling to draw against
# instead: awards are unbounded running sums and can go negative.
#
# Only a browser can pin any of this. The card is the one type whose whole body
# is built client-side, from totals the player has been accumulating as it goes.
class TokenCheckpointBarsTest < ApplicationSystemTestCase
  TYPES = [
    { "id" => "gold",  "name" => "Coins", "icon" => "🪙" },
    { "id" => "lives", "name" => "Lives", "icon" => "❤️" }
  ].freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "tcb-#{SecureRandom.hex(3)}")
  end

  # `tokens` maps each option to what picking it is worth. `note` is the
  # checkpoint card's own body copy and `result_note` the Verto-level line
  # above the final tally — the two halves of the explainer, stored apart
  # because only the card's is something SurveyTranslator can translate.
  def deck!(tokens, note: nil, result_note: nil)
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "cid" => "q1", "text" => "First pick",
          "options" => tokens.keys, "tokens" => tokens },
        { "type" => "token_checkpoint", "cid" => "cp", "text" => "Here is how it adds up",
          "description" => note }.compact
      ],
      tokenisation_enabled: true, token_types: TYPES, token_amounts_shown: true,
      token_result_note: result_note,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def reach_checkpoint!(pick)
    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    find(".preview-card.active .pick-item", text: pick).click
    find(".preview-btn-next").click
    assert_text "Here is how it adds up"
    assert_selector ".token-checkpoint-row", count: 2
    settle_fills!
  end

  # The fill animates from zero to its share, so a box read the moment the card
  # arrives is a frame of the transition rather than the answer. Settle the
  # FILLS — the track never moves, so settling that one proves nothing.
  def settle_fills!
    page.all(".preview-card.active .token-checkpoint-fill", visible: :all).each { |f| settle_box(f) }
  end

  def fill_widths
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".preview-card.active .token-checkpoint-fill"))
           .map(f => f.getBoundingClientRect().width)
    JS
  end

  test "the leading token fills the bar and the rest are drawn against it" do
    deck!({ "Both" => { "gold" => 10, "lives" => 5 } })
    reach_checkpoint!("Both")

    track = page.evaluate_script(<<~JS)
      document.querySelector(".preview-card.active .token-checkpoint-track").getBoundingClientRect().width
    JS
    gold, lives = fill_widths

    assert_in_delta track, gold, 2, "the token that is ahead gets the whole bar"
    assert_in_delta track / 2.0, lives, 2, "half the points is half the bar"
  end

  test "a token you can lose is drawn as a loss, by how much was lost" do
    deck!({ "Costly" => { "gold" => 4, "lives" => -2 } })
    reach_checkpoint!("Costly")

    assert_selector ".token-checkpoint-fill.is-loss", count: 1
    gold, lives = fill_widths
    assert_in_delta gold / 2.0, lives, 2, "the bar follows the size of the loss, not its sign"
    assert_selector ".token-checkpoint-amount", text: "-2"
  end

  test "everything at zero draws empty tracks rather than dividing by zero" do
    deck!({ "Nothing" => {} })
    reach_checkpoint!("Nothing")

    assert_selector ".token-checkpoint-track", count: 2, visible: :all
    assert_equal [ 0.0, 0.0 ], fill_widths.map { |w| w.round(1) }
    assert_selector ".token-checkpoint-amount", text: "0", count: 2
  end

  # _update() lands on the checkpoint again every time it becomes the active
  # card, backwards included. Rebuilding it unconditionally replayed the fill
  # transition, so stepping back over the card made the bars twitch.
  test "stepping back onto the checkpoint does not redraw the bars" do
    deck!({ "Both" => { "gold" => 10, "lives" => 5 } })
    reach_checkpoint!("Both")
    before = fill_widths
    stamp  = page.evaluate_script("document.querySelector('.preview-card.active .token-checkpoint-body').dataset.totals")

    find(".preview-btn-back").click
    assert_text "First pick"
    find(".preview-btn-next").click
    assert_text "Here is how it adds up"
    settle_fills!

    assert_equal stamp,
                 page.evaluate_script("document.querySelector('.preview-card.active .token-checkpoint-body').dataset.totals")
    # Sub-pixel layout jitter can shift a box by a fraction; a bar that had
    # restarted would be back at zero, or somewhere on its way up from it.
    before.zip(fill_widths).each do |was, now|
      assert_in_delta was, now, 1,
                      "the bars were already right; coming back must not restart them"
    end
  end

  test "the bars are decorative — the number beside them is the announcement" do
    deck!({ "Both" => { "gold" => 10, "lives" => 5 } })
    reach_checkpoint!("Both")
    assert_selector ".token-checkpoint-track[aria-hidden='true']", count: 2, visible: :all
  end

  # ── The words beside the numbers ──────────────────────────────────────────
  #
  # "The scores seem to be just numbers, so I wonder if we should consider
  # whether they need a bit more context or explanation." Both halves are
  # creator copy and both render as a pill; neither has a default, because what
  # a token is counting is the creator's to say and a house sentence about
  # points in general would be worse than the bare numbers it replaced.

  test "the checkpoint's explainer is a pill, above the first bar" do
    deck!({ "Both" => { "gold" => 10, "lives" => 5 } },
          note: "These are trade-offs, not a score. Nobody gets both going up at once.")
    reach_checkpoint!("Both")

    settle_box(find(".preview-card.active .q-subtitle"))
    pill = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const sub  = card.querySelector(".q-subtitle")
        const row  = card.querySelector(".token-checkpoint-row")
        const cs   = getComputedStyle(sub)
        const s = sub.getBoundingClientRect(), r = row.getBoundingClientRect()
        return {
          clearOfBars: Math.round(r.top - s.bottom),
          radius:      parseFloat(cs.borderRadius),
          tinted:      cs.backgroundColor !== "rgba(0, 0, 0, 0)",
          bordered:    parseFloat(cs.borderTopWidth) > 0,
          narrower:    s.width < card.getBoundingClientRect().width
        }
      })()
    JS

    assert_text "These are trade-offs, not a score. Nobody gets both going up at once."
    assert_operator pill["clearOfBars"], :>, 0,
                    "the explainer is not above the bars. It explains them — under them it is a " \
                    "footnote to a thing already read"
    assert_operator pill["radius"], :>=, 20,
                    "drawn as a plain subtitle, not a pill. The pill is what makes it read as a " \
                    "note about the scores rather than as more card copy"
    assert pill["tinted"], "no tint behind it — the pill shares the bars' amber so the card reads as one thing"
    assert pill["bordered"], "no border — same reason"
    assert pill["narrower"], "the pill ran the full width of the card, which is a paragraph, not a pill"
  end

  test "a checkpoint with nothing to say draws no empty pill" do
    deck!({ "Both" => { "gold" => 10, "lives" => 5 } })
    reach_checkpoint!("Both")

    assert page.has_no_selector?(".preview-card.active .q-subtitle"),
           "an explainer the creator never wrote was drawn anyway. Blank means the card is " \
           "exactly what it was before this existed"
  end

  test "the final tally carries the creator's sentence above it" do
    deck!({ "Both" => { "gold" => 10, "lives" => 5 } },
          result_note: "Your totals are the trade-offs you made, not how well you did.")
    reach_checkpoint!("Both")
    find(".preview-btn-finish").click

    assert_selector ".token-result-card", wait: 10
    assert_selector ".token-result-note",
                    text: "Your totals are the trade-offs you made, not how well you did."

    order = page.evaluate_script(<<~JS)
      (() => {
        const card  = document.querySelector(".token-result-card")
        const note  = card.querySelector(".token-result-note")
        const label = card.querySelector(".token-result-label")
        return Math.round(label.getBoundingClientRect().top - note.getBoundingClientRect().bottom)
      })()
    JS

    assert_operator order, :>, 0,
                    "the sentence landed below YOU COLLECTED. It is the frame for the numbers, " \
                    "so it has to be read before them"
  end

  test "no sentence, and the tally is exactly the numbers it always was" do
    deck!({ "Both" => { "gold" => 10, "lives" => 5 } })
    reach_checkpoint!("Both")
    find(".preview-btn-finish").click

    assert_selector ".token-result-card", wait: 10
    assert page.has_no_selector?(".token-result-note"),
           "an empty pill on the end screen. _renderTokenScore must draw nothing at all when the " \
           "creator wrote nothing"
  end
end
