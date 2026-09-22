require "application_system_test_case"

# The "View all answers" panel on a freeform result card
# (freeform_answers_controller): opens with the first page from
# SurveyTextAnswersController, loads the next on demand, asks the server for
# a search rather than filtering what happens to be loaded, and closes on
# Escape. The endpoint's own contract is covered in
# test/integration/freeform_answers_test.rb; this is the browser half.
class FreeformAnswersModalTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "ffm-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ffm-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "member")
    @survey = @org.surveys.create!(
      title: "FFM", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "open_ended", "text" => "What stood out?" },
               { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ]
    )
    # Every third respondent wrote an "Other" in on the Colour card — 44 of
    # them — for the write-in half of the panel below.
    130.times do |i|
      answers = { "0" => { "type" => "open_ended", "value" => "Answer #{i}" } }
      answers["1"] = { "type" => "multiple_choice", "value" => "Other", "other" => "Other #{i}" } if (i % 3).zero?
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
        created_at: (200 - i).minutes.ago, answers: answers
      )
    end
  end

  def open_panel
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    click_button "View all answers (130) →"
    assert_selector "[data-freeform-answers-target='modal']:not(.hidden)", wait: 5
    assert_selector ".freeform-item", count: 100, wait: 10
  end

  test "opens on the newest page, loads more, and closes on Escape" do
    open_panel

    within("[data-freeform-answers-target='modal']") do
      assert_text "What stood out?"
      assert_text "Showing 100 of 130"
      assert_equal "Answer 129", first(".freeform-item__text").text
      assert_selector ".freeform-item__when", minimum: 1

      click_button "Load more"
      assert_selector ".freeform-item", count: 130, wait: 10
      assert_text "Showing 130 of 130"
      assert_no_button "Load more", wait: 2
    end
  end

  test "Copy all walks the pages it hasn't loaded yet, so all means all" do
    open_panel

    within("[data-freeform-answers-target='modal']") do
      # Headless Chromium has no clipboard to write to, so the button reports
      # a failed copy — but the walk that precedes it is what this checks:
      # every remaining page is fetched before anything is copied.
      click_button "Copy all"
      assert_selector ".freeform-item", count: 130, wait: 10
      assert_text "Showing 130 of 130"
    end

    press_keys(:escape) # the modal's Escape handler is window-scoped; no click needed to reach it
    assert_selector "[data-freeform-answers-target='modal'].hidden", visible: :all, wait: 5
  end

  # Enter after typing, rather than waiting out the 300ms debounce: on a
  # loaded CI runner the timer has lagged past the assertion's wait, leaving
  # the unfiltered list in place. Enter runs the same search at once.
  #
  # Enter is pressed with no pointer involved. Cuprite's Element#send_keys
  # CLICKS the element first, at coordinates it computes just beforehand —
  # and the debounce from the typing above can return in that gap, the list
  # shrinks to its matches, the centred panel re-lays out, and the click
  # lands on the backdrop, which closes the panel. About one run in three
  # locally, more under parallel workers.
  def search_for(text)
    find("[data-freeform-answers-target='search']").set(text) # types, then blurs
    execute_script("document.querySelector(\"[data-freeform-answers-target='search']\").focus()")
    press_keys(:enter)
  end

  test "searching asks the server across every answer" do
    open_panel

    search_for("Answer 12")
    within("[data-freeform-answers-target='modal']") do
      # "Answer 12" and "Answer 120".."Answer 129" — eleven, some of them
      # beyond the first page the panel had loaded.
      assert_text "11 of 130 match", wait: 15
      assert_selector ".freeform-item", count: 11, wait: 15
      assert_no_button "Load more", wait: 2
    end

    search_for("nothing here")
    within("[data-freeform-answers-target='modal']") do
      assert_text "No answers match.", wait: 15
      assert_selector ".freeform-item", count: 0
    end
  end

  # The "Other" a closed question collects opens in the same panel, with its
  # own eyebrow — and the next freeform card to open it gets the default back,
  # rather than the last caller's label over its own answers.
  test "a closed question's write-ins open in the same panel" do
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner

    click_button "View all answers (44) →"
    assert_selector "[data-freeform-answers-target='modal']:not(.hidden)", wait: 5
    # The eyebrow is set in small caps by CSS, so what the browser shows is
    # uppercase — matched case-insensitively, since the case is the style's.
    within("[data-freeform-answers-target='modal']") do
      assert_text(/other: written-in answers/i)
      assert_text "Colour?"
      assert_selector ".freeform-item", count: 44, wait: 10
      assert_equal "Other 129", first(".freeform-item__text").text
      assert_text "Showing 44 of 44"
    end

    press_keys(:escape)
    assert_selector "[data-freeform-answers-target='modal'].hidden", visible: :all, wait: 5

    click_button "View all answers (130) →"
    within("[data-freeform-answers-target='modal']") do
      assert_text(/freeform answers/i, wait: 5)
      assert_no_text(/written-in answers/i)
      assert_text "What stood out?"
    end
  end

  test "the search box also searches when the typing pauses" do
    open_panel

    find("[data-freeform-answers-target='search']").set("Answer 12")
    within("[data-freeform-answers-target='modal']") do
      assert_text "11 of 130 match", wait: 15
      assert_selector ".freeform-item", count: 11, wait: 15
    end
  end
end
