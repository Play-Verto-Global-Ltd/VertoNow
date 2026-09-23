require "application_system_test_case"

# The editor's Preview overlay is a DEEP CLONE of the editor's live card DOM
# with the editor-only chrome stripped by selector — so every affordance added
# to a card reaches Preview by default and stays there until someone remembers
# to add it to that list. tap_preview_chrome_test made that point for the tap
# card. This is the sweep that followed ("some of the editor look and feel is
# bleeding into preview, run an audit"), and it covers the three shapes the
# leak comes in:
#
#   1. A creator CTA that is not inert. `media-picker` is bound on the editor
#      root, an ancestor of this overlay, so a cloned "Background" or
#      "Reposition" opened the creator's media modal on top of the preview they
#      were checking.
#   2. A creator CONTROL that writes to the deck. The open-ended card's "Answer
#      length" <select> carries change->survey-editor#markDirty — changing it
#      while previewing as a respondent autosaved a new character limit.
#   3. Editor markup that stands IN PLACE of respondent markup, which a flat
#      remove cannot fix. The scenario book's pager is the tap pager's twin: the
#      editor draws a full-width "Next page ›" with a dot strip floating above
#      it, the player draws one ‹ · · · › capsule.
#
# Preview is what a Verto gets checked against before it ships, so a wrong
# Preview is the wrong answer to "is this ready?".
class PreviewChromeAuditTest < ApplicationSystemTestCase
  IMG = "https://images.pexels.com/photos/1/pexels-photo-1.jpeg".freeze

  def setup
    super
    @org  = Organisation.create!(name: "Aud", slug: "aud-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Aud", email_address: "aud-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Aud", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "multiple_choice", "cid" => "pic", "text" => "Which one?",
          "options" => %w[Alpha Bravo], "image" => IMG },
        { "type" => "open_ended", "cid" => "txt", "text" => "Tell us more" },
        { "type" => "scenario", "cid" => "sc", "text" => "A choice",
          "pages" => [ { "id" => "p1", "text" => "Page one" },
                       { "id" => "p2", "text" => "Page two" } ],
          "options" => %w[Stay Go] }
      ]
    )
  end

  def open_preview
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Which one?"

    # Not [data-action*='publish-panel#open'] — that substring also matches the
    # Design button's `publish-panel#openDesign`.
    find("button[data-action='click->publish-panel#open click->editor-panel#open']").click
    click_button "▶ Preview Verto"
    assert_selector ".preview-overlay .preview-card.active", wait: 5
  end

  # The overlay opens on card 1 and every other preview card is built but
  # hidden, so the book has to be WALKED to. Counting clicks would be brittle:
  # the deck's own Next is intercepted by a scenario card's page turns
  # (preview-verto#_scenarioTurn), so "three cards along" is not three clicks.
  def walk_to_book
    8.times do
      break if page.has_css?(".preview-overlay .preview-card.active .book-wrap", wait: 1)
      find("[data-preview-verto-target='nextBtn']").click
    end
    assert_selector ".preview-overlay .preview-card.active .book-wrap", wait: 5
  end

  test "no creator CTA from the card panel survives into the preview" do
    open_preview

    # .add-bg-fab is the class both "Background" and "Reposition" carry; the row
    # is the box they sat in, absolutely positioned over the panel.
    [ ".add-bg-fab", ".card-bg-fab", ".header-bg-fab", ".media-adjust-fab",
      ".split-left-cta-row", ".card-media-dock", ".tap-card-adjust-btn" ].each do |sel|
      assert page.has_no_css?(".preview-overlay #{sel}", visible: :all),
             "#{sel} reached the preview clone — `media-picker` is bound on the editor root, so " \
             "this one is live: it opens the creator's media modal from inside a respondent view"
    end
    assert page.has_no_css?('.preview-overlay [data-action*="media-picker#"]', visible: :all),
           "something in Preview still opens the media picker on click"
  end

  test "the creator's answer-length control does not reach the preview" do
    open_preview

    assert page.has_no_css?(".preview-overlay .freeform-limit-row", visible: :all),
           "the open-ended card's 'Answer length' select is in Preview. It is not decoration — " \
           "its <select> carries change->survey-editor#markDirty, so changing it while " \
           "previewing as a respondent autosaves a new character limit onto the deck."
    assert page.has_no_css?(".preview-overlay [data-char-limit]", visible: :all),
           "the limit select survived under a different selector"
  end

  test "the hidden animation apply-paths do not reach the preview" do
    open_preview

    [ ".range-theme-picker", ".nps-shape-picker" ].each do |sel|
      assert page.has_no_css?(".preview-overlay #{sel}", visible: :all),
             "#{sel} reached the preview clone. It ships `hidden`, which is a state rather than " \
             "a deletion — and one of the two shipped without its `hidden` for a while, which " \
             "is exactly how a hidden thing becomes a visible one."
    end
  end

  # Swap, don't strip: removing the editor's pager on its own would leave a
  # previewed scenario with no way forward at all.
  test "the preview shows the respondent's book pager, not the creator's" do
    open_preview
    walk_to_book

    pager = evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-overlay .preview-card.active")
        const row  = card.querySelector(".book-nav-row")
        return {
          editorNext: !!card.querySelector(".next-btn"),
          chevrons:   row ? row.querySelectorAll(".book-chevron").length : 0,
          dotsInRow:  row ? row.querySelectorAll(".book-dots").length : 0,
          strayDots:  Array.from(card.querySelectorAll(".book-dots"))
                           .filter(d => !d.closest(".book-nav-row")).length,
          nextWired:  !!(row && row.querySelector("[data-scenario-target='nextBtn']"))
        }
      })()
    JS

    refute pager["editorNext"],
           "the creator's full-width 'Next page ›' is in Preview — the player draws a chevron"
    assert_equal 2, pager["chevrons"],
                 "the previewed pager is not the player's ‹ · · · › capsule (found " \
                 "#{pager['chevrons']} chevrons)"
    assert_equal 1, pager["dotsInRow"],
                 "the dots are not between the two chevrons, which is the whole shape of the " \
                 "player's pager"
    assert_equal 0, pager["strayDots"],
                 "the editor's separate dot strip is still floating above the row"
    assert pager["nextWired"],
           "the swapped-in chevron carries no data-scenario-target, so it is a picture of a " \
           "pager rather than one — the same failure swapping the tap pager was written to avoid"
  end

  # The page has to actually turn. A pager that looks right and does nothing is
  # a worse preview than one that looks wrong.
  test "the previewed book pager turns the page" do
    open_preview
    walk_to_book

    first = evaluate_script(<<~JS)
      document.querySelector(".preview-overlay .preview-card.active .book-page.is-active .book-page-text")?.textContent?.trim()
        || document.querySelector(".preview-overlay .preview-card.active .book-page-text").textContent.trim()
    JS
    find(".preview-overlay .preview-card.active .book-nav-row [data-scenario-target='nextBtn']").click

    assert_selector ".preview-overlay .preview-card.active .book-wrap", wait: 3
    after = evaluate_script(<<~JS)
      document.querySelector(".preview-overlay .preview-card.active .book-page.is-active .book-page-text")?.textContent?.trim()
        || ""
    JS
    refute_equal first, after, "the previewed pager's chevron did not turn the page"
  end
end
