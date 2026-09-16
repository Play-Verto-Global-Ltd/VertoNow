require "test_helper"

# Share links: the dashboard's Share modal and the named /play/ addresses it
# manages. The per-link comparison override matters even though the modal no
# longer edits it (2026-08-17 simplification): links created before then still
# carry overrides, the player still honours them, so the tests below check BOTH
# the page and the endpoint that would otherwise hand the aggregate over anyway.
class ShareLinksTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def sign_in_org(suffix, role: "admin")
    user = User.create!(name: "U", email_address: "sl-#{suffix}-#{SecureRandom.hex(2)}@test.com",
                        password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "sl-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: role)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def published_survey(org, **attrs)
    org.surveys.create!({ title: "T", theme: "T", audience_age: "all", key_insight: "x",
                          default_locale: "en", locales: [ "en" ], cards: CARDS,
                          publish_token: SecureRandom.urlsafe_base64(18),
                          published_at: Time.current }.merge(attrs))
  end

  # ── The dashboard CTA ─────────────────────────────────────────────────────

  test "a live Verto's card leads with Send, a draft's does not" do
    org = sign_in_org("cta")
    published_survey(org, title: "Live one")
    org.surveys.create!(title: "Draft one", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS)

    get root_path
    assert_response :success
    assert_select "button[data-action='click->share-modal#open']", 1
    assert_select "[data-share-modal-target='modal']", 1
  end

  # Every role gets the button and the panel — handing the link on is what
  # every seat is for (the viewer role exists for exactly that). What a
  # non-admin does NOT get is any of the panel's forms: those post to
  # admin-only endpoints, so they're drawn on the same answer. See
  # viewer_role_test for the viewer's side of this.
  test "a non-admin member gets the Share button and a read-only panel" do
    org = sign_in_org("member", role: "member")
    survey = published_survey(org)

    get root_path
    assert_select "button[data-action='click->share-modal#open']", 1

    get share_survey_path(survey)
    assert_response :success
    assert_select "input#share-url-main[value=?]", play_survey_url(survey.publish_token)
    assert_select "form", 0, "a non-admin's panel should carry no forms at all"
  end

  test "the link mutations stay admin-only for a non-admin member" do
    org = sign_in_org("member-mut", role: "member")
    survey = published_survey(org)

    assert_no_difference "SurveyLink.count" do
      post survey_links_path(survey), params: { name: "Nope" }
      assert_redirected_to root_path
    end
  end

  # ── The panel ─────────────────────────────────────────────────────────────

  test "the Share panel renders inside the turbo frame with the live link" do
    org = sign_in_org("panel")
    survey = published_survey(org)

    get share_survey_path(survey)
    assert_response :success
    assert_select "turbo-frame#share-modal"
    assert_select "input#share-url-main[value=?]", play_survey_url(survey.publish_token)
  end

  test "the panel says a draft isn't live yet but still manages links" do
    org = sign_in_org("draft-panel")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)

    get share_survey_path(draft)
    assert_response :success
    assert_select ".share-notice__title"
    assert_select "input#share-url-main", 0
    assert_select "form[action=?]", survey_links_path(draft)
  end

  test "a Verto in another organisation is not reachable" do
    other = Organisation.create!(name: "X", slug: "sl-x-#{SecureRandom.hex(3)}")
    theirs = published_survey(other)
    sign_in_org("cross")

    get share_survey_path(theirs)
    assert_response :not_found
  end

  # ── Creating and editing links ────────────────────────────────────────────

  test "creating a link derives a slug from its name" do
    org = sign_in_org("create")
    survey = published_survey(org)

    post survey_links_path(survey), params: { name: "Control Group!" }
    assert_redirected_to share_survey_path(survey)
    link = survey.survey_links.sole
    assert_equal "Control Group!", link.name
    assert_equal "control-group", link.slug
    assert link.active?
    # Nothing pinned: the link follows the Verto until someone says otherwise.
    assert_nil link.show_results_comparison
  end

  test "a requested custom URL is used, and de-collided rather than rejected" do
    org = sign_in_org("collide")
    survey = published_survey(org)

    post survey_links_path(survey), params: { name: "A", slug: "newsletter" }
    post survey_links_path(survey), params: { name: "B", slug: "Newsletter" }

    slugs = survey.survey_links.ordered.pluck(:slug)
    assert_equal [ "newsletter", "newsletter-2" ], slugs
  end

  test "a link cannot claim a slug another Verto's publish token already holds" do
    org = sign_in_org("ns")
    other = published_survey(org)
    other.update_column(:publish_token, "already-lowercase-token")
    survey = published_survey(org)

    post survey_links_path(survey), params: { name: "N", slug: "already-lowercase-token" }
    assert_equal "already-lowercase-token-2", survey.survey_links.sole.slug
  end

  test "a Verto's own custom slug cannot take a share link's address" do
    org = sign_in_org("reverse-ns")
    survey = published_survey(org)
    other  = published_survey(org)
    other.survey_links.create!(name: "N", slug: "town-hall")

    post survey_settings_path(survey), params: { slug: "town-hall", return_to: "share" }
    assert_nil survey.reload.slug
    assert_includes response.headers["Location"], "slug_error=taken"
    assert_includes response.headers["Location"], "/share"
  end

  test "settings posted from the modal come back to the modal" do
    org = sign_in_org("return-to")
    survey = published_survey(org)

    post survey_settings_path(survey), params: { show_results_comparison: "1", return_to: "share" }
    assert_redirected_to share_survey_path(survey)
    assert survey.reload.show_results_comparison?
  end

  test "renaming a link leaves its address alone" do
    org = sign_in_org("rename")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Old", slug: "keep-this")

    patch survey_link_path(survey, link), params: { name: "New name" }
    assert_equal "New name", link.reload.name
    assert_equal "keep-this", link.slug
  end

  test "a link's address can be changed deliberately, but not onto a taken one" do
    org = sign_in_org("readdress")
    survey = published_survey(org)
    link  = survey.survey_links.create!(name: "A", slug: "one")
    survey.survey_links.create!(name: "B", slug: "two")

    patch survey_link_path(survey, link), params: { slug: "One Two Three" }
    assert_equal "one-two-three", link.reload.slug

    patch survey_link_path(survey, link), params: { slug: "two" }
    assert_equal "one-two-three", link.reload.slug
    assert_includes response.headers["Location"], "link_error=taken"
  end

  test "the per-Verto link cap is enforced" do
    org = sign_in_org("cap")
    survey = published_survey(org)
    SurveyLink::MAX_PER_SURVEY.times { |i| survey.survey_links.create!(name: "L#{i}", slug: "cap-#{i}") }

    assert_no_difference -> { SurveyLink.count } do
      post survey_links_path(survey), params: { name: "One too many" }
    end
    assert_includes response.headers["Location"], "link_error=limit"
  end

  test "deleting a link keeps the responses collected through it" do
    org = sign_in_org("delete")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "A", slug: "gone-soon")
    resp = survey.responses.create!(session_token: SecureRandom.uuid, survey_link: link, answered: true)

    assert_difference -> { SurveyLink.count }, -1 do
      delete survey_link_path(survey, link)
    end
    assert_nil resp.reload.survey_link_id
    assert_equal survey.id, resp.survey_id
  end

  # ── The player ────────────────────────────────────────────────────────────

  test "the player resolves a Verto by a share link's slug" do
    org = sign_in_org("resolve")
    survey = published_survey(org)
    survey.survey_links.create!(name: "Newsletter", slug: "news-2026")

    get play_survey_path("news-2026")
    assert_response :success
    assert_select ".q-title", text: "Q"
  end

  test "a paused link stops resolving, for reads and writes alike" do
    org = sign_in_org("paused")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Off", slug: "switched-off")

    patch survey_link_path(survey, link), params: { active: "0" }
    assert_not link.reload.active?

    get play_survey_path("switched-off")
    assert_response :not_found

    post progress_survey_path("switched-off"),
         params: { session_token: SecureRandom.uuid, answers: {} }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
  end

  test "a share link's slug does not reach an unpublished Verto" do
    org = sign_in_org("draft-link")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)
    draft.survey_links.create!(name: "Early", slug: "too-early")

    get play_survey_path("too-early")
    assert_response :gone
  end

  test "a respondent arriving on a link is attributed to it" do
    org = sign_in_org("attribute")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Newsletter", slug: "attrib-me")

    post progress_survey_path("attrib-me"),
         params: { session_token: "tok-#{SecureRandom.hex(4)}", answers: { "1" => { "value" => "Yes" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal link.id, survey.responses.sole.survey_link_id
  end

  # ── The whole point: one link compares, another doesn't ───────────────────

  test "a link can turn comparison on where the Verto has it off" do
    org = sign_in_org("compare-on")
    survey = published_survey(org, show_results_comparison: false)
    survey.survey_links.create!(name: "Cohort", slug: "compare-yes", show_results_comparison: true)

    get play_survey_path(survey.publish_token)
    assert_select ".welcome-intake-compare", 0

    get play_survey_path("compare-yes")
    assert_select ".welcome-intake-compare", 1
  end

  test "a link can turn comparison off where the Verto has it on" do
    org = sign_in_org("compare-off")
    survey = published_survey(org, show_results_comparison: true)
    survey.survey_links.create!(name: "Control", slug: "compare-no", show_results_comparison: false)

    get play_survey_path(survey.publish_token)
    assert_select ".welcome-intake-compare", 1

    get play_survey_path("compare-no")
    assert_select ".welcome-intake-compare", 0
  end

  test "the results endpoint refuses a link that has comparison off" do
    org = sign_in_org("compare-endpoint")
    survey = published_survey(org, show_results_comparison: true)
    survey.survey_links.create!(name: "Control", slug: "no-peeking", show_results_comparison: false)
    Response::MIN_REGION_SAMPLE_SIZE.times do
      survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                               answers: { "1" => { "value" => "Yes" } })
    end

    get player_results_path(survey.publish_token)
    assert_response :success
    assert JSON.parse(response.body)["ok"]

    # Hiding the button would not be enough — the endpoint is reachable by hand.
    get player_results_path("no-peeking")
    assert_response :forbidden
  end

  test "a link with no override follows the Verto" do
    org = sign_in_org("inherit")
    survey = published_survey(org, show_results_comparison: true)
    survey.survey_links.create!(name: "Plain", slug: "follows-verto")

    get play_survey_path("follows-verto")
    assert_select ".welcome-intake-compare", 1

    survey.update!(show_results_comparison: false)
    get play_survey_path("follows-verto")
    assert_select ".welcome-intake-compare", 0
  end

  test "the share button and regions map can be overridden per link too" do
    org = sign_in_org("other-overrides")
    survey = published_survey(org, share_enabled: true, regions_enabled: true)
    survey.survey_links.create!(name: "Quiet", slug: "quiet-link",
                                share_enabled: false, regions_enabled: false)

    get play_survey_path(survey.publish_token)
    body = response.body
    assert_includes body, play_survey_url(survey.publish_token)
    assert_includes body, player_regions_url(survey.publish_token)

    get play_survey_path("quiet-link")
    assert_not_includes response.body, player_regions_url("quiet-link")
  end

  # ── The simplified panel: recall, Test Mode, unpublish ────────────────────

  test "the modal keeps sharing simple — no override selects or settings checkboxes" do
    org = sign_in_org("simple")
    survey = published_survey(org)
    survey.survey_links.create!(name: "Newsletter", slug: "simple-check")

    get share_survey_path(survey)
    assert_response :success
    assert_select "select", 0
    assert_select "input[type=checkbox]", 0
  end

  test "an active link offers Recall, a recalled one offers Restore" do
    org = sign_in_org("recall")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Poster", slug: "recall-me")

    get share_survey_path(survey)
    assert_select "form[action=?] input[name=active][value='0']", survey_link_path(survey, link)

    link.update!(active: false)
    get share_survey_path(survey)
    assert_select "form[action=?] input[name=active][value='1']", survey_link_path(survey, link)
    assert_select ".share-link--paused", 1
  end

  test "a live Verto's modal offers Convert to Test Mode and Unpublish" do
    org = sign_in_org("tm-offer")
    survey = published_survey(org)

    get share_survey_path(survey)
    assert_select "form[action=?]", test_mode_survey_path(survey)
    assert_select "form[action=?]", unpublish_survey_path(survey, return_to: "share")
  end

  # The player's press-and-hold hatch is hidden from RESPONDENTS by design, but
  # it was hidden from the creator too — nothing anywhere named the gesture or
  # the address it leads to, so the only people who could use it were the ones
  # who had read the source. The modal is the right place to say it: signed in,
  # and the screen the creator is on when they hand the link out.
  test "a live Verto's modal names the in-player route into Test Mode" do
    org = sign_in_org("tm-live")
    survey = published_survey(org)

    get share_survey_path(survey)
    assert_select "input#share-url-live-test[value=?]", live_test_survey_url(survey.publish_token)
    assert_select ".share-hint", text: /Start test mode/
  end

  # It has to follow the address respondents actually use, not just the raw
  # token — a Verto with a vanity slug hands that out, and /test/live resolves
  # by the same four-way lookup, so pointing at the token here would send the
  # creator somewhere they never share.
  test "the in-player route follows the vanity slug when there is one" do
    org = sign_in_org("tm-slug")
    survey = published_survey(org, slug: "open-day")

    get share_survey_path(survey)
    assert_select "input#share-url-live-test[value=?]", live_test_survey_url("open-day")
  end

  # Nothing to enter Test Mode FROM: a draft has no live link, and a Verto
  # already converted has been taken off /play, so the hatch has no page to sit
  # on. Offering the address either way would be a link straight to a 410.
  test "a draft and a converted Verto get no in-player route" do
    org = sign_in_org("tm-nolive")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)
    get share_survey_path(draft)
    assert_select "input#share-url-live-test", 0

    converted = published_survey(org)
    post test_mode_survey_path(converted)
    get share_survey_path(converted)
    assert_select "input#share-url-live-test", 0
  end

  test "converting to Test Mode takes the Verto off /play and mints a test link" do
    org = sign_in_org("tm-convert")
    survey = published_survey(org)

    post test_mode_survey_path(survey)
    assert_redirected_to share_survey_path(survey)

    survey.reload
    assert_not survey.published?
    assert survey.test_token.present?

    get play_survey_path(survey.publish_token)
    assert_response :gone
    get test_survey_path(survey.test_token)
    assert_response :success
  end

  test "converting to Test Mode keeps an existing test link instead of rotating it" do
    org = sign_in_org("tm-keep")
    survey = published_survey(org, test_token: "already-testing")

    post test_mode_survey_path(survey)
    assert_equal "already-testing", survey.reload.test_token
  end

  test "a draft's modal offers Create test link rather than Convert" do
    org = sign_in_org("tm-draft")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)

    get share_survey_path(draft)
    assert_select "form[action=?]", test_link_survey_path(draft, return_to: "share")
    assert_select "form[action=?]", test_mode_survey_path(draft), 0
    assert_select "form[action=?]", unpublish_survey_path(draft, return_to: "share"), 0
  end

  test "the modal shows the test link once Test Mode is on, and can turn it off" do
    org = sign_in_org("tm-show")
    survey = published_survey(org, test_token: "show-me-testing")

    get share_survey_path(survey)
    assert_select "input#share-url-test[value=?]", test_survey_url("show-me-testing")

    delete test_link_survey_path(survey, return_to: "share")
    assert_redirected_to share_survey_path(survey)
    assert_nil survey.reload.test_token
  end

  test "unpublish posted from the modal comes back to the modal" do
    org = sign_in_org("unpub")
    survey = published_survey(org)

    post unpublish_survey_path(survey, return_to: "share")
    assert_redirected_to share_survey_path(survey)
    assert_not survey.reload.published?

    # Off the modal, the editor keeps its own redirect.
    survey.update!(unpublished_at: nil)
    post unpublish_survey_path(survey)
    assert_redirected_to survey_path(survey)
  end

  # ── QR ────────────────────────────────────────────────────────────────────

  test "a link gets its own downloadable QR code" do
    org = sign_in_org("qr")
    survey = published_survey(org)
    link = survey.survey_links.create!(name: "Poster", slug: "poster-link")

    get qr_survey_path(survey, link_id: link.id)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_includes response.headers["Content-Disposition"], "poster-link-qr.svg"

    get qr_survey_path(survey, link_id: link.id, format: :png)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_includes response.headers["Content-Disposition"], "poster-link-qr.png"
  end

  test "a draft's link has no QR to download" do
    org = sign_in_org("qr-draft")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)
    link = draft.survey_links.create!(name: "Poster", slug: "draft-poster")

    get qr_survey_path(draft, link_id: link.id)
    assert_response :not_found
  end

  # ── Every field that makes a link says how to commit it ────────────────────

  # Reported as "I can't seem to find the generate custom links option — the
  # user needs to press enter but that is non obvious". These fields have always
  # saved on Enter or on blur, and said so nowhere: one submittable input, no
  # button, and a creator who typed a link and looked for somewhere to click
  # found nothing. The Create link form below them has had a button all along,
  # which is what made the ones without read as not-a-form.
  test "every custom-link field in the share panel carries a visible submit" do
    org = sign_in_org("submit")
    survey = published_survey(org)
    survey.survey_links.create!(name: "Newsletter", slug: "news-letter")

    get share_survey_path(survey)
    assert_response :success

    assert_select "form.share-slug-form button[type=submit]", 1,
                  "the Custom URL field must offer a way to commit it that is not Enter"
    # The CLASS, not just the button: form_with drops a bare `style:` option on
    # the floor (it only passes class/id/data/aria through), so a rename row
    # styled inline laid itself out as a block and put Save on its own line
    # under the name. The class is what makes it a row.
    assert_select "form.share-link__rename input[name=name]", 1
    assert_select "form.share-link__rename button[type=submit]", 1, "so must renaming a link"
    # The one that was always right, kept honest.
    assert_select "form.share-new button[type=submit]", 1
  end

  # The reported complaint was "I can't find the custom links option in the
  # Share panel" — from a DRAFT, where the dashboard's Share button does not
  # appear and the editor had no way into the panel at all. The panel itself
  # has always handled a draft; it was simply unreachable.
  test "the editor opens the audience-links panel, draft or live" do
    org = sign_in_org("audience")
    draft = org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS)
    live = published_survey(org)

    [ draft, live ].each do |survey|
      get survey_path(survey)
      assert_response :success
      # Scoped to the publish panel: the phone dock has its own trigger for the
      # same modal, and this is about the desktop panel that had none.
      assert_select ".publish-panel button[data-action='click->share-modal#open'][data-panel-url=?]",
                    share_survey_path(survey), { count: 1 },
                    "#{survey.published? ? 'a live' : 'a draft'} Verto needs a way into the panel"
    end

    # And the panel it opens says what a draft can do rather than turning it away.
    get share_survey_path(draft)
    assert_response :success
    assert_select ".share-notice", text: /#{Regexp.escape(I18n.t('share_modal.not_live_body'))}/
    assert_select "form.share-new button[type=submit]", 1
  end

  test "a non-admin gets no audience-links entry point" do
    org = sign_in_org("audience-member", role: "member")
    survey = published_survey(org)

    get survey_path(survey)
    assert_response :success
    assert_select "button[data-action='click->share-modal#open']", { count: 0 },
                  "the panel behind it is admin-only, so the door must be too"
  end

  test "the editor's own custom-link field carries one too" do
    org = sign_in_org("submit-editor")
    survey = published_survey(org)

    get survey_path(survey)
    assert_response :success
    assert_select "form[action=?] input[name=slug]", survey_settings_path(survey), 1
    assert_select "form[action=?] button[type=submit]", survey_settings_path(survey), { minimum: 1 },
                  "the publish panel's custom link is the field the report was about"
  end
end
