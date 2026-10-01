require "application_system_test_case"

# Picking a rating card's emoji.
#
# The five points wore whatever the Verto's theme chose and no creator could
# say otherwise — an education Verto got 📚 and the client found it "a bit
# archaic", and "if it auto-generated something completely unrelated to
# education, I'll be stuck". One 🎨 on the card, like the select options have:
# it opens the shared emoji picker, the pick fills the whole set (a rating is
# a set, never five different pictures), and Clear goes back to the theme.
#
# The whole path, because every link in it can drop the value silently: the
# picker has to write into the card's own input, the repaint has to reach all
# five points, the card row has to carry the pick for the autosave, and the
# player has to render what was saved.
class RatingEmojiPickerTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Rate", slug: "rate-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Rate", email_address: "rate-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    # "Books and reading" resolves to 📚 — a themed default, so the test can
    # tell "the creator's pick" apart from "whatever the theme would have done".
    @survey = @org.surveys.create!(
      title: "Rate", theme: "Books and reading", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "rating", "cid" => "r1", "text" => "How was school today?",
          "options" => [ "Poor", "Fair", "Good", "Great", "Excellent" ] }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How was school today?"
  end

  def stars
    evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector("[data-card-cid='r1']")
        return {
          glyphs:  Array.from(wrap.querySelectorAll(".rating-star")).map(s => s.textContent.trim()),
          on:      Array.from(wrap.querySelectorAll(".rating-star")).map(s => s.dataset.ratingOn),
          kind:    wrap.querySelector(".rating-wrap").className,
          dataset: wrap.dataset.cardRatingEmoji || ""
        }
      })()
    JS
  end

  def wait_for_stored(expected)
    stored = :unset
    30.times do
      stored = @survey.reload.cards.find { |c| c["cid"] == "r1" }["rating_emoji"]
      break if stored == expected
      sleep 0.5
    end
    stored
  end

  test "the themed glyph is what an untouched card draws" do
    open_editor
    assert_equal [ "📚" ] * 5, stars["glyphs"]
    assert_equal "", stars["dataset"], "an untouched card is carrying a stored emoji — its absence is " \
                                       "what keeps it following the theme"
  end

  test "picking an emoji fills the whole set, survives the save, and reaches the player" do
    open_editor
    find("[data-card-cid='r1'] .rating-style-btn").click
    assert_selector ".emoji-picker-popover", visible: true, wait: 5

    find(".emoji-picker-popover .emoji-picker-search").set("dice")
    find(".emoji-picker-popover .emoji-picker-item[data-emoji='🎲']").click
    assert_no_selector ".emoji-picker-popover", visible: true

    after = stars
    assert_equal [ "🎲" ] * 5, after["glyphs"], "the pick did not reach every point"
    assert_equal [ "🎲" ] * 5, after["on"], "the active glyph is out of step with the resting one"
    assert_includes after["kind"], "rating-kind-emoji"
    assert_equal "🎲", after["dataset"], "the pick was not recorded on the card row, so the autosave will not carry it"

    assert_equal "🎲", wait_for_stored("🎲"), "the pick did not reach the deck"

    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active .rating-star", text: "🎲", count: 5
    assert page.has_no_css?(".preview-card.active .rating-style-slot", visible: :all),
           "the creator's 🎨 reached the respondent"
  end

  test "an emoji pasted from outside the library is offered, and Clear goes back to the theme" do
    open_editor
    find("[data-card-cid='r1'] .rating-style-btn").click
    assert_selector ".emoji-picker-popover", visible: true, wait: 5

    # 🇪🇺 is two regional indicators and in no library row; the search can only
    # match the library's words, so the pasted glyph has to be its own answer.
    find(".emoji-picker-popover .emoji-picker-search").set("🇪🇺")
    find(".emoji-picker-popover .emoji-picker-item[data-emoji='🇪🇺']").click
    assert_equal [ "🇪🇺" ] * 5, stars["glyphs"]
    assert_equal "🇪🇺", wait_for_stored("🇪🇺")

    find("[data-card-cid='r1'] .rating-style-btn").click
    assert_selector ".emoji-picker-popover", visible: true, wait: 5
    find(".emoji-picker-popover .emoji-picker-clear").click

    assert_equal [ "📚" ] * 5, stars["glyphs"], "Clear should hand the set back to the theme"
    assert_equal "", stars["dataset"]
    assert_nil wait_for_stored(nil), "a cleared pick must leave the deck, not store a blank"
  end
end
