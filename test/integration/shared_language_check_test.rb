require "test_helper"

# The public half of the Language check screen — /language-check/:token, the
# page a creator sends to somebody who speaks the language and has no account.
#
# The token IS the authorisation, so the assertions that matter most here are
# about the boundary: what a link holder can reach (only this Verto's wording,
# only the languages the link was minted for), what they cannot (results,
# respondents, settings, the deck's structure), and that turning a link off
# actually turns it off.
class SharedLanguageCheckTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "Nick", email_address: "slc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "SLC Org", slug: "slc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Colours", theme: "Colours", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: %w[en es fr],
      cards: [
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => {
            "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] },
            "fr" => { "text" => "Couleur préférée ?", "options" => %w[Bleu Vert] }
          } },
        { "type" => "open_ended", "cid" => "c_oe", "text" => "Tell us more" }
      ]
    )
    @link = @survey.language_check_links.create!(name: "Marta — Spanish", locales: [ "es" ],
                                                 created_by_user: @user)
  end

  def mc_card
    @survey.reload.cards.find { |c| c["cid"] == "c_mc" }
  end

  # ── Reaching the page ──────────────────────────────────────────────────────

  test "a link holder reads the page with no account and no sign-in" do
    get shared_language_check_path(@link.token)
    assert_response :success
    assert_match "¿Color favorito?", response.body
    assert_match "Favourite colour?", response.body,
                 "the primary line is the source the translation is being checked against"
  end

  test "the page is not indexable" do
    get shared_language_check_path(@link.token)
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"],
                 "the URL is the whole of the authorisation — an indexed one publishes the capability"
  end

  test "robots.txt asks crawlers off the path as well" do
    get "/robots.txt"
    assert_match "Disallow: /language-check/", response.body
  end

  test "a link scoped to Spanish never renders the French" do
    get shared_language_check_path(@link.token)
    assert_response :success
    assert_no_match(/Couleur pr/, response.body,
                    "a link minted for one language must not hand over the others")
  end

  test "a scoped link still shows the primary line, as context it cannot act on" do
    get shared_language_check_path(@link.token)
    assert_response :success
    assert_match "Favourite colour?", response.body,
                 "checking a translation means comparing it against the question it translates"
    assert_match I18n.t("language_check.for_reference"), response.body,
                 "a line drawn only as context must say so, not just lack buttons"
  end

  test "a scoped link cannot act on the primary line it is shown" do
    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "en", verb: "edit", fields: { text: "Rewritten by a stranger" } }

    assert_equal "Favourite colour?", mc_card["text"],
                 "the source line is read-only, enforced at the write and not only in the markup"
    assert_equal 0, LanguageCheck.where(survey: @survey, locale: "en").count
  end

  test "progress counts only the lines the reviewer is responsible for" do
    get shared_language_check_path(@link.token)
    # Two cards carry words; the link sees Spanish on both. The English it is
    # shown for reference must not be in the denominator.
    assert_match I18n.t("language_check.progress", approved: 0, total: 2), response.body
  end

  test "an unscoped link shows every language" do
    open_link = @survey.language_check_links.create!(name: "Everyone")
    get shared_language_check_path(open_link.token)
    assert_match "¿Color favorito?", response.body
    assert_match "Couleur", response.body
  end

  test "a paused link, a revoked one and a deleted Verto all read the same" do
    @link.update!(active: false)
    get shared_language_check_path(@link.token)
    assert_response :not_found
    assert_match "review link isn", response.body

    @link.update!(active: true)
    @survey.update!(deleted_at: Time.current)
    get shared_language_check_path(@link.token)
    assert_response :not_found
    assert_match "review link isn", response.body

    get shared_language_check_path("not-a-real-token")
    assert_response :not_found
    assert_match "review link isn", response.body
  end

  test "a link whose languages the Verto has dropped is unavailable, not empty" do
    @survey.update!(locales: %w[en fr])
    get shared_language_check_path(@link.token)
    assert_response :not_found
  end

  test "opening the page records that the link is being used" do
    assert_nil @link.last_seen_at
    get shared_language_check_path(@link.token)
    assert @link.reload.last_seen_at.present?
  end

  # ── Acting on a line ───────────────────────────────────────────────────────

  test "a link holder approves a line without a CSRF token or a session" do
    post shared_language_check_lines_path(@link.token), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert_response :redirect

    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal "approved", row.status
    assert_equal @link, row.language_check_link
    assert_nil row.reviewed_by_user, "a link holder has no account by construction"
  end

  test "a link holder's edit lands in the deck the player serves" do
    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { text: "¿Cuál es tu color favorito?", options: [ "Azul", "Verde lima" ] } }

    assert_equal "¿Cuál es tu color favorito?", mc_card.dig("i18n", "es", "text")
    assert_equal [ "Azul", "Verde lima" ], mc_card.dig("i18n", "es", "options")
    assert_equal 1, @survey.reload.translations_revision
  end

  test "a read-only link approves and comments but cannot change a word" do
    @link.update!(can_edit: false)

    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "Nope" } }
    assert_equal "¿Color favorito?", mc_card.dig("i18n", "es", "text"),
                 "read-only is a posture, enforced where the write happens — not a hidden button"
    assert_equal 0, @survey.reload.translations_revision

    post shared_language_check_lines_path(@link.token), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert LanguageCheck.exists?(survey: @survey, cid: "c_mc", locale: "es")

    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "Reads fine to me." }
    assert LanguageCheckNote.exists?(survey: @survey, cid: "c_mc", locale: "es")
  end

  test "a link holder cannot touch a language the link was not minted for" do
    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "fr", verb: "edit", fields: { text: "Pirate" } }

    assert_equal "Couleur préférée ?", mc_card.dig("i18n", "fr", "text")
    assert_equal 0, LanguageCheck.where(survey: @survey, locale: "fr").count
  end

  test "a paused link stops accepting actions, not just page loads" do
    @link.update!(active: false)
    post shared_language_check_lines_path(@link.token), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert_response :not_found
    assert_equal 0, LanguageCheck.where(survey: @survey).count
  end

  test "nothing on the page can change the deck's structure" do
    before = mc_card
    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { text: "Sigue igual", type: "open_ended", cid: "c_hacked",
                             options: %w[a b c d], image: "/evil.png" } }

    after = mc_card
    assert_equal "multiple_choice", after["type"], "a reviewer changes what a question SAYS, never what it IS"
    assert_equal "c_mc", after["cid"]
    assert_equal before["options"], after["options"]
    assert_nil after["image"]
    assert_equal 2, after.dig("i18n", "es", "options").length
  end

  test "a link holder cannot reach the owner's screens for the same Verto" do
    get survey_language_check_path(@survey)
    assert_response :redirect, "the owner's screen still requires an account"

    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert_response :redirect
    assert_equal 0, LanguageCheck.where(survey: @survey).count
  end

  # ── Who reviewed it ────────────────────────────────────────────────────────

  test "a reviewer names themselves once and their approvals carry it" do
    post shared_language_check_name_path(@link.token), params: { reviewer_name: "Marta" }
    assert_response :redirect

    post shared_language_check_lines_path(@link.token), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert_equal "Marta", LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es").reviewed_by_name
  end

  test "reviewing anonymously is allowed and reads as such" do
    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "Sounds stiff." }
    note = LanguageCheckNote.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_nil note.author_name
    assert_equal I18n.t("language_check.anonymous_reviewer"), note.author_label
  end

  test "a submitted name is bounded and stripped of control characters" do
    noisy = [ "M", 0.chr, "arta" ].join + ("x" * 200)
    post shared_language_check_name_path(@link.token), params: { reviewer_name: noisy }
    post shared_language_check_lines_path(@link.token), params: { cid: "c_mc", locale: "es", verb: "approve" }

    name = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es").reviewed_by_name
    assert_equal LanguageCheck::MAX_NAME, name.length
    assert_not name.include?(0.chr)
  end

  test "a name is per link, so reviewing a second Verto does not rename the first" do
    other = @org.surveys.create!(title: "B", theme: "B", audience_age: "all", key_insight: "k",
                                 default_locale: "en", locales: %w[en es],
                                 cards: [ { "type" => "open_ended", "cid" => "c_b", "text" => "Why?" } ])
    other_link = other.language_check_links.create!

    post shared_language_check_name_path(@link.token), params: { reviewer_name: "Marta" }
    post shared_language_check_name_path(other_link.token), params: { reviewer_name: "Jonas" }

    post shared_language_check_lines_path(@link.token), params: { cid: "c_mc", locale: "es", verb: "approve" }
    post shared_language_check_lines_path(other_link.token), params: { cid: "c_b", locale: "es", verb: "approve" }

    assert_equal "Marta", LanguageCheck.find_by!(survey: @survey, cid: "c_mc").reviewed_by_name
    assert_equal "Jonas", LanguageCheck.find_by!(survey: other, cid: "c_b").reviewed_by_name
  end

  # ── What the owner sees afterwards ─────────────────────────────────────────

  test "the owner's screen shows what the link holder did" do
    post shared_language_check_name_path(@link.token), params: { reviewer_name: "Marta" }
    post shared_language_check_lines_path(@link.token), params: { cid: "c_mc", locale: "es", verb: "approve" }
    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "Approved with one nit." }

    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    get survey_language_check_path(@survey)

    assert_response :success
    assert_match "Marta", response.body
    assert_match "Approved with one nit.", response.body
  end

  # ── What a reviewer sees of the out-of-date warning and the author's note ──

  test "a reviewer sees the out-of-date warning and the author's note, without the creator's controls" do
    LanguageCheck.record_translated!(@survey.id, [ [ "c_mc", "es", "an-older-original" ] ])
    LanguageCheck.create!(survey: @survey, cid: "c_mc", locale: "en", translator_note: "colour as in paint")

    get shared_language_check_path(@link.token)
    assert_match I18n.t("language_check.outdated_note"), response.body
    assert_match "colour as in paint", response.body
    assert_no_match I18n.t("language_check.retranslate"), response.body,
                    "re-translating spends AI and replaces words — the creator's call"
    assert_no_match 'value="translator_note"', response.body
  end

  test "a reviewer cannot set the author's note" do
    post shared_language_check_lines_path(@link.token),
         params: { cid: "c_mc", locale: "es", verb: "translator_note", body: "mine" }
    assert_nil LanguageCheck.where(survey: @survey).where.not(translator_note: nil).first
  end
end
