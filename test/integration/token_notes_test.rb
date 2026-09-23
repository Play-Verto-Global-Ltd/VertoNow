require "test_helper"

# The words around the points — on the intro, on the mid-deck checkpoint, and
# on the final tally.
#
# The intro's two came first (Feedback 17, below). The other two came from a
# creator running a live study: "the scores seem to be just numbers, so I
# wonder if we should consider whether they need a bit more context or
# explanation." They are stored in DIFFERENT places on purpose, and the
# difference is the thing these tests are protecting:
#
#   intro, leaderboard, final tally  →  survey columns, because the intro's
#     pills and the end screen are not cards. Settings copy is shown verbatim
#     in every language — SurveyTranslator walks cards and nothing else.
#   the Points Checkpoint            →  the CARD's own `description`, because
#     it has a card, and card copy is translated. A Verto running in English
#     and Spanish gets a Spanish checkpoint note for free and an English final
#     tally either way; that asymmetry is deliberate, not an oversight.
#
# Feedback 17: "being able to edit both of the tokenomics text per verto
# would be useful, to add own context here about mountain and steps etc. I
# think we can lose the 'steps' lozenge from here, as we have it at the
# bottom of screen for players." The pills previewed the deck's token types
# on the intro; the player's own HUD chip already names the token, so the
# intro was saying it twice.
class TokenNotesTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Welcome" },
    { "type" => "yes_no", "cid" => "q", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def survey(tokens_note: nil, leaderboard_note: nil, token_result_note: nil, cards: CARDS)
    org = Organisation.create!(name: "O", slug: "tn-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards,
      tokenisation_enabled: true, leaderboard_enabled: true,
      tokens_note: tokens_note, leaderboard_note: leaderboard_note,
      token_result_note: token_result_note,
      token_types: [ { "id" => "steps", "icon" => "🥾", "name" => "Steps" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def checkpoint_deck(description: nil)
    [ { "type" => "yes_no", "cid" => "q", "text" => "Q", "options" => [ "Yes", "No" ] },
      { "type" => "token_checkpoint", "cid" => "cp", "text" => "Your points so far",
        "description" => description }.compact ]
  end

  def admin_for(org)
    user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(3)}@test.com",
                        password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    user
  end

  test "custom tokenomics copy renders on the intro, and the default returns when cleared" do
    s = survey(tokens_note: "Every step up this mountain earns you points.",
               leaderboard_note: "The fastest climbers make the summit board!")
    get "/play/#{s.publish_token}"

    assert_response :success
    assert_includes response.body, "Every step up this mountain earns you points.",
                    "the custom points note is not on the intro — tokens_note_text is not " \
                    "being read where the hardcoded i18n used to be"
    assert_includes response.body, "The fastest climbers make the summit board!"

    s.update_columns(tokens_note: nil, leaderboard_note: nil)
    get "/play/#{s.publish_token}"

    # html_escape, because the default copy contains an apostrophe and the
    # body carries it as &#39; — the raw string never matches.
    assert_includes response.body, ERB::Util.html_escape(I18n.t("player.tokens_welcome_note")),
                    "a blank note must fall back to the locale default, not to nothing — " \
                    "same contract as compare_note"
    assert_includes response.body, ERB::Util.html_escape(I18n.t("player.leaderboard_teaser"))
  end

  test "the token-type pills row is gone from the intro" do
    s = survey

    get "/play/#{s.publish_token}"

    assert_response :success
    refute_includes response.body, "welcome-intake-token-types",
                    "the token-type pills are back on the points intro. The owner asked for " \
                    "the 'Steps' lozenge to go — the player's HUD chip already names the " \
                    "token, so the intro was saying it twice."
    # The notes themselves stay; only the pills between them went.
    assert_includes response.body, "welcome-intake-tokens-note"
  end

  test "update_settings stores and clears both notes" do
    s = survey
    admin_for(s.organisation)

    post survey_settings_path(s), params: {
      tokens_note: "  Climb for points.  ", leaderboard_note: "  Summit board awaits.  "
    }

    assert_equal "Climb for points.", s.reload.tokens_note, "stored un-stripped or not at all"
    assert_equal "Summit board awaits.", s.leaderboard_note

    post survey_settings_path(s), params: { tokens_note: "   ", leaderboard_note: "" }

    assert_nil s.reload.tokens_note,
               "blank must clear to nil so the locale default returns — an empty string " \
               "would render an empty pill instead"
    assert_nil s.leaderboard_note
  end

  # ── Both limits, on screen ─────────────────────────────────────────────────
  # The 200-char cap has always been enforced, but it was the only number a
  # creator could find and it is the less useful of the two: each note renders
  # as a single pill on the intro, so it stops FITTING (about 120) long before
  # it stops SAVING. Showing one limit taught the wrong one.

  test "the cap is a named constant, enforced on the way in" do
    s = survey
    admin_for(s.organisation)

    post survey_settings_path(s), params: { tokens_note: "x" * (Survey::MAX_NOTE + 50) }

    assert_equal Survey::MAX_NOTE, s.reload.tokens_note.length,
                 "the note must be cut to MAX_NOTE server-side — maxlength is a courtesy, not a guard"
    assert_operator Survey::RECOMMENDED_NOTE, :<, Survey::MAX_NOTE,
                    "the recommended width has to sit below the cap or there is nothing to advise about"
  end

  test "the editor shows both limits and the split-to-a-card advice" do
    s = survey
    admin_for(s.organisation)

    get survey_path(s)
    assert_response :success

    assert_match 'data-note-limit-recommended-value="120"', response.body
    assert_match 'data-note-limit-max-value="200"', response.body
    assert_match I18n.t("editor.note_limit_split_hint", n: Survey::RECOMMENDED_NOTE), response.body

    counter = I18n.t("js.editor.note_limit_count")
    %w[%{n} %{recommended} %{max}].each do |slot|
      assert_includes counter, slot,
                      "the counter must name the count AND both limits — it is the whole point of the string"
    end
  end

  # ── The final tally ────────────────────────────────────────────────────────

  test "the final-score note reaches the player, and says nothing when unset" do
    s = survey(token_result_note: "Your totals are the trade-offs you made, not a score.")

    get "/play/#{s.publish_token}"

    assert_response :success
    assert_includes response.body,
                    %(data-player-tokens-result-note-value="Your totals are the trade-offs you made, not a score."),
                    "the end screen is built by _renderTokenScore from this value — without it on the " \
                    "element the creator's sentence has no way of reaching the tally"

    s.update_columns(token_result_note: nil)
    get "/play/#{s.publish_token}"

    assert_includes response.body, %(data-player-tokens-result-note-value=""),
                    "an unset note must arrive EMPTY, not as house copy. Every other note here " \
                    "falls back to a locale default; this one must not — only the creator knows " \
                    "what their tokens are counting, so a shipped sentence about points in " \
                    "general would be worse than the bare numbers it replaced"
  end

  test "a blank final-score note resolves to nothing rather than to a locale default" do
    assert_nil survey.token_result_note_text,
               "token_result_note_text fell back to house copy. The pill is rendered only when " \
               "this is present, so a default here puts words in every existing Verto's mouth"
  end

  test "update_settings stores, caps and clears the final-score note" do
    s = survey
    admin_for(s.organisation)

    post survey_settings_path(s), params: { token_result_note: "  What the totals mean.  " }
    assert_equal "What the totals mean.", s.reload.token_result_note

    post survey_settings_path(s), params: { token_result_note: "x" * (Survey::MAX_NOTE + 50) }
    assert_equal Survey::MAX_NOTE, s.reload.token_result_note.length,
                 "the final-score note must be cut server-side like its two siblings — maxlength " \
                 "is a courtesy, not a guard"

    post survey_settings_path(s), params: { token_result_note: "   " }
    assert_nil s.reload.token_result_note, "blank must clear to nil, not to an empty string"
  end

  test "the editor offers the final-score note beside the intro's" do
    s = survey
    admin_for(s.organisation)

    get survey_path(s)

    assert_response :success
    assert_match(/name="token_result_note"/, response.body,
                 "the box is not in the Tokenisation panel, which is the one place a creator " \
                 "looks for points copy")
    assert_match(/maxlength="#{Survey::MAX_NOTE}"/, response.body)
  end

  # The limitation, stated where the typing happens rather than discovered by a
  # Spanish respondent reading English. Only on the Vertos it can bite.
  test "a multilingual Verto is told its settings copy is not translated" do
    s = survey
    admin_for(s.organisation)

    get survey_path(s)
    assert_no_match(/only card text is translated/, response.body,
                    "a single-language Verto has no translation to warn about")

    s.update_columns(locales: %w[en es])
    get survey_path(s)
    assert_match(/only card text is translated/, response.body,
                 "a Verto with a second language must be told these three notes are shown in " \
                 "English to everyone — it is the reason the checkpoint's note lives on the card")
  end

  # ── The mid-deck checkpoint ────────────────────────────────────────────────

  test "a checkpoint card's own body copy reaches the player" do
    s = survey(cards: checkpoint_deck(description: "These are trade-offs, not a score."))

    get "/play/#{s.publish_token}"

    assert_response :success
    assert_includes response.body, "These are trade-offs, not a score.",
                    "the checkpoint's explainer never rendered. It is the card's `description` " \
                    "precisely so SurveyTranslator carries it into the Verto's other languages"
  end

  test "the editor invites the copy on a checkpoint, and names what it is for" do
    s = survey(cards: checkpoint_deck)
    admin_for(s.organisation)

    get survey_path(s)

    assert_response :success
    # The attribute, not the string: window.I18N carries the whole `card:`
    # namespace into the page, so both of these appear in the body regardless
    # and only the rendered data-placeholder says which one the card got.
    assert_includes response.body, %(data-placeholder="#{I18n.t("card.checkpoint_body_placeholder")}"),
                    "a checkpoint with no copy yet offers nowhere to type it — the node IS the " \
                    "field (survey-editor#_readCard), so without it rendered empty there is " \
                    "nothing to click into and the feature does not exist"
    assert_not_includes response.body, %(data-placeholder="#{I18n.t("card.body_placeholder")}"),
                        "the checkpoint was handed the generic invitation. 'Add body copy' on a " \
                        "card with no body gives a creator no reason to think it is where the " \
                        "points get explained"
  end

  test "an ordinary question card is still not offered body copy it did not ask for" do
    s = survey(cards: [ { "type" => "yes_no", "cid" => "q", "text" => "Q", "options" => [ "Yes", "No" ] } ])
    admin_for(s.organisation)

    get survey_path(s)

    assert_response :success
    assert_not_includes response.body, %(class="q-subtitle"),
                        "every question card in the deck grew an empty invitation. The prompt is " \
                        "for the two types whose copy is the point and which nothing writes for " \
                        "the creator (CardTypes::BODY_COPY_PROMPTED_TYPES); a generated question " \
                        "card arrives with a subtitle already"
  end
end
