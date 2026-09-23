require "test_helper"

# Telling a respondent what their answers did — the whole reason the account
# asked for an address — and the unsubscribe question that forces.
#
# The properties that matter here are all about restraint. A creator gets one
# send per person per Verto and cannot spend it twice. An address nobody proved
# they own is never mailed. And a respondent who wants fewer emails from one
# council is offered exactly that, rather than "stop everything Playverto ever
# sends you" — which is what the only existing link would have meant.
class PlayerNotificationsTest < ActionDispatch::IntegrationTest
  def org(name = "Haverley Town Council")
    Organisation.create!(name: name, slug: "pn-#{SecureRandom.hex(3)}")
  end

  def survey(owner: nil, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      join_prompt_enabled: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def with_impact(s)
    s.update!(impact_headline: "The High Street closes at weekends from March",
              impact_body: "1,284 people answered and 62% wanted a weekend closure.",
              impact_changes: [ "Deliveries move to a 7–10am window" ],
              impact_link_url: "https://haverley.example/report", impact_link_label: "The full report")
    s
  end

  # A respondent who kept `s` and proved they can read their inbox.
  def keeper(s, verified: true, email: nil)
    r = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    pl = Player.for_email(email || "pn-#{SecureRandom.hex(4)}@test.com")
    pl.verify_email! if verified
    PlayerClaim.claim!(player: pl, response: r, source: "signup")
    pl
  end

  def admin_for(o)
    u = User.create!(name: "U", email_address: "pn-a-#{SecureRandom.hex(3)}@test.com",
                     password: "verylongpassword")
    o.memberships.create!(user: u, role: "admin")
    post session_path, params: { email_address: u.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    u
  end

  def mails_to(player)
    ActionMailer::Base.deliveries.select { |m| m.to.include?(player.email_address) }
  end

  # ── Publishing what happened ──────────────────────────────────────────────

  test "publishing tells everyone who asked, exactly once" do
    s = with_impact(survey)
    a, b = keeper(s), keeper(s)
    admin_for(s.organisation)

    assert_difference -> { ActionMailer::Base.deliveries.size }, 2 do
      perform_enqueued_jobs { post survey_impact_path(s) }
    end

    assert s.reload.impact_published?
    assert_equal 1, mails_to(a).size
    assert_equal 1, mails_to(b).size
    assert_equal 2, PlayerNotification.where(survey_id: s.id, kind: "impact").count
    assert PlayerNotification.where(survey_id: s.id).all? { |n| n.sent_at.present? }
  end

  test "a second publish is refused, and nobody is mailed again" do
    s = with_impact(survey)
    keeper(s)
    admin_for(s.organisation)
    perform_enqueued_jobs { post survey_impact_path(s) }
    before = ActionMailer::Base.deliveries.size

    perform_enqueued_jobs { post survey_impact_path(s) }

    assert_redirected_to survey_path(s, panel: "publish", impact_error: "already")
    assert_equal before, ActionMailer::Base.deliveries.size
  end

  test "a replayed job cannot mail the same person twice" do
    # The button is guarded by impact_published_at; this is the belt to that
    # pair of braces — a retried job, or two workers racing, resolve to one
    # mail on the unique index rather than on a check they could both pass.
    s = with_impact(survey)
    keeper(s)
    s.update_column(:impact_published_at, Time.current)

    perform_enqueued_jobs { NotifyPlayersJob.perform_now(s.id, "impact") }
    before = ActionMailer::Base.deliveries.size
    perform_enqueued_jobs { NotifyPlayersJob.perform_now(s.id, "impact") }

    assert_equal before, ActionMailer::Base.deliveries.size
  end

  test "an impact with nothing written cannot be published" do
    # A headline on its own is a promise, not an outcome — and refusing an
    # empty one is what stops a misfire spending the single send this Verto
    # gets.
    s = survey(impact_headline: "We did a thing")
    keeper(s)
    admin_for(s.organisation)

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      perform_enqueued_jobs { post survey_impact_path(s) }
    end
    assert_redirected_to survey_path(s, panel: "publish", impact_error: "incomplete")
    assert_not s.reload.impact_published?
  end

  test "the mail carries what changed and both ways to stop it" do
    s = with_impact(survey)
    pl = keeper(s)
    admin_for(s.organisation)
    perform_enqueued_jobs { post survey_impact_path(s) }

    mail = mails_to(pl).sole
    body = (mail.text_part || mail).body.to_s
    assert_match "The High Street closes at weekends from March", body
    assert_match "Deliveries move to a 7–10am window", body
    assert_match "https://haverley.example/report", body
    assert_match s.organisation.name, mail.subject

    token = PlayerNotification.find_by(player_id: pl.id, survey_id: s.id).token
    assert_match player_unsubscribe_url(token, scope: "organisation"), body
    assert_match player_unsubscribe_url(token, scope: "all"), body
    # RFC 8058: a mail client's own button reaches the NARROW one, because that
    # is what the reader thinks they are stopping — this sender.
    assert_equal "<#{player_unsubscribe_url(token, scope: 'organisation')}>",
                 mail["List-Unsubscribe"].to_s
  end

  # A mailer action runs inside a Solid Queue job, which has no request and so
  # no Current.locale — the reader's language has to be applied explicitly, and
  # applied to the WHOLE message. The subject used to be rendered at the call
  # site, outside PlayerNotificationMailer#deliver_as's with_locale block, so a
  # French respondent would have got an English subject over a French body. It
  # was invisible until these strings were translated: while they lived in
  # en.yml alone, both halves came out English and agreed.
  test "the whole mail is in the reader's language, subject included" do
    s = with_impact(survey)
    pl = keeper(s)
    pl.update!(preferred_locale: "fr")
    admin_for(s.organisation)

    assert_equal :en, I18n.locale, "the job's ambient locale is the default, not the reader's"
    perform_enqueued_jobs { post survey_impact_path(s) }

    mail = mails_to(pl).sole
    assert_equal I18n.t("player_notification_mailer.impact.subject_org",
                        org: s.organisation.name, locale: :fr),
                 mail.subject
    assert_match I18n.t("player_notification_mailer.why", locale: :fr),
                 (mail.text_part || mail).body.to_s
  end

  test "a reader with no preferred locale still gets English" do
    s = with_impact(survey)
    pl = keeper(s)
    admin_for(s.organisation)
    perform_enqueued_jobs { post survey_impact_path(s) }

    assert_equal I18n.t("player_notification_mailer.impact.subject_org",
                        org: s.organisation.name, locale: :en),
                 mails_to(pl).sole.subject
  end

  # ── Who is never mailed ───────────────────────────────────────────────────

  test "an address nobody proved they own is never mailed" do
    s = with_impact(survey)
    unverified = keeper(s, verified: false)
    admin_for(s.organisation)

    perform_enqueued_jobs { post survey_impact_path(s) }

    assert_empty mails_to(unverified)
  end

  test "an opt-out from this organisation is honoured, and reaches no further" do
    a = org("Haverley")
    b = org("Riverside Youth Trust")
    mine, theirs = with_impact(survey(owner: a)), with_impact(survey(owner: b))
    pl = keeper(mine)
    PlayerClaim.claim!(player: pl,
                       response: theirs.responses.create!(session_token: SecureRandom.uuid,
                                                          status: "completed", answered: true),
                       source: "signup")
    PlayerEmailPreference.unsubscribe!(player: pl, organisation: a)

    perform_enqueued_jobs do
      NotifyPlayersJob.perform_now(mine.id, "impact")
      NotifyPlayersJob.perform_now(theirs.id, "impact")
    end

    assert_equal 1, mails_to(pl).size, "silenced one organisation, not both"
    assert_match "Riverside Youth Trust", mails_to(pl).sole.subject
  end

  test "a globally suppressed address is never mailed" do
    s = with_impact(survey)
    pl = keeper(s)
    EmailSuppression.record!(pl.email_address, reason: "hard_bounce")

    perform_enqueued_jobs { NotifyPlayersJob.perform_now(s.id, "impact") }

    assert_empty mails_to(pl)
  end

  test "somebody who unsubscribes mid-send is not mailed by the batch already in flight" do
    s = with_impact(survey)
    pl = keeper(s)
    PlayerEmailPreference.unsubscribe!(player: pl, organisation: s.organisation)

    # The scope is rebuilt per batch, but deliverable? is what makes each
    # individual send correct even when the scope is a minute old.
    assert_not PlayerAudience.deliverable?(pl, s)
    perform_enqueued_jobs { NotifyPlayersJob.perform_now(s.id, "impact") }
    assert_empty mails_to(pl)
  end

  # ── The two links ─────────────────────────────────────────────────────────

  def notification_for(s, pl)
    PlayerNotification.claim(player: pl, survey: s, kind: "impact")
  end

  test "loading the unsubscribe page changes nothing" do
    # Corporate scanners follow GETs. One must not be able to opt a person out.
    s = with_impact(survey)
    pl = keeper(s)
    n = notification_for(s, pl)

    get player_unsubscribe_path(n.token, scope: "all")

    assert_response :success
    assert_equal 0, PlayerEmailPreference.count
    assert_equal 0, EmailSuppression.count
  end

  test "the narrow link stops one organisation and touches nothing else" do
    s = with_impact(survey)
    pl = keeper(s)
    n = notification_for(s, pl)

    post player_unsubscribe_path(n.token, scope: "organisation")

    assert_response :success
    assert_select ".you-h1", text: I18n.t("player_unsubscribe.done_title"),
                  count: 1
    assert PlayerEmailPreference.unsubscribed?(pl.id, s.organisation_id)
    assert_equal 0, EmailSuppression.count,
                 "a respondent muting one council must not silence a creator's own mail"
  end

  test "the wide link means what it says" do
    s = with_impact(survey)
    pl = keeper(s)
    n = notification_for(s, pl)

    post player_unsubscribe_path(n.token, scope: "all")

    assert EmailSuppression.exists?(email: pl.email_address)
  end

  test "a missing or malformed scope fails toward the smaller consequence" do
    s = with_impact(survey)
    pl = keeper(s)
    n = notification_for(s, pl)

    post player_unsubscribe_path(n.token), params: { scope: "everything" }

    assert PlayerEmailPreference.unsubscribed?(pl.id, s.organisation_id)
    assert_equal 0, EmailSuppression.count
  end

  test "unsubscribing twice is a no-op, not an error" do
    s = with_impact(survey)
    pl = keeper(s)
    n = notification_for(s, pl)

    post player_unsubscribe_path(n.token, scope: "organisation")
    first = PlayerEmailPreference.sole.unsubscribed_at
    post player_unsubscribe_path(n.token, scope: "organisation")

    assert_response :success
    assert_equal 1, PlayerEmailPreference.count
    assert_equal first, PlayerEmailPreference.sole.reload.unsubscribed_at
  end

  test "the unsubscribe form opts out of Turbo, so the confirmation is actually shown" do
    # This action renders its confirmation rather than redirecting — there is
    # no page to redirect to that still knows which of the two things was done
    # — and Turbo Drive silently discards a 200 HTML response to a form post.
    # Without this the write lands and the person sees nothing change, which
    # on an unsubscribe means they press it again and then complain. Found in
    # a browser, not here: the request test sees the rendered body either way.
    s = with_impact(survey)
    n = notification_for(s, keeper(s))

    get player_unsubscribe_path(n.token)

    assert_select "form[data-turbo=false]", 1
  end

  test "an unknown token says the link expired rather than erroring" do
    get player_unsubscribe_path("no-such-token")
    assert_response :success
    assert_select ".you-h1", text: I18n.t("player_unsubscribe.expired_title")
  end

  # ── Follow-ups ────────────────────────────────────────────────────────────

  test "a follow-up notice names the Verto they played as the reason" do
    o = org
    first  = survey(owner: o)
    second = survey(owner: o, theme: "High Street, one year on")
    first.update!(follow_up_survey_ids: [ second.id ])
    pl = keeper(first)
    admin_for(o)

    perform_enqueued_jobs { post survey_follow_up_notice_path(first) }

    body = (mails_to(pl).sole.text_part || mails_to(pl).sole).body.to_s
    assert_match "Car-free High Street", body, "the reason is on the card, always"
    assert_match "High Street, one year on", body
    assert_match play_survey_url(second.publish_token), body
  end

  test "a Verto pointing nowhere has nothing to announce" do
    s = survey
    keeper(s)
    admin_for(s.organisation)

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      perform_enqueued_jobs { post survey_follow_up_notice_path(s) }
    end
    assert_redirected_to survey_path(s, panel: "publish", impact_error: "no_follow_up")
  end

  test "a follow-up can only point at the creator's own Vertos" do
    mine  = survey
    other = survey(owner: org("Someone else"))
    admin_for(mine.organisation)

    post survey_settings_path(mine), params: { follow_up_survey_ids: [ other.id, mine.id ] }

    assert_empty mine.reload.follow_up_survey_ids,
                 "a picker is a suggestion, not an authorisation"
  end

  test "an unpublished or deleted follow-up drops out rather than sending anyone to a dead link" do
    o = org
    first = survey(owner: o)
    gone  = survey(owner: o)
    first.update!(follow_up_survey_ids: [ gone.id ])
    assert_equal 1, first.follow_up_surveys.size

    gone.update_column(:unpublished_at, Time.current)
    assert_empty first.reload.follow_up_surveys
  end

  # ── What a duplicate carries ──────────────────────────────────────────────

  test "duplicating carries the promise but never the impact or the follow-ups" do
    o = org
    other = survey(owner: o)
    s = with_impact(survey(owner: o,
                           next_step_headline: "The council decides on 14 October",
                           next_step_body: "We publish in November."))
    s.update!(impact_published_at: Time.current, follow_up_survey_ids: [ other.id ])

    copy = s.duplicate!

    assert_equal "The council decides on 14 October", copy.next_step_headline
    assert_equal "We publish in November.", copy.next_step_body
    assert_nil copy.impact_headline, "a brand-new Verto must not claim to have already changed something"
    assert_nil copy.impact_published_at
    assert_empty Array(copy.follow_up_survey_ids)
  end

  # ── What the account shows ────────────────────────────────────────────────

  def sign_in_as(pl)
    _link, raw = PlayerSignInLink.mint!(player: pl)
    post player_sign_in_path(raw)
  end

  test "the account shows the promise, then the impact, and is honest in between" do
    s = survey
    pl = keeper(s)
    sign_in_as(pl)

    # 3 — the commonest state, and it must not read as an error.
    get you_verto_path(s)
    assert_select ".you-sub", text: I18n.t("you.impact_none", org: s.organisation.name)

    # 1 — the promise, written when they published.
    s.update!(next_step_headline: "The council decides on 14 October")
    get you_verto_path(s)
    assert_select ".you-impact-headline", text: "The council decides on 14 October"

    # 2 — what actually happened.
    with_impact(s).update!(impact_published_at: Time.current)
    get you_verto_path(s)
    assert_select ".you-h2", text: I18n.t("you.impact_title")
    assert_select ".you-impact-change", text: /Deliveries move/
  end

  test "a follow-up sits on the Verto that points at it, and not one already played" do
    o = org
    played = survey(owner: o)
    fresh  = survey(owner: o, theme: "High Street, one year on")
    already = survey(owner: o, theme: "Already done this one")
    played.update!(follow_up_survey_ids: [ fresh.id, already.id ])

    pl = keeper(played)
    PlayerClaim.claim!(player: pl,
                       response: already.responses.create!(session_token: SecureRandom.uuid,
                                                           status: "completed", answered: true),
                       source: "signup")
    sign_in_as(pl)

    get you_path

    # In the What's next section, carrying the reason — the Verto that points
    # — on the card, so nothing is offered without saying why.
    assert_select "#next .you-verto.is-next .you-verto-title", text: "High Street, one year on"
    assert_select "#next .you-verto-because",
                  text: I18n.t("you.next_because", verto: "Car-free High Street")
    # And the one they have already played is not offered back to them.
    assert_select "#next .you-verto-title", text: "Already done this one", count: 0
    assert_select "#next .you-verto", 1
  end

  test "a Verto pointing nowhere draws no What's next section at all" do
    s = survey
    sign_in_as(keeper(s))

    get you_path

    assert_select ".you-verto", 1
    assert_select "#next", 0
  end

  test "only an admin can spend the organisation's one contact with a respondent" do
    # Admin-only in the company of #contacts rather than of #publish: this is
    # outward-facing, irreversible in a way unpublishing is not, and it spends
    # the single contact this organisation gets with each of these people.
    s = with_impact(survey)
    keeper(s)
    member = User.create!(name: "M", email_address: "pn-m-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    s.organisation.memberships.create!(user: member, role: "member")
    post session_path, params: { email_address: member.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      perform_enqueued_jobs do
        post survey_impact_path(s)
        post survey_follow_up_notice_path(s)
      end
    end
    assert_not s.reload.impact_published?
  end

  # ── What the creator sees ─────────────────────────────────────────────────

  # The results page used to carry an "N asked to hear" tile beside the
  # response count. It was removed on the owner's instruction, 2026-09-23 — a
  # third number in a row of two that describe the results themselves, and the
  # only one of the three that was not about the answers.
  #
  # The claims it counted are untouched: they are what the follow-up mail is
  # sent to, which is what every other test in this file is about. This one
  # holds the removal, so a tile does not quietly come back with a count of
  # people on a page that no longer explains who they are.
  test "the results page does not show who asked to hear" do
    s = survey
    keeper(s)
    admin_for(s.organisation)

    get survey_results_path(s)
    assert_response :success
    assert_no_match(/asked to hear/, response.body)
    assert_equal 1, s.player_claims.count, "the claim itself still stands; only its tile went"
  end
end
