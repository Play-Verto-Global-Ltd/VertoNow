require "application_system_test_case"

# Browser coverage for the Language check screen, on both sides of it: the
# creator's and the account-less reviewer's.
#
# Worth a browser test for two reasons an integration test cannot reach. The
# edit form and the comment thread are folded away by a Stimulus controller, so
# what a reviewer can actually get at is a DOM question. And the whole screen is
# built to work with no JavaScript at all — every action is a plain form POST —
# which is a claim only a real browser can check, by turning the controller off
# and using the page anyway.
class LanguageCheckSystemTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
      "description" => "Pick one", "options" => %w[Blue Green],
      "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } },
    { "type" => "open_ended", "cid" => "c_oe", "text" => "Tell us more" }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "lc-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Nick", email_address: "lc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Colours", theme: "Colours", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: %w[en es fr],
                                   cards: CARDS)
  end

  def mc_card
    @survey.reload.cards.find { |c| c["cid"] == "c_mc" }
  end

  test "the creator reaches the screen from the editor's Language panel" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner

    click_button "Publish & share →"
    # The Publish panel is a tall scroller and the Language block sits well
    # down it, so the summary is in the DOM but out of the viewport — Capybara
    # refuses to click what it cannot see. Bring it into view first, the way a
    # creator would by scrolling.
    summary = find("summary.publish-block-title", text: "Language", visible: :all)
    scroll_to(summary)
    summary.click
    # Opening the <details> reflows everything below it in the scroller, and
    # the share block above carries a thumbnail whose images arrive late — so
    # the entry link is visible, and findable, while its box is still moving.
    # Capybara resolves the centre and then clicks, which lands on whatever has
    # slid into that point: the click does nothing and the assertion below sees
    # the editor's own path. Settle the box first, the idiom this base class
    # carries for exactly "CLICKS something that arrived by animation".
    #
    # Settling was not enough on its own: CI still saw the editor's path once
    # (run 837, 2026-09-23) with the box settled, which means something else
    # can take that first click — a late reflow after the settle, or a layer
    # passing over it. So the link's destination is asserted directly (the
    # thing this test is about), and the click is repeated until the page has
    # actually navigated. A click that lands is idempotent here; one that is
    # swallowed is retried rather than failing a test that is not about it.
    target = survey_language_check_path(@survey)
    entry  = find("a.lc-editor-entry", match: :first)
    assert_equal target, URI(entry[:href]).path
    navigated = wait_until(timeout: 10, interval: 0.5) do
      next true if page.current_path == target

      settle_box(entry)
      entry.click
      page.has_current_path?(target, wait: 2)
    rescue Capybara::ElementNotFound, Ferrum::NodeNotFoundError
      page.current_path == target
    end
    assert navigated, "the Language panel's entry never reached #{target} (still on #{page.current_path})"

    assert_current_path target
    assert_text "Favourite colour?"
    assert_text "¿Color favorito?"
  end

  test "every language of a card is on screen at once, original first" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    within "#card-c_mc" do
      langs = all(".lc-lang-name").map(&:text)
      assert_equal [ "English (UK)", "Spanish", "French" ], langs,
                   "the original leads, the translations follow — that is the reading order"
    end
  end

  test "a line with no translation says so instead of passing English off as French" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    within "#line-c_mc-fr" do
      assert_text "Favourite colour?"
      assert_text "Not translated yet"
    end
  end

  test "approving a line updates its badge and the progress count" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    assert_text "0 of 6 lines approved"
    within("#line-c_mc-es") { click_button "Approve" }

    assert_text "1 of 6 lines approved"
    # The badge is text-transform: uppercase, so assert on the state class the
    # server decided rather than on restyled copy.
    assert_selector "#line-c_mc-es .lc-state--approved"
  end

  test "the creator edits the Spanish and the player serves the new words" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    within "#line-c_mc-es" do
      click_button "Edit wording"
      fill_in "f-line-c_mc-es-text", with: "¿Cuál es tu color favorito?"
      click_button "Save wording"
    end

    assert_text "¿Cuál es tu color favorito?"
    assert_equal "¿Cuál es tu color favorito?", mc_card.dig("i18n", "es", "text")
  end

  test "an approved line that is then edited reads as approved-then-edited" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    within("#line-c_mc-es") { click_button "Approve" }
    within "#line-c_mc-es" do
      click_button "Edit wording"
      fill_in "f-line-c_mc-es-text", with: "Otra cosa"
      click_button "Save wording"
    end

    assert_selector "#line-c_mc-es .lc-state--stale"
  end

  # ── The languages rail ─────────────────────────────────────────────────────

  test "the rail lists each language with how far it has got" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    within ".lc-rail" do
      assert_selector ".lc-rail-item", count: 3
      # The original is labelled as such; the translations carry a count, so a
      # creator can see at a glance which language they are behind on. Spanish
      # is translated on one of the two cards here, French on neither.
      assert_selector ".lc-rail-item.is-primary", text: /English/
      assert_selector ".lc-rail-item", text: /Spanish/
      assert_selector ".lc-rail-item", text: %r{French.*0/2}m
      assert_selector ".lc-rail-status", count: 2
    end
  end

  test "a creator adds two languages from the rail in one go" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    find(".lc-rail-add-summary").click
    check "locales[]", option: "de", allow_label_click: true
    check "locales[]", option: "it", allow_label_click: true
    click_button "Generate translations"

    assert_selector ".lc-rail-item", count: 5
    assert_equal %w[en es fr de it], @survey.reload.verto_locales
  end

  test "a language just asked for says it is being worked on, not that it is empty" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    find(".lc-rail-add-summary").click
    check "locales[]", option: "de", allow_label_click: true
    click_button "Generate translations"

    # The job runs in the background; a bare 0/2 would read as a failure.
    assert_selector ".lc-rail-status--working"
  end

  test "the rail refreshes itself when a translation finishes, without a reload" do
    # The whole point of the poll: you should not have to guess when to press
    # reload. The job is done out of band here — that is exactly what a
    # background worker landing behind an open page looks like.
    @survey.language_checks.destroy_all
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "running",
                               attempts: 1, started_at: 5.seconds.ago)

    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner
    assert_selector ".lc-rail-status--working"

    # French lands while the page sits there.
    cards = @survey.reload.cards.map do |c|
      c.merge("i18n" => (c["i18n"] || {}).merge(
        "fr" => { "text" => "fr:#{c['text']}", "options" => Array(c["options"]).map { |o| "fr:#{o}" } }
      ))
    end
    @survey.update!(cards: cards)
    SurveyTranslation.find_by(survey: @survey, locale: "fr").done!

    # No reload from the test — the page has to notice on its own.
    assert_selector ".lc-rail-item", text: /French/, wait: 15
    assert_no_selector ".lc-rail-status--working", wait: 15
    within(".lc-rail") { assert_text "Translated", wait: 15 }
  end

  test "a fully translated Verto does not poll" do
    cards = @survey.cards.map do |c|
      c.merge("i18n" => %w[es fr].index_with do |loc|
        { "text" => "#{loc}:#{c['text']}", "description" => c["description"].presence && "#{loc}:#{c['description']}",
          "options" => Array(c["options"]).map { |o| "#{loc}:#{o}" }.presence }.compact
      end)
    end
    @survey.update!(cards: cards)

    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-language-status-working-value='false']"
  end

  # The reported bug, at the rail. French has no words and no SurveyTranslation
  # row — the shape every translation path that isn't TranslateLocalesJob leaves
  # behind. The page used to read that as nothing to wait for, never arm the
  # poll, and sit on "Not translated yet" until somebody reloaded by hand.
  test "a language nobody recorded a run for still makes the page watch" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-language-status-working-value='true']"
    # And it must not answer that by reloading itself over and over: the poll
    # reloads on a language CHANGING state, and nothing here changes.
    assert_selector ".lc-rail-item", text: /French/
    assert_no_selector ".lc-rail-status--working"
  end

  # ── The share modal ────────────────────────────────────────────────────────

  test "the reviewer links open from the top of the screen, not the bottom" do
    @survey.language_check_links.create!(name: "Marta — Spanish", locales: [ "es" ])
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    assert_no_text "Marta — Spanish", wait: 1
    click_button "Send this to a reviewer"
    within "#language-check-share-modal" do
      assert_text "Marta — Spanish"
      assert_button "Create review link"
    end
  end

  test "escape closes the share modal" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    click_button "Send this to a reviewer"
    assert_selector "#language-check-share-modal:not(.hidden)"
    # No pointer: send_keys clicks body's centre first, which can be the
    # modal's backdrop — a click that closes the modal on its own.
    press_keys(:escape)
    assert_selector "#language-check-share-modal.hidden", visible: false
  end

  test "creating a link brings the creator back into the modal with it in hand" do
    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    dismiss_cookie_banner

    click_button "Send this to a reviewer"
    within "#language-check-share-modal" do
      fill_in "name", with: "Jonas — French"
      click_button "Create review link"
    end

    # A closed modal here would hide the URL the creator came for.
    assert_selector "#language-check-share-modal:not(.hidden)"
    assert_text "Jonas — French"
    assert_selector "input[value*='/language-check/']"
  end

  # ── The reviewer's side ────────────────────────────────────────────────────

  test "a reviewer with no account opens the link, names themselves and approves" do
    link = @survey.language_check_links.create!(name: "Marta", locales: [ "es" ])

    visit shared_language_check_path(link.token)
    dismiss_cookie_banner

    assert_text "Check this Verto's wording"
    assert_text "¿Color favorito?"
    assert_text "Favourite colour?", exact: false

    fill_in "lc-reviewer-name", with: "Marta"
    click_button "Save"

    within("#line-c_mc-es") { click_button "Approve" }

    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal "approved", row.status
    assert_equal "Marta", row.reviewed_by_name
  end

  test "a reviewer scoped to Spanish is shown the original but given nothing to press on it" do
    link = @survey.language_check_links.create!(locales: [ "es" ])
    visit shared_language_check_path(link.token)
    dismiss_cookie_banner

    assert_selector "#line-c_mc-en"
    within "#line-c_mc-en" do
      assert_selector ".lc-chip--read", text: /for reference/i
      assert_no_button "Approve"
      assert_no_button "Edit wording"
    end
    within("#line-c_mc-es") { assert_button "Approve" }
    assert_no_selector "#line-c_mc-fr"
  end

  test "a read-only link offers approving and commenting but no edit button" do
    link = @survey.language_check_links.create!(locales: [ "es" ], can_edit: false)
    visit shared_language_check_path(link.token)
    dismiss_cookie_banner

    within "#line-c_mc-es" do
      assert_button "Approve"
      assert_button "Comment"
      assert_no_button "Edit wording"
    end
  end

  test "a reviewer leaves a comment and the creator reads it" do
    link = @survey.language_check_links.create!(locales: [ "es" ])
    visit shared_language_check_path(link.token)
    dismiss_cookie_banner

    within "#line-c_mc-es" do
      click_button "Comment"
      find("textarea[name='body']").set("“Verde” should be “Verde claro” here.")
      click_button "Post comment"
    end

    assert_text "Verde claro"

    sign_in_as(@user)
    visit survey_language_check_path(@survey)
    within("#line-c_mc-es") { assert_text "Verde claro" }
  end

  test "a revoked link stops working immediately" do
    link = @survey.language_check_links.create!(locales: [ "es" ])
    visit shared_language_check_path(link.token)
    dismiss_cookie_banner
    assert_text "¿Color favorito?"

    link.destroy!
    visit shared_language_check_path(link.token)
    assert_text "This review link isn't available"
  end

  # ── No JavaScript ──────────────────────────────────────────────────────────

  test "the screen works with its Stimulus controller disabled" do
    # The claim the whole screen is built on: every action is a plain form POST,
    # so a reviewer whose browser never ran the controller can still use it.
    # Approximated by stripping the controller's hooks from the DOM — what is
    # left is the markup a scriptless browser would have.
    link = @survey.language_check_links.create!(locales: [ "es" ])
    visit shared_language_check_path(link.token)
    dismiss_cookie_banner

    execute_script(<<~JS)
      document.querySelectorAll("[data-controller='language-check']").forEach(el => {
        el.removeAttribute("data-controller")
      })
      document.querySelectorAll(".lc-edit, .lc-notes").forEach(el => { el.hidden = false })
    JS

    within "#line-c_mc-es" do
      fill_in "f-line-c_mc-es-text", with: "Sin JavaScript"
      click_button "Save wording"
    end

    assert_equal "Sin JavaScript", mc_card.dig("i18n", "es", "text")
  end
end
