require "test_helper"

# The end-of-Verto ask: "keep your answers, and hear what happens next".
#
# Off by default and creator-written, which is the whole shape of it — a
# respondent is asked for an email address, so it is a thing a creator turns
# on deliberately, and what it says is theirs rather than ours.
class JoinPromptTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Welcome" },
    { "type" => "yes_no", "cid" => "q", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def survey(**attrs)
    org = Organisation.create!(name: "O", slug: "jp-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def admin_for(org)
    user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(3)}@test.com",
                        password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    user
  end

  # ── The toggle ────────────────────────────────────────────────────────────

  test "it is off until a creator turns it on" do
    s = survey
    assert_not s.join_prompt_enabled?,
      "a Verto that asks respondents for an email must never do so by default"

    admin_for(s.organisation)
    post survey_settings_path(s), params: { join_prompt_enabled: "1" }

    assert s.reload.join_prompt_enabled?
  end

  test "the toggle is not locked once a Verto is live" do
    s = survey
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed")
    admin_for(s.organisation)

    post survey_settings_path(s), params: { join_prompt_enabled: "1" }

    assert s.reload.join_prompt_enabled?,
      "it only changes what a respondent is shown from here on, so it belongs " \
      "with the presentation switches rather than in SETTINGS_LOCKED_IN_USE"
  end

  # ── The comparison it brings with it ──────────────────────────────────────

  # An account is where you see your answers beside everyone else's, and that
  # page draws nothing while show_results_comparison is off. So the ask turning
  # on turns the comparison on — once, as a default, never as an override.

  test "turning the ask on turns the comparison on with it" do
    s = survey
    assert_not s.show_results_comparison?
    admin_for(s.organisation)

    post survey_settings_path(s), params: { join_prompt_enabled: "1" }

    s.reload
    assert s.join_prompt_enabled?
    assert s.show_results_comparison?,
      "an account whose Verto has no comparison open has nothing to show a respondent"
  end

  test "a request that names the comparison itself is taken at its word" do
    s = survey
    admin_for(s.organisation)

    post survey_settings_path(s), params: { join_prompt_enabled: "1", show_results_comparison: "0" }

    assert s.reload.join_prompt_enabled?
    assert_not s.show_results_comparison?
  end

  test "the creator can switch the comparison off afterwards and re-saving the ask leaves it off" do
    s = survey
    admin_for(s.organisation)
    post survey_settings_path(s), params: { join_prompt_enabled: "1" }
    post survey_settings_path(s), params: { show_results_comparison: "0" }
    assert_not s.reload.show_results_comparison?

    # The checkbox form posts its field on every change, so this is the shape of
    # a creator re-saving the ask — not a flip, so not a second default.
    post survey_settings_path(s), params: { join_prompt_enabled: "1" }

    assert s.reload.join_prompt_enabled?
    assert_not s.show_results_comparison?, "a default is applied once, not enforced"
  end

  test "turning the ask off leaves the comparison as the creator had it" do
    s = survey
    admin_for(s.organisation)
    post survey_settings_path(s), params: { join_prompt_enabled: "1" }
    assert s.reload.show_results_comparison?

    post survey_settings_path(s), params: { join_prompt_enabled: "0" }

    assert_not s.reload.join_prompt_enabled?
    assert s.show_results_comparison?,
      "the end screen's comparison was open before the account was and is not the account's to close"
  end

  test "a refused ask does not open the comparison either" do
    neuro = DemographicQuestions::OPTIONAL_CARDS["neurodiversity"].dup
    s = survey
    s.update!(cards: CARDS.map(&:dup) + [ neuro ])
    admin_for(s.organisation)

    post survey_settings_path(s), params: { join_prompt_enabled: "1" }

    assert_not s.reload.join_prompt_enabled?
    assert_not s.show_results_comparison?,
      "the whole request is refused; half of it landing would publish a comparison nobody asked for"
  end

  test "the panel says what the account needs, and says so when the comparison is off" do
    s = survey(join_prompt_enabled: true, show_results_comparison: true)
    admin_for(s.organisation)

    get survey_path(s)
    assert_response :success
    assert_select "#join-compare-off", 0

    s.update_columns(show_results_comparison: false)
    get survey_path(s)
    assert_select "#join-compare-off", 1,
      "an account with no comparison behind it should be flagged where the creator turns it on"
  end

  # ── The copy ──────────────────────────────────────────────────────────────

  test "blank copy reads as the locale default, and a creator's copy replaces it" do
    s = survey
    assert_equal I18n.t("player.join_title"), s.join_title_text
    assert_equal I18n.t("player.join_body"),  s.join_body_text
    assert_equal I18n.t("player.join_cta"),   s.join_cta_text

    s.update!(join_title: "Hear what the council decides.")
    assert_equal "Hear what the council decides.", s.reload.join_title_text
  end

  test "the player's fallback follows the respondent's language" do
    s = survey

    I18n.with_locale(:fr) do
      assert_equal I18n.t("player.join_title", locale: :fr), s.join_title_text
      refute_equal I18n.t("player.join_title", locale: :en), s.join_title_text,
        "player.join_* was translated into 24 locales precisely so a French " \
        "respondent stops reading English on the end screen"
    end
  end

  # The other half of that, and the reason the two readers are separate.
  #
  # The editor renders these as the value= of inputs that autosave onchange, so
  # a French creator being pre-filled with French house copy is one stray
  # keystroke away from PINNING French onto surveys.join_title — shown then to
  # every respondent, in every language. The pre-fill is English by design.
  test "the editor's pre-fill stays English whatever the creator's UI language" do
    s = survey
    english = I18n.t("player.join_title", locale: :en)

    %i[fr ar ja].each do |locale|
      I18n.with_locale(locale) do
        assert_equal english, s.join_title_for_editor,
          "a #{locale} creator would otherwise save #{locale} copy onto an English Verto"
        assert_equal I18n.t("player.join_body", locale: :en), s.join_body_for_editor
        assert_equal I18n.t("player.join_cta", locale: :en), s.join_cta_for_editor
      end
    end
  end

  test "an en-US creator keeps American spelling in the pre-fill" do
    s = survey

    I18n.with_locale(:"en-US") do
      assert_equal I18n.t("player.join_title", locale: :"en-US"), s.join_title_for_editor
      assert_equal I18n.t("player.join_body", locale: :"en-US"), s.join_body_for_editor
    end
  end

  test "a creator's own copy is returned untouched to both the editor and the player" do
    s = survey
    s.update!(join_title: "Hear what the council decides.")

    I18n.with_locale(:fr) do
      assert_equal "Hear what the council decides.", s.reload.join_title_for_editor
      assert_equal "Hear what the council decides.", s.join_title_text
    end
  end

  test "update_settings stores the three fields and clears them back to the default" do
    s = survey(join_prompt_enabled: true)
    admin_for(s.organisation)

    post survey_settings_path(s), params: {
      join_title: "  Keep your answers.  ", join_body: "  We'll email you once.  ",
      join_cta: "  Send me the link  "
    }

    assert_equal "Keep your answers.", s.reload.join_title, "stored un-stripped or not at all"
    assert_equal "We'll email you once.", s.join_body
    assert_equal "Send me the link", s.join_cta

    post survey_settings_path(s), params: { join_title: "   ", join_body: "", join_cta: "  " }

    assert_nil s.reload.join_title,
      "blank must clear to nil so the locale default returns — an empty string " \
      "would render an empty heading instead"
    assert_nil s.join_body
    assert_nil s.join_cta
  end

  test "the caps are named constants, enforced on the way in" do
    s = survey(join_prompt_enabled: true)
    admin_for(s.organisation)

    post survey_settings_path(s), params: {
      join_title: "x" * (Survey::MAX_JOIN_TITLE + 50),
      join_body:  "y" * (Survey::MAX_JOIN_BODY + 50),
      join_cta:   "z" * (Survey::MAX_END_LABEL + 50)
    }

    s.reload
    assert_equal Survey::MAX_JOIN_TITLE, s.join_title.length,
      "maxlength is a courtesy; the cut has to happen server-side"
    assert_equal Survey::MAX_JOIN_BODY, s.join_body.length
    assert_equal Survey::MAX_END_LABEL, s.join_cta.length
    assert_operator Survey::RECOMMENDED_JOIN_TITLE, :<, Survey::MAX_JOIN_TITLE,
      "the recommended width has to sit below the cap or there is nothing to advise about"
    assert_operator Survey::RECOMMENDED_JOIN_BODY, :<, Survey::MAX_JOIN_BODY
  end

  # ── The editor ────────────────────────────────────────────────────────────

  test "the panel shows the toggle, and the copy fields only once it is on" do
    s = survey
    admin_for(s.organisation)

    get survey_path(s)
    assert_response :success
    assert_match 'name="join_prompt_enabled"', response.body
    assert_select "[data-gate-cards-target='joinCard'][hidden]", 1,
      "an off switch shows no card — the feed offers the CTA instead"
    assert_select "[data-gate-cards-target='joinCta']:not([hidden])", 1

    s.update!(join_prompt_enabled: true)
    get survey_path(s)

    assert_select "[data-gate-cards-target='joinCard']:not([hidden])", 1
    assert_select "[data-gate-cards-target='joinCta'][hidden]", 1
  end

  # The copy used to be edited in this panel, in a collapsed disclosure — the
  # one part of the account ask a creator writes, furthest from where they could
  # see it. It moved to a card in the feed beside the thank-you card. It is NOT
  # in both places: two surfaces writing the same columns is how the editor and
  # the player drifted apart before.
  test "the wording is edited on the card in the feed, not in the panel" do
    s = survey(join_prompt_enabled: true)
    admin_for(s.organisation)

    get survey_path(s)
    assert_response :success

    assert_no_match(/name="join_title"/, response.body)
    assert_no_match(/name="join_body"/, response.body)
    assert_no_match(/name="join_cta"/, response.body)

    %w[joinTitle joinBody joinCtaText].each do |target|
      assert_select "[data-gate-cards-target='#{target}'][contenteditable='true']", 1
    end
  end

  test "the fields are pre-filled with the resolved default, so a creator edits a real sentence" do
    s = survey(join_prompt_enabled: true)
    admin_for(s.organisation)

    get survey_path(s)

    assert_match ERB::Util.html_escape(I18n.t("player.join_title")), response.body,
      "an empty box teaches nothing about what the block will say"
  end

  # ── The wall ──────────────────────────────────────────────────────────────
  # A block that collects an email is a contact form by any reading, so it sits
  # behind the same refusal: health-adjacent special-category answers must never
  # sit beside a name and an address.

  test "it cannot be turned on for a Verto that asks the neurodiversity question" do
    neuro = DemographicQuestions::OPTIONAL_CARDS["neurodiversity"].dup
    s = survey
    s.update!(cards: CARDS.map(&:dup) + [ neuro ])
    admin_for(s.organisation)

    post survey_settings_path(s), params: { join_prompt_enabled: "1" }

    assert_not s.reload.join_prompt_enabled?,
      "the neurodiversity wall has a second door if the join prompt can walk through it"
    assert_redirected_to survey_path(s, panel: "publish", contact_error: "neurodiversity")
  end

  test "the refusal is a redirect with a reason, not a 500" do
    neuro = DemographicQuestions::OPTIONAL_CARDS["neurodiversity"].dup
    s = survey
    s.update!(cards: CARDS.map(&:dup) + [ neuro ])
    admin_for(s.organisation)

    post survey_settings_path(s), params: { join_prompt_enabled: "1" }

    assert_response :redirect
    get survey_path(s, panel: "publish", contact_error: "neurodiversity")
    assert_match(/neurodiversity/i, response.body)
  end

  # ── Duplicate ─────────────────────────────────────────────────────────────

  # ── The block, on the player ──────────────────────────────────────────────

  test "the end screen carries the block only when the ask is on" do
    off = survey
    get play_survey_path(off.publish_token)
    assert_response :success
    assert_select ".join-card", 0
    assert_includes response.body, 'data-player-join-url-value=""',
                    "and no live endpoint to reach"

    on = survey(join_prompt_enabled: true)
    get play_survey_path(on.publish_token)
    assert_select ".join-card", 1
    assert_includes response.body, join_survey_url(on.publish_token)
  end

  test "the block renders the creator's own sentences" do
    s = survey(join_prompt_enabled: true, join_title: "Keep your street",
               join_body: "We'll tell you what the council decides.",
               join_cta: "Email me")

    get play_survey_path(s.publish_token)

    assert_select ".join-title", text: "Keep your street"
    assert_select ".join-body", text: "We'll tell you what the council decides."
    assert_select ".join-btn", text: /Email me/
  end

  test "the card starts hidden, so nothing appears before the end screen" do
    # .play-end-actions is inside the thank-you panel, but the join card is
    # revealed by _renderJoinState rather than by the panel — a card that
    # shipped without `hidden` would flash on the first paint.
    s = survey(join_prompt_enabled: true)
    get play_survey_path(s.publish_token)
    assert_select ".join-card.hidden", 1
  end

  test "owner preview carries no live join endpoint" do
    # The same rule every other *-url-value follows: a creator checking their
    # own Verto must not be able to mail themselves a sign-in link from it.
    # Test Mode is swept for the whole set in test_mode_test.rb.
    s = survey(join_prompt_enabled: true)
    admin_for(s.organisation)

    get preview_survey_path(s)

    assert_response :success
    assert_includes response.body, 'data-player-join-url-value=""'
  end

  test "duplicating a Verto carries the ask, and the notes that used to be dropped" do
    s = survey(join_prompt_enabled: true, join_title: "Keep it", join_body: "Because.",
               join_cta: "Go", tokens_note: "Climb for points.",
               leaderboard_note: "Summit board awaits.")
    admin_for(s.organisation)

    post duplicate_survey_path(s)
    copy = s.organisation.surveys.order(:id).last

    assert copy.join_prompt_enabled?, "duplicate! must carry the new columns or Duplicate drops them"
    assert_equal "Keep it", copy.join_title
    assert_equal "Because.", copy.join_body
    assert_equal "Go", copy.join_cta
    assert_equal "Climb for points.", copy.tokens_note,
      "tokens_note was missing from duplicate! — a follow-up Verto is usually a duplicate, " \
      "which is exactly when losing a creator's own copy shows"
    assert_equal "Summit board awaits.", copy.leaderboard_note
  end
end
