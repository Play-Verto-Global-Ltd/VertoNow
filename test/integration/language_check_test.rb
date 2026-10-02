require "test_helper"

# The Language check screen: every card's wording in every language the Verto
# has, and the owner-side links that hand that page to somebody without an
# account.
#
# The highest-stakes assertions here are the ones about what an edit DOES —
# a reviewer's fix has to land in the deck the player serves (that is the
# feature), without ever resizing an option list (that is the alignment every
# stored answer depends on) and without an older editor tab writing it back.
class LanguageCheckScreenTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "Nick", email_address: "lc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "LC Org", slug: "lc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Colours", theme: "Colours", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: %w[en es fr],
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    )
  end

  def sign_in(user = @user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def mc_card
    @survey.reload.cards.find { |c| c["cid"] == "c_mc" }
  end

  # Give a locale words of its own on every card, so the deck reports it as
  # finished. The poll is armed from coverage, so a test about run rows has to
  # say what the coverage is or the two get tangled up in each other.
  def translate_fully!(locale)
    cards = @survey.reload.cards.map do |card|
      translated = LanguageCheckLines::FIELDS.each_with_object({}) do |field, acc|
        value = card[field]
        next if value.blank?
        acc[field] = value.is_a?(Array) ? value.map { |v| "#{locale}:#{v}" } : "#{locale}:#{value}"
      end
      card.merge("i18n" => (card["i18n"] || {}).merge(locale => translated))
    end
    @survey.update!(cards: cards)
  end

  # ── The screen ─────────────────────────────────────────────────────────────

  # Every field LanguageCheckLines reviews needs a label, because _line renders
  # it with a bare t() — no :default — so a field added to SCALAR_FIELDS without
  # one shows the reviewer `translation_missing` where a heading should be. The
  # NPS scale captions were the two most recent, so this pins the rule rather
  # than just them: the labels come from the same list the screen renders.
  test "every reviewable field has a label on the screen" do
    missing = LanguageCheckLines::FIELDS.reject do |field|
      I18n.exists?("language_check.field.#{field}")
    end
    assert_empty missing,
                 "#{missing.inspect} would render as translation_missing — the screen labels " \
                 "each field with a bare t(\"language_check.field.<field>\")"
  end

  test "an NPS card's scale captions are shown for review, under their own labels" do
    @survey.update!(cards: @survey.cards + [
      { "type" => "nps", "cid" => "c_nps", "text" => "How much say?",
        "nps_low_label" => "I have no say at all", "nps_high_label" => "I am a decision maker",
        "i18n" => { "es" => { "text" => "¿Cuánta voz?", "nps_low_label" => "No tengo ninguna voz" } } }
    ])
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success

    assert_match I18n.t("language_check.field.nps_low_label"), response.body
    assert_match I18n.t("language_check.field.nps_high_label"), response.body
    assert_match "I have no say at all", response.body
    assert_match "No tengo ninguna voz", response.body, "the Spanish caption is what a Spanish " \
                 "respondent reads, so it is what a Spanish reviewer has to be shown"
    assert_no_match "translation_missing", response.body
  end

  test "the screen shows every language's wording for a card, primary first" do
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success

    assert_match "Favourite colour?", response.body, "the primary line must be shown"
    assert_match "¿Color favorito?", response.body, "the Spanish translation must be shown"
    # French has no i18n entry, so its line falls back to the primary wording —
    # which is exactly what the player renders for it. A blank line there would
    # have a reviewer approve something nobody will see.
    assert_match "language_check.untranslated_note", response.body.gsub(
      I18n.t("language_check.untranslated_note"), "language_check.untranslated_note"
    ), "an untranslated line must say so rather than passing English off as French"
  end

  test "a one-language Verto is told so instead of shown an empty board" do
    @survey.update!(locales: [ "en" ])
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success
    assert_match I18n.t("language_check.single_language_title"), response.body
  end

  test "the editor links to the screen and carries its wording revision" do
    @survey.update!(translations_revision: 4)
    sign_in
    get survey_path(@survey)
    assert_response :success
    assert_match survey_language_check_path(@survey), response.body
    assert_match 'data-survey-editor-translations-revision-value="4"', response.body,
                 "the editor must send back the revision it was rendered at"
  end

  test "another organisation's Verto is not reachable" do
    other = User.create!(name: "Other", email_address: "o-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    other_org = Organisation.create!(name: "Other", slug: "o-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: other, role: "admin")
    sign_in(other)
    get survey_language_check_path(@survey)
    assert_response :not_found
  end

  # ── Approving ──────────────────────────────────────────────────────────────

  test "approving a line records who, when, and the words approved" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert_response :redirect

    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal "approved", row.status
    assert_equal @user, row.reviewed_by_user
    assert row.content_digest.present?, "the approved wording must be fingerprinted"
    assert row.source_digest.present?,
           "a translation's approval must also record the primary wording it was checked against"
  end

  test "taking an approval back clears the record of it, not just the status" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal @user, row.reviewed_by_user

    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "reset" }

    row.reload
    assert_equal "pending", row.status
    assert_nil row.reviewed_by_user
    assert_nil row.reviewed_at
    assert_nil row.content_digest,
               "a row still carrying the fingerprint of an approval nobody stands behind " \
               "would resurface as a stale badge the next time the text changed"
    assert_nil row.source_digest
  end

  test "editing a line after approval leaves the approval visibly stale" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")

    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¿Cuál es tu color favorito?" } }

    card    = mc_card
    content = LanguageCheckLines.translated_content(card, "es", LanguageCheckLines.canonical_content(card))
    assert_equal "approved", row.reload.status,
                 "the row keeps the reviewer's decision — the screen reports it as stale, it is not erased"
    assert_equal "stale", LanguageCheck.state_for(row, LanguageCheckLines.digest(content)),
                 "wording edited after approval must read as stale"
  end

  test "rewriting the primary language lapses the translations approved against it" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")

    # The Spanish has not changed — the English under it has. A translation
    # approval is a judgement about fidelity to a source, so it has to lapse.
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit", fields: { text: "Which colour do you like best?" } }

    card    = mc_card
    content = LanguageCheckLines.translated_content(card, "es", LanguageCheckLines.canonical_content(card))
    source  = LanguageCheckLines.digest(LanguageCheckLines.canonical_content(card))
    assert_equal "stale", LanguageCheck.state_for(row.reload, LanguageCheckLines.digest(content), source)
  end

  # ── Editing ────────────────────────────────────────────────────────────────

  test "an edit to a translation lands in the deck the player serves" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { text: "¿Cuál es tu color favorito?", options: [ "Azul", "Verde lima" ] } }

    entry = mc_card.dig("i18n", "es")
    assert_equal "¿Cuál es tu color favorito?", entry["text"]
    assert_equal [ "Azul", "Verde lima" ], entry["options"]
    assert_equal 1, @survey.reload.translations_revision
  end

  test "an edit never resizes an option list" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { options: [ "Azul", "Verde", "Rojo", "Amarillo" ] } }

    assert_equal 2, mc_card.dig("i18n", "es", "options").length,
                 "option N in every language is a label for option N — a translation " \
                 "that grows the list would shear every stored answer's alignment"
    assert_equal %w[Blue Green], mc_card["options"], "the canonical list is untouched"
  end

  test "a blank translation field clears the override rather than storing empty text" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "" } }

    entry = mc_card.dig("i18n", "es")
    assert_not entry.key?("text"),
               "blank means 'show the original here' — the player falls back to the primary language"
  end

  test "a live Verto's canonical option labels are not editable, its question still is" do
    @survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "1" => { "value" => "Blue" } })
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit",
                   fields: { text: "Favorite colour?", options: %w[Navy Emerald] } }

    assert_equal %w[Blue Green], mc_card["options"],
                 "canonical option labels are the answer key for answers already collected"
    assert_equal "Favorite colour?", mc_card["text"],
                 "the question text carries no keys — fixing a typo in a live question must work"
  end

  test "a secondary language stays editable on a live Verto" do
    @survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "1" => { "value" => "Blue" } })
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { options: [ "Azul marino", "Esmeralda" ] } }

    assert_equal [ "Azul marino", "Esmeralda" ], mc_card.dig("i18n", "es", "options"),
                 "nothing is keyed by a translated label, so it is always safe to fix"
  end

  test "editing the primary text drops the rich-text twin that would outrank it" do
    # text_html is a presentation-only copy of the SAME words, and the player
    # renders it in preference to the plain text whenever the two agree
    # (ApplicationHelper#rich_card_text). Left behind, the respondent keeps
    # reading the old sentence in bold and the reviewer's fix never shows.
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c_mc" ? c.merge("text_html" => "<b>Favourite colour?</b>") : c
    end)
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit", fields: { text: "Which colour wins?" } }

    assert_equal "Which colour wins?", mc_card["text"]
    assert_nil mc_card["text_html"], "a twin holding the old words must not outlive them"
  end

  test "an unchanged primary field keeps its rich-text twin" do
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c_mc" ? c.merge("text_html" => "<b>Favourite colour?</b>") : c
    end)
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit",
                   fields: { text: "Favourite colour?", description: "Choose one" } }

    assert_equal "<b>Favourite colour?</b>", mc_card["text_html"],
                 "formatting the reviewer never touched must survive"
    assert_equal "Choose one", mc_card["description"]
  end

  test "editing one option's words drops only that option's twin" do
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c_mc" ? c.merge("options_html" => [ "<b>Blue</b>", "<i>Green</i>" ]) : c
    end)
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "edit", fields: { options: %w[Navy Green] } }

    assert_equal %w[Navy Green], mc_card["options"]
    assert_nil mc_card["options_html"][0]
    assert_equal "<i>Green</i>", mc_card["options_html"][1],
                 "only the slot whose words moved loses its formatting"
  end

  test "a scenario page edit drops that page's html twin and leaves the others" do
    @survey.update!(cards: @survey.cards + [ {
      "type" => "scenario", "cid" => "c_sc", "text" => "A story",
      "pages" => [ { "id" => "p1", "text" => "First", "html" => "<b>First</b>" },
                   { "id" => "p2", "text" => "Second", "html" => "<b>Second</b>" } ]
    } ])
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_sc", locale: "en", verb: "edit",
                   fields: { pages: [ { id: "p1", text: "Opening" }, { id: "p2", text: "Second" } ] } }

    pages = @survey.reload.cards.find { |c| c["cid"] == "c_sc" }["pages"]
    assert_equal "Opening", pages[0]["text"]
    assert_nil pages[0]["html"]
    assert_equal "<b>Second</b>", pages[1]["html"]
  end

  test "a translation edit never writes a rich-text twin into a secondary language" do
    # Translations are plain by contract — sanitize_cards_images! strips any
    # *_html inside i18n, and the editor's store only ever seeds html for the
    # primary. Nothing here may reintroduce one.
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit",
                   fields: { text: "<b>¿Color?</b>", text_html: "<b>¿Color?</b>" } }

    entry = mc_card.dig("i18n", "es")
    assert_not entry.key?("text_html")
    assert_equal "<b>¿Color?</b>", entry["text"],
                 "stored as the plain string it is — escaped on render, never as markup"
  end

  test "a card or language the Verto does not have is refused without saying which" do
    sign_in
    post survey_language_check_lines_path(@survey), params: { cid: "c_ghost", locale: "es", verb: "approve" }
    assert_response :redirect
    assert_equal 0, LanguageCheck.where(survey: @survey, cid: "c_ghost").count

    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "de", verb: "approve" }
    assert_equal 0, LanguageCheck.where(survey: @survey, locale: "de").count
  end

  # ── Comments ───────────────────────────────────────────────────────────────

  test "a comment is recorded against the line and shown on the screen" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "“Verde” should be “Verde claro” here." }

    note = LanguageCheckNote.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal @user, note.author_user
    get survey_language_check_path(@survey)
    assert_match "Verde claro", response.body
  end

  test "a blank comment is not stored" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "   " }
    assert_equal 0, LanguageCheckNote.where(survey: @survey).count
  end

  test "an over-long comment is truncated rather than rejected" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "x" * (LanguageCheckNote::MAX_BODY + 500) }
    assert_equal LanguageCheckNote::MAX_BODY,
                 LanguageCheckNote.find_by!(survey: @survey, cid: "c_mc", locale: "es").body.length
  end

  # ── Adding languages from the sidebar ──────────────────────────────────────

  test "the sidebar adds several languages at once and sets them translating" do
    sign_in
    assert_enqueued_with(job: TranslateLocalesJob) do
      post survey_language_check_languages_path(@survey), params: { locales: %w[de it] }
    end
    assert_response :redirect

    assert_equal %w[en es fr de it], @survey.reload.verto_locales,
                 "one sitting, one background run — not one page reload per language"
  end

  test "adding a language the Verto already has costs nothing" do
    sign_in
    assert_no_enqueued_jobs(only: TranslateLocalesJob) do
      post survey_language_check_languages_path(@survey), params: { locales: [ "es" ] }
    end
    assert_equal %w[en es fr], @survey.reload.verto_locales,
                 "re-translating a language already carried would overwrite hand-edited wording"
  end

  test "the sidebar never drops a language" do
    sign_in
    # The form posts only what was ticked. An empty or partial list must not be
    # read as a deselection — that is the editor's Language settings' job, and a
    # sidebar that silently removed French from a live Verto would be a very
    # quiet way to lose a translation.
    post survey_language_check_languages_path(@survey), params: { locales: [ "de" ] }
    assert_equal %w[en es fr de], @survey.reload.verto_locales
  end

  test "an unsupported or junk language code is ignored" do
    sign_in
    post survey_language_check_languages_path(@survey), params: { locales: [ "de", "xx", "", "../etc" ] }
    assert_equal %w[en es fr de], @survey.reload.verto_locales
  end

  test "a language stuck mid-run offers a way out instead of a permanent spinner" do
    sign_in
    # A row abandoned by a dead worker: nothing will ever close it, so the
    # screen has to stop believing it and offer the creator a way forward.
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "running",
                               attempts: 1, started_at: 2.hours.ago)

    get survey_language_check_path(@survey)
    assert_response :success
    # The status CLASS, not the copy: the label carries an apostrophe that ERB
    # escapes, and the class is what the server actually decided.
    assert_match "lc-rail-status--failed", response.body
    assert_match I18n.t("language_check.rail_retry"), response.body
    assert_no_match(/lc-rail-status--working/, response.body,
                    "a row nothing will ever close must stop claiming to be in progress")
  end

  test "an untranslated language with no run at all can still be asked for" do
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success
    # French has no i18n entries and no SurveyTranslation row — a language added
    # before any of this existed. It must not be a dead end.
    assert_match I18n.t("language_check.rail_generate_one"), response.body
  end

  test "retrying a language re-queues it" do
    sign_in
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "failed",
                               attempts: 3, last_error: "boom")

    assert_enqueued_with(job: TranslateLocalesJob) do
      post retry_survey_language_check_language_path(@survey), params: { locale: "fr" }
    end

    row = SurveyTranslation.find_by(survey: @survey, locale: "fr")
    assert_equal "queued", row.status
    assert_equal 0, row.attempts, "a retry is a fresh run, not one already out of attempts"
    assert_nil row.last_error
  end

  # ── The status poll ────────────────────────────────────────────────────────

  test "the status endpoint says whether anything is still outstanding" do
    sign_in
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "running",
                               attempts: 1, started_at: 10.seconds.ago)

    get survey_language_check_status_path(@survey)
    assert_response :success
    body = JSON.parse(response.body)
    assert body["working"], "a live run must keep the page asking"
    fr = body["languages"].find { |l| l["locale"] == "fr" }
    assert_equal "running", fr["state"]
    assert_equal 2, fr["total"]
  end

  test "a stale run stops the poll rather than keeping a tab asking for ever" do
    sign_in
    # Spanish out of the way first: it is half-translated in the fixture, and a
    # language still missing words is a reason to keep asking all of its own.
    # This test is about the clock, so leave the clock as the only thing to see.
    translate_fully!("es")
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "running",
                               attempts: 1, started_at: 2.hours.ago)

    get survey_language_check_status_path(@survey)
    body = JSON.parse(response.body)
    assert_not body["working"], "the clock is what decides a dead run, and the poll must respect it"
    assert_equal "failed", body["languages"].find { |l| l["locale"] == "fr" }["state"]
  end

  test "a fully translated Verto never starts the poll" do
    sign_in
    translate_fully!("es")
    translate_fully!("fr")

    get survey_language_check_status_path(@survey)
    assert_not JSON.parse(response.body)["working"]

    get survey_language_check_path(@survey)
    assert_match 'data-language-status-working-value="false"', response.body,
                 "a page left open on a finished Verto must cost nothing"
  end

  # The bug this was all for: a language gets its words from a path that keeps
  # no record — creating the Verto, importing one, generating or optimising a
  # card, adding a question — so there is no run row to notice, and the screen
  # sat on "Not translated yet" until somebody thought to reload.
  test "a language nobody recorded a run for still keeps the page watching" do
    sign_in
    assert_nil SurveyTranslation.find_by(survey: @survey, locale: "fr")

    get survey_language_check_status_path(@survey)
    body = JSON.parse(response.body)
    assert body["working"], "no run row is not the same as nothing to wait for"
    assert_equal "none", body["languages"].find { |l| l["locale"] == "fr" }["state"]

    get survey_language_check_path(@survey)
    assert_match 'data-language-status-working-value="true"', response.body
  end

  # The reload loop this fix had to avoid: the rail deciding to watch while the
  # endpoint reports nothing doing is a page that reloads itself every few
  # seconds, for ever, on the screen a creator is working in. Neither half can
  # be tested for it alone, which is why it could be written twice and missed.
  test "the rail and the status endpoint agree about what is outstanding" do
    sign_in

    [ -> { }, -> { translate_fully!("es"); translate_fully!("fr") },
      -> { translate_fully!("es")
           SurveyTranslation.create!(survey: @survey, locale: "fr", status: "failed",
                                     attempts: 3, last_error: "boom") } ].each_with_index do |fixture, i|
      setup
      sign_in
      fixture.call

      get survey_language_check_status_path(@survey)
      endpoint = JSON.parse(response.body)["working"]

      get survey_language_check_path(@survey)
      rail = response.body.include?('data-language-status-working-value="true"')

      assert_equal endpoint, rail,
                   "fixture #{i}: the rail says #{rail}, the endpoint says #{endpoint} — " \
                   "one of them will make the other reload for ever"
    end
  end

  test "the signature names each language's state, and ignores a count moving" do
    sign_in
    get survey_language_check_status_path(@survey)
    before = JSON.parse(response.body)["signature"]
    assert_equal "en:primary,es:none,fr:none", before

    translate_fully!("fr")
    get survey_language_check_status_path(@survey)
    assert_not_equal before, JSON.parse(response.body)["signature"],
                     "a language finishing is exactly what a reload is for"
  end

  test "the page arms the poll when a language is being translated" do
    sign_in
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "queued", attempts: 0)

    get survey_language_check_path(@survey)
    assert_match 'data-language-status-working-value="true"', response.body
    assert_match survey_language_check_status_path(@survey), response.body
  end

  test "the completed original is never reported as outstanding" do
    sign_in
    get survey_language_check_status_path(@survey)
    en = JSON.parse(response.body)["languages"].find { |l| l["locale"] == "en" }
    assert_equal "primary", en["state"]
  end

  test "another organisation cannot poll this Verto's progress" do
    other = User.create!(name: "O", email_address: "o2-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    other_org = Organisation.create!(name: "O", slug: "o2-#{SecureRandom.hex(3)}")
    other_org.memberships.create!(user: other, role: "admin")
    sign_in(other)

    get survey_language_check_status_path(@survey)
    assert_response :not_found
  end

  test "a viewer seat cannot retry a language" do
    viewer = User.create!(name: "V", email_address: "v4-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "failed", attempts: 3)

    assert_no_enqueued_jobs(only: TranslateLocalesJob) do
      post retry_survey_language_check_language_path(@survey), params: { locale: "fr" }
    end
  end

  test "retrying a language the Verto does not have does nothing" do
    sign_in
    assert_no_enqueued_jobs(only: TranslateLocalesJob) do
      post retry_survey_language_check_language_path(@survey), params: { locale: "ja" }
    end
  end

  test "a viewer seat cannot add languages" do
    viewer = User.create!(name: "V", email_address: "v3-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)

    assert_no_enqueued_jobs(only: TranslateLocalesJob) do
      post survey_language_check_languages_path(@survey), params: { locales: [ "de" ] }
    end
    assert_equal %w[en es fr], @survey.reload.verto_locales,
                 "adding a language spends AI and changes what respondents are offered"
  end

  test "the sidebar shows how far each language has actually got" do
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success

    # Spanish is translated on c_mc only; French on neither. Counted off the
    # deck, so a job that half-finished reads as half-finished.
    coverage = LanguageCheckLines.coverage(LanguageCheckLines.for(@survey),
                                            @survey.verto_locales, @survey.default_locale)
    assert_equal({ total: 2, translated: 2, primary: true }, coverage["en"])
    assert_equal({ total: 2, translated: 1, primary: false }, coverage["es"])
    assert_equal({ total: 2, translated: 0, primary: false }, coverage["fr"])
  end

  test "a one-language Verto still gets the sidebar that fixes it" do
    @survey.update!(locales: [ "en" ])
    sign_in
    get survey_language_check_path(@survey)
    assert_response :success
    assert_match "lc-rail", response.body,
                 "the way out of a one-language Verto is the sidebar, not a trip back to the editor"
  end

  # ── Review links ───────────────────────────────────────────────────────────

  test "an admin mints a scoped review link" do
    sign_in
    post survey_language_check_links_path(@survey),
         params: { name: "Marta — Spanish", locales: [ "es" ], can_edit: "1" }

    link = @survey.language_check_links.sole
    assert_equal "Marta — Spanish", link.name
    assert_equal [ "es" ], link.visible_locales
    assert link.can_edit?
    assert link.token.present?
  end

  test "a link scoped to no locales sees every language" do
    sign_in
    post survey_language_check_links_path(@survey), params: { name: "Everyone" }
    assert_equal %w[en es fr], @survey.language_check_links.sole.visible_locales
  end

  test "a link stops offering a language the Verto has dropped" do
    link = @survey.language_check_links.create!(locales: %w[es fr])
    @survey.update!(locales: %w[en es])
    assert_equal [ "es" ], link.visible_locales
  end

  test "pausing keeps the URL, revoking destroys it and keeps the review record" do
    sign_in
    link = @survey.language_check_links.create!(name: "Marta")
    @survey.language_checks.create!(cid: "c_mc", locale: "es", status: "approved",
                                    language_check_link: link, reviewed_by_name: "Marta")

    patch survey_language_check_link_path(@survey, link), params: { active: "0" }
    assert_not link.reload.active?
    assert_match "share=1", response.location,
                 "every link action happens inside the modal — landing on a closed one hides what just happened"

    delete survey_language_check_link_path(@survey, link)
    assert_not LanguageCheckLink.exists?(link.id)
    row = LanguageCheck.find_by!(survey: @survey, cid: "c_mc", locale: "es")
    assert_equal "approved", row.status,
                 "revoking a link must not reset a Verto's review state to 'nobody has looked at this'"
    assert_nil row.language_check_link_id
  end

  test "a non-admin can read the screen but not mint a link" do
    viewer = User.create!(name: "V", email_address: "v-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)

    get survey_language_check_path(@survey)
    assert_response :success

    post survey_language_check_links_path(@survey), params: { name: "Nope" }
    assert_response :redirect
    assert_equal 0, @survey.language_check_links.count
  end

  test "a viewer seat rules on the wording but cannot rewrite it" do
    viewer = User.create!(name: "V", email_address: "v2-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)

    # Reading the wording and saying whether it is right is what a viewer seat
    # is for, so approving and commenting are open to it.
    post survey_language_check_lines_path(@survey), params: { cid: "c_mc", locale: "es", verb: "approve" }
    assert LanguageCheck.exists?(survey: @survey, cid: "c_mc", locale: "es")
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "note", body: "Reads oddly." }
    assert LanguageCheckNote.exists?(survey: @survey, cid: "c_mc", locale: "es")

    # Rewriting the Verto is not. This screen is a write path into `cards` like
    # any other, and the same line applies.
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "Cambiado" } }
    assert_equal "¿Color favorito?", mc_card.dig("i18n", "es", "text")
    assert_equal 0, @survey.reload.translations_revision

    get survey_language_check_path(@survey)
    assert_no_match I18n.t("language_check.edit"), response.body,
                    "the page must not offer a button the endpoint would refuse"
  end

  test "the number of live review links is bounded" do
    sign_in
    LanguageCheckLinksController::MAX_PER_SURVEY.times { @survey.language_check_links.create! }
    post survey_language_check_links_path(@survey), params: { name: "One too many" }
    assert_equal LanguageCheckLinksController::MAX_PER_SURVEY, @survey.language_check_links.count
  end

  # ── The lost-update guard ──────────────────────────────────────────────────

  test "an editor tab older than a reviewer's edit does not write the old wording back" do
    sign_in
    # A reviewer fixes the Spanish.
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }
    assert_equal 1, @survey.reload.translations_revision

    # An editor tab rendered BEFORE that (revision 0) autosaves the whole deck,
    # carrying the Spanish it was seeded with.
    patch survey_path(@survey), params: {
      title: "Colours",
      translations_revision: 0,
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "¡El mejor color!", mc_card.dig("i18n", "es", "text"),
                 "the reviewer's wording must survive an autosave from a tab that never saw it"
  end

  test "an editor tab that has seen the edit is still authoritative about translations" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }
    revision = @survey.reload.translations_revision

    patch survey_path(@survey), params: {
      title: "Colours",
      translations_revision: revision,
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "Otro texto", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "Otro texto", mc_card.dig("i18n", "es", "text"),
                 "a creator editing Spanish in an up-to-date editor must not be overruled"
  end

  test "an editor payload with no revision at all is treated as stale" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }

    patch survey_path(@survey), params: {
      title: "Colours",
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "¡El mejor color!", mc_card.dig("i18n", "es", "text"),
                 "a cached client from before this shipped must not silently lose a reviewer's fix"
  end

  test "the guard leaves the rest of the deck to the editor" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }

    patch survey_path(@survey), params: {
      title: "Colours",
      translations_revision: 0,
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "A brand new question?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal "A brand new question?", mc_card["text"],
                 "only the (card, language) pairs the reviewer touched are carried forward"
    assert_equal "¡El mejor color!", mc_card.dig("i18n", "es", "text")
  end

  # ── Languages added behind an open editor ──────────────────────────────────

  # The reported bug: German added from the rail while an editor tab was open.
  # The job translated it, the tab's next autosave rebuilt every card from a
  # store that had never heard of German, and every German line was gone —
  # while the rail, reading the finished run, still said "Translated".
  def add_german_behind_the_editor!
    @survey.update!(locales: %w[en es fr de])
    translate_fully!("de")
  end

  def autosave_from_a_tab_loaded_before_german(extra = {})
    patch survey_path(@survey), params: {
      title: "Colours",
      translations_revision: @survey.reload.translations_revision,
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => "Favourite colour?",
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } } }
      ]
    }.merge(extra).to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
  end

  test "an editor tab that never knew a language does not autosave it away" do
    sign_in
    add_german_behind_the_editor!

    autosave_from_a_tab_loaded_before_german(content_locales: %w[en es fr])

    assert_equal "de:Favourite colour?", mc_card.dig("i18n", "de", "text")
    assert_equal "de:Welcome", @survey.reload.cards.first.dig("i18n", "de", "text")
  end

  test "a cached editor that sends no language list keeps the languages it never mentioned" do
    sign_in
    add_german_behind_the_editor!

    autosave_from_a_tab_loaded_before_german

    assert_equal "de:Favourite colour?", mc_card.dig("i18n", "de", "text")
  end

  test "a language the editor knows is still the editor's to write" do
    sign_in
    add_german_behind_the_editor!

    autosave_from_a_tab_loaded_before_german(content_locales: %w[en es fr de])

    assert_nil mc_card.dig("i18n", "de"),
               "clearing a language in an editor that shows it is a real edit"
    assert_equal "¿Color favorito?", mc_card.dig("i18n", "es", "text")
  end

  test "a finished run does not make an untranslated language read as Translated" do
    sign_in
    translate_fully!("es")
    SurveyTranslation.create!(survey: @survey, locale: "fr", status: "done", attempts: 1,
                               finished_at: 1.minute.ago)

    get survey_language_check_status_path(@survey)
    body = JSON.parse(response.body)
    assert_equal "incomplete", body["languages"].find { |l| l["locale"] == "fr" }["state"]
    assert_not body["working"], "nothing is on its way, so there is nothing to poll for"

    get survey_language_check_path(@survey)
    fr_row = response.body[/data-language-row="fr".*?<\/li>/m]
    assert_no_match "lc-rail-status--done", fr_row, "the deck has no French, whatever the run said"
    assert_match "0/2", fr_row
    assert_match I18n.t("language_check.rail_retry"), fr_row
  end

  # ── Translations of an original that has since been rewritten ─────────────

  # The welcome card in the report: Spanish, French, Portuguese and Czech all
  # still said "5 minutes" under an English that now said "3 minutes", every
  # line read "Not checked", and nothing on the screen said they were older
  # than the question they sat under.
  def record_spanish_provenance!(digest: nil)
    pairs = LanguageCheckLines.translated_pairs(@survey.reload.cards, [ "es" ])
    pairs = pairs.map { |cid, locale, _| [ cid, locale, digest ] } if digest
    LanguageCheck.record_translated!(@survey.id, pairs)
  end

  def autosave_mc(text: "Favourite colour?", es_text: "¿Color favorito?")
    patch survey_path(@survey), params: {
      title: "Colours", translations_revision: @survey.reload.translations_revision,
      content_locales: %w[en es fr],
      cards: [
        { "type" => "welcome_card", "cid" => "c_w", "title" => "hi", "text" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "c_mc", "text" => text,
          "description" => "Pick one", "options" => %w[Blue Green],
          "i18n" => { "es" => { "text" => es_text, "options" => %w[Azul Verde] } } }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
  end

  def spanish_mc_line
    response.body[/id="line-c_mc-es".*?(?=id="line-|\z)/m].to_s
  end

  test "rewriting the original leaves its translation marked out of date" do
    sign_in
    record_spanish_provenance!
    autosave_mc(text: "Your favourite colour, honestly?")

    get survey_language_check_path(@survey)
    assert_match "lc-outdated", spanish_mc_line
    assert_match I18n.t("language_check.count_outdated", count: 1), response.body
    assert_match I18n.t("language_check.retranslate"), spanish_mc_line

    get survey_language_check_path(@survey, filter: "outdated")
    assert_match 'id="line-c_mc-es"', response.body
    assert_no_match 'id="line-c_mc-fr"', response.body
  end

  test "rewriting the translation in the editor makes it current again" do
    sign_in
    record_spanish_provenance!
    autosave_mc(text: "Your favourite colour, honestly?")
    autosave_mc(text: "Your favourite colour, honestly?", es_text: "¿Tu color favorito, de verdad?")

    get survey_language_check_path(@survey)
    assert_no_match "lc-outdated", spanish_mc_line
  end

  test "a translation nobody recorded the origin of is not called out of date" do
    sign_in
    autosave_mc(text: "Your favourite colour, honestly?")

    get survey_language_check_path(@survey)
    assert_no_match "lc-outdated", response.body, "no record is \"we cannot tell\", not \"stale\""
  end

  test "a reviewer's rewrite of an out-of-date line makes it current" do
    sign_in
    record_spanish_provenance!(digest: "an-older-original")
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "es", verb: "edit", fields: { text: "¡El mejor color!" } }

    get survey_language_check_path(@survey)
    assert_no_match "lc-outdated", spanish_mc_line
  end

  test "Re-translate on a line asks for that card in that language" do
    sign_in
    assert_enqueued_with(job: TranslateLocalesJob, args: [ @survey.id, [ "es" ], [ "c_mc" ] ]) do
      post retranslate_survey_language_check_path(@survey), params: { locale: "es", cid: "c_mc" }
    end
    assert_redirected_to survey_language_check_path(@survey, anchor: "line-c_mc-es")
  end

  test "re-translating a language leaves the lines a reviewer rewrote alone" do
    sign_in
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c_w" ? c.merge("i18n" => { "es" => { "text" => "Bienvenido" } }) : c
    end)
    record_spanish_provenance!(digest: "an-older-original")
    LanguageCheck.find_by(survey: @survey, cid: "c_mc", locale: "es")
                 .update!(edited_at: 1.hour.ago, edited_by_name: "Marta")

    get survey_language_check_path(@survey)
    assert_match I18n.t("language_check.rail_retranslate", count: 1), response.body,
                 "the button's count is the work it will do"

    assert_enqueued_with(job: TranslateLocalesJob, args: [ @survey.id, [ "es" ], [ "c_w" ] ]) do
      post retranslate_survey_language_check_path(@survey), params: { locale: "es" }
    end
  end

  test "a language being re-translated shows as translating, not as done" do
    sign_in
    translate_fully!("es")
    SurveyTranslation.create!(survey: @survey, locale: "es", status: "queued", attempts: 0)

    get survey_language_check_status_path(@survey)
    body = JSON.parse(response.body)
    assert_equal "queued", body["languages"].find { |l| l["locale"] == "es" }["state"]
    assert body["working"], "the page has to wait for the new words, or it never shows them"
  end

  test "a viewer seat cannot re-translate" do
    viewer = User.create!(name: "V", email_address: "v5-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)

    assert_no_enqueued_jobs(only: TranslateLocalesJob) do
      post retranslate_survey_language_check_path(@survey), params: { locale: "es", cid: "c_mc" }
    end
  end

  # ── Translator notes ───────────────────────────────────────────────────────

  test "the author's note on a card is saved and shown on every language's line" do
    sign_in
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "translator_note", body: "  colour as in favourite paint  " }

    assert_equal "colour as in favourite paint",
                 LanguageCheck.find_by(survey: @survey, cid: "c_mc", locale: "en").translator_note

    get survey_language_check_path(@survey)
    assert_match "colour as in favourite paint", spanish_mc_line
    assert_match "lc-tnote", spanish_mc_line
  end

  test "a blank note clears it" do
    sign_in
    LanguageCheck.create!(survey: @survey, cid: "c_mc", locale: "en", translator_note: "old")
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "translator_note", body: " " }

    assert_nil LanguageCheck.find_by(survey: @survey, cid: "c_mc", locale: "en").translator_note
  end

  test "a viewer seat cannot set a translator note" do
    viewer = User.create!(name: "V", email_address: "v6-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in(viewer)
    post survey_language_check_lines_path(@survey),
         params: { cid: "c_mc", locale: "en", verb: "translator_note", body: "mine" }

    assert_nil LanguageCheck.find_by(survey: @survey, cid: "c_mc", locale: "en")
  end

  test "changing the primary language forgets where translations came from" do
    record_spanish_provenance!
    @survey.switch_primary_locale!("es")
    assert_equal 0, LanguageCheck.where(survey: @survey).where.not(translated_from_digest: nil).count
  end

  test "a translated line with no recorded origin can still be re-translated" do
    sign_in
    get survey_language_check_path(@survey)
    assert_no_match "lc-outdated", spanish_mc_line
    assert_match "lc-btn lc-btn--ghost\">#{I18n.t("language_check.retranslate")}<", spanish_mc_line,
                 "lines translated before provenance existed are the ones most likely to be stale"
  end
end
