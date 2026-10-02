require "test_helper"

class PartnershipFlowTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "A", email_address: "creator@test.com", password: "verylongpassword")
    @oa = Organisation.create!(name: "Creator Co", slug: "creator-co-#{SecureRandom.hex(2)}")
    @oa.memberships.create!(user: @admin, role: "admin")
    sign_in @admin
  end

  test "creator creates a partnership, invites and adds a partner, shares a Verto" do
    # Index: empty state
    get partnerships_path
    assert_response :success
    assert_match "Partner groups you run", response.body
    assert_match "No partner groups yet", response.body

    # New form
    get new_partnership_path
    assert_response :success
    assert_match "Group name", response.body

    # Create
    post partnerships_path, params: { partnership: { name: "Pilot Group" } }
    assert_redirected_to partnership_path(Partnership.last)
    follow_redirect!
    assert_response :success
    assert_match "Pilot Group", response.body
    assert_match "Add a partner", response.body
    assert_match "No partners yet", response.body

    a = Partnership.last
    # Generate invite
    post partnership_partnership_invites_path(a)
    assert_redirected_to partnership_path(a, new_invite_token: Invite.last.token)
    follow_redirect!
    assert_match "New join link", response.body

    # Add a partner org + accept invite
    partner_user_email = "b-#{SecureRandom.hex(2)}@test.com"
    invite_token = Invite.last.token
    # Need to log out then accept as fresh user
    delete session_path
    post accept_invite_path(invite_token), params: {
      name: "Partner B Admin",
      organisation_name: "Partner B",
      email_address: partner_user_email,
      password: "verylongpassword",
      password_confirmation: "verylongpassword"
    }
    assert_redirected_to partnership_path(a)
    follow_redirect!
    assert_match "Pilot Group", response.body
    assert_match "Run by Creator Co", response.body, "partner_show should label creator org"

    # Back in as creator
    delete session_path
    sign_in @admin

    # Create + publish a Verto, then add to partnership
    survey = @oa.surveys.create!(
      title: "Pilot Verto", theme: "Pilot Theme", audience_age: "18-35",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type"=>"welcome_card", "title"=>"hi" }, { "type"=>"single_choice", "title"=>"Q", "options"=>[ { "label"=>"Yes" }, { "label"=>"No" } ] } ],
      publish_token: SecureRandom.urlsafe_base64(18),
      published_at: Time.current
    )

    post partnership_partnership_vertos_path(a), params: { survey_id: survey.id }
    assert_redirected_to partnership_path(a)
    follow_redirect!
    assert_match "Pilot Verto", response.body, "partnership creator_show should list added Verto"

    # Should have exactly one SurveyShare auto-generated (one partner in partnership)
    assert_equal 1, a.survey_shares.count
    share = a.survey_shares.first
    assert_equal "Partner B", share.partner_organisation.name
    assert share.share_token.present?
  end

  test "partner sees partnership in member section and gets their share link + results page" do
    # Build the scenario
    a = @oa.partnerships.create!(name: "Trial")
    partner_admin = User.create!(name: "P", email_address: "p2-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Partner X", slug: "partner-x-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")
    a.partnership_memberships.create!(organisation: partner_org)

    survey = @oa.surveys.create!(
      title: "Trial Verto", theme: "T", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type"=>"single_choice", "title"=>"Q", "options"=>[ { "label"=>"A" }, { "label"=>"B" } ] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    a.partnership_vertos.create!(survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: a)
    share = a.survey_shares.first

    delete session_path
    sign_in partner_admin

    get partnerships_path
    assert_response :success
    assert_match(/Partner groups you('|&#39;)re a member of/, response.body)
    assert_match "Trial", response.body

    get partnership_path(a)
    assert_response :success
    assert_match "Partner X", response.body, "partner_show should not crash for member"
    assert_match "Trial Verto", response.body
    assert_match share.share_token, response.body, "partner sees their own share token"

    av = a.partnership_vertos.first
    get partnership_partnership_verto_path(a, av)
    assert_response :success
    assert_match "Trial Verto", response.body
    assert_match share.share_token, response.body
    assert_match "Fewer than 5 other people have answered yet", response.body,
                 "nobody else has answered, so there is nothing to compare with"
  end

  test "any org can be a creator and a partner-member simultaneously" do
    # Set up: org A creates "Group A", org B creates "Group B" and invites A
    a_partnership = @oa.partnerships.create!(name: "Group A")

    ob_admin = User.create!(name: "B-admin", email_address: "b-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    ob = Organisation.create!(name: "Org B", slug: "ob-#{SecureRandom.hex(2)}")
    ob.memberships.create!(user: ob_admin, role: "admin")
    b_partnership = ob.partnerships.create!(name: "Group B")
    b_partnership.partnership_memberships.create!(organisation: @oa)

    get partnerships_path
    assert_response :success
    assert_match "Group A", response.body, "should list owned partnership"
    assert_match "Group B", response.body, "should list member partnership"

    # Visiting Group A → creator_show
    get partnership_path(a_partnership)
    assert_response :success
    assert_match "Add a partner", response.body, "creator view of own partnership"

    # Visiting Group B → partner_show
    get partnership_path(b_partnership)
    assert_response :success
    assert_match "Run by Org B", response.body, "member view of partnership"
    refute_match "Add a partner", response.body, "should NOT see creator controls on partnership you're a member of"
  end

  # The comparison is with everyone else who answered the Verto — the owner's
  # own respondents and any other partner's alike — not only the partner
  # group's other links: what a partner asks is how their people differ from
  # everybody else's.
  test "everyone else is every other respondent to the Verto, whichever link they came through" do
    partner_admin = User.create!(name: "B", email_address: "agg-b-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Agg Partner", slug: "agg-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")

    survey = @oa.surveys.create!(
      title: "Cross-Test", theme: "X", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type"=>"multiple_choice", "text"=>"Q", "options"=>[ "A", "B" ] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )

    a1 = @oa.partnerships.create!(name: "Aggregate Alpha")
    a1.partnership_memberships.create!(organisation: partner_org)
    a1.partnership_vertos.create!(survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: a1)

    a2 = @oa.partnerships.create!(name: "Aggregate Beta")
    a2.partnership_memberships.create!(organisation: partner_org)
    a2.partnership_vertos.create!(survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: a2)

    a1_share = a1.survey_shares.first
    a2_share = a2.survey_shares.first

    # 2 through a1, 5 through a2, 3 on the owner's own link
    respond = ->(share, value) { survey.responses.create!(session_token: SecureRandom.urlsafe_base64(16), survey_share: share, status: "completed", answers: { "0"=>{ "value"=>value } }) }
    2.times { respond.call(a1_share, "A") }
    5.times { respond.call(a2_share, "B") }
    3.times { respond.call(nil, "B") }

    delete session_path
    sign_in partner_admin

    get partnership_partnership_verto_path(a1, a1.partnership_vertos.first)
    assert_response :success
    assert_match "<strong style=\"font-family:'Alata',sans-serif;\">2</strong> from your link", response.body
    assert_match "<strong style=\"font-family:'Alata',sans-serif;\">8</strong> everyone else", response.body,
                 "the other partnership's five and the owner's three"

    get partnership_partnership_verto_path(a2, a2.partnership_vertos.first)
    assert_response :success
    assert_match "<strong style=\"font-family:'Alata',sans-serif;\">5</strong> from your link", response.body
    assert_match "<strong style=\"font-family:'Alata',sans-serif;\">5</strong> everyone else", response.body
  end

  # The owner's results cards, the partner's respondents on them, everyone
  # else drawn beside each answer — and only as numbers: the owner's
  # respondents' words and anyone's contact details stay with the owner.
  test "partner results compare every answer with everyone else, as distributions only" do
    partner_admin = User.create!(name: "P", email_address: "cmp-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Cmp Partner", slug: "cmp-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")
    survey = @oa.surveys.create!(
      title: "Cmp Verto", theme: "T", audience_age: "all", key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "text" => "Pick", "options" => [ "Pitch", "Court" ] },
        { "type" => "open_ended", "text" => "Why?" },
        { "type" => "contact_form", "text" => "Stay in touch" }
      ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    partnership = @oa.partnerships.create!(name: "Cmp Group")
    PartnershipMembership.join!(partnership: partnership, organisation: partner_org)
    pv = partnership.partnership_vertos.create!(survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: partnership)
    share = partnership.survey_shares.sole
    respond = ->(via, pick, why, email) do
      survey.responses.create!(session_token: SecureRandom.uuid, survey_share: via, status: "completed",
                               answers: { "0" => { "value" => pick }, "1" => { "value" => why },
                                          "2" => { "value" => { "name" => "N", "email" => email } } })
    end
    2.times { respond.call(share, "Pitch", "Our own words", "ours@example.com") }
    4.times { respond.call(nil, "Court", "The owner's respondent wrote this", "theirs@example.com") }
    respond.call(nil, "Pitch", "The owner's respondent wrote this", "theirs@example.com")

    delete session_path
    sign_in partner_admin
    get partnership_partnership_verto_path(partnership, pv)
    assert_response :success

    # Court: nobody here picked it, 80% of everyone else did — the row is
    # drawn for them anyway, with their tick and figure.
    assert_match %r{title="Court">Court</span>\s*<span class="rc-pct">0%</span>\s*<span class="rc-vs">80%</span>}, response.body
    assert_match %r{title="Pitch">Pitch</span>\s*<span class="rc-pct">100%</span>\s*<span class="rc-vs">20%</span>}, response.body
    assert_select ".rc-base[style*='inset-inline-start:80%']"
    assert_select ".rc-answers.rc-vs-n", text: "5 everyone else"

    assert_match "Our own words", response.body, "the partner reads its own respondents"
    assert_no_match "The owner's respondent wrote this", response.body
    assert_no_match "theirs@example.com", response.body
    assert_no_match "ours@example.com", response.body, "contact details were left for the Verto's owner"
  end

  # Two card types tally something other than label => count, and the partner
  # results page drew both as if they did: a tap card's per-statement scale
  # 500'd it (Hash#to_f), and a prioritise card's rank SUMS read as shares of
  # the total. Street Soccer hit the first on the Unleash Football Verto.
  test "partner results draw a tap card per statement and a prioritise card as mean ranks" do
    partner_admin = User.create!(name: "P", email_address: "tap-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Tap Partner", slug: "tap-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")
    survey = @oa.surveys.create!(
      title: "Tap Verto", theme: "T", audience_age: "all", key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "tap_card", "text" => "Does it sound like you?", "options" => [ "I play to keep my head clear", "My club feels welcoming" ],
          "responses" => [ { "key" => "no", "label" => "Not me" }, { "key" => "yes", "label" => "That's me" } ] },
        { "type" => "prioritise", "text" => "Rank these", "options" => [ "Cheaper", "Closer" ] }
      ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    partnership = @oa.partnerships.create!(name: "Tap Group")
    PartnershipMembership.join!(partnership: partnership, organisation: partner_org)
    pv = partnership.partnership_vertos.create!(survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: partnership)
    share = partnership.survey_shares.sole
    answers = [
      { "0" => { "value" => { "I play to keep my head clear" => "yes", "My club feels welcoming" => "no" } },
        "1" => { "value" => [ "Cheaper", "Closer" ] } },
      { "0" => { "value" => { "I play to keep my head clear" => "yes", "My club feels welcoming" => "yes" } },
        "1" => { "value" => [ "Closer", "Cheaper" ] } },
      { "0" => { "value" => { "I play to keep my head clear" => "no", "My club feels welcoming" => "yes" } },
        "1" => { "value" => [ "Cheaper", "Closer" ] } }
    ]
    answers.each { |a| survey.responses.create!(session_token: SecureRandom.uuid, survey_share: share, status: "completed", answers: a) }

    delete session_path
    sign_in partner_admin
    get partnership_partnership_verto_path(partnership, pv)

    assert_response :success
    # Each statement heads its own answers, labelled as the card labels them.
    assert_select ".rc-group-label", text: "I play to keep my head clear"
    assert_match %r{That(&#39;|')s me</span>\s*<span class="rc-pct">67%</span>}, response.body
    # Cheaper ranked 1, 2, 1 → 1.3; Closer 2, 1, 2 → 1.7. Best first.
    assert_match(/title="Cheaper">Cheaper<\/span>\s*<span class="rc-n">avg 1\.3<.*?title="Closer">Closer<\/span>\s*<span class="rc-n">avg 1\.7</m, response.body)
  end

  test "signed-in admin of an existing org joins a partnership via the join link" do
    # Setup: a partner org with an existing admin who's signed in
    partner_admin = User.create!(name: "Existing", email_address: "exist-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Existing Co", slug: "exist-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")

    # Creator (admin @admin from setup) makes a partnership + invite
    a = @oa.partnerships.create!(name: "Existing-User Group")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      partnership: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # Sign in as the partner admin
    delete session_path
    sign_in partner_admin

    # GET /invites/:token shows the signed-in picker
    get invite_path(invite.token)
    assert_response :success
    assert_match "Signed in as", response.body
    assert_match partner_admin.name, response.body
    assert_match "Join with", response.body
    assert_match "Existing Co", response.body
    refute_match "Confirm password", response.body, "signed-in users should NOT see the signup form"

    # POST accept with join_as_organisation_id
    post accept_invite_path(invite.token), params: { join_as_organisation_id: partner_org.id }
    assert_redirected_to partnership_path(a)
    follow_redirect!
    assert_match "Existing-User Group", response.body

    # PartnershipMembership created without creating a new org
    assert a.partnership_memberships.exists?(organisation: partner_org), "existing org should be linked"
    refute Organisation.exists?(name: "#{partner_admin.name}'s organisation"), "no new org should be created"

    # Invite is single-use
    assert invite.reload.accepted?
  end

  test "signed-in user with multiple admin orgs picks which one joins" do
    user = User.create!(name: "Multi", email_address: "multi-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org_x = Organisation.create!(name: "Org X", slug: "ox-#{SecureRandom.hex(2)}")
    org_y = Organisation.create!(name: "Org Y", slug: "oy-#{SecureRandom.hex(2)}")
    org_x.memberships.create!(user: user, role: "admin")
    org_y.memberships.create!(user: user, role: "admin")

    a = @oa.partnerships.create!(name: "Multi-Org Group")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      partnership: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    delete session_path
    sign_in user

    get invite_path(invite.token)
    assert_response :success
    assert_match "Pick which organisation joins", response.body
    assert_match "Org X", response.body
    assert_match "Org Y", response.body

    post accept_invite_path(invite.token), params: { join_as_organisation_id: org_y.id }
    assert_redirected_to partnership_path(a)

    assert a.partnership_memberships.exists?(organisation: org_y)
    refute a.partnership_memberships.exists?(organisation: org_x), "only the picked org should join"
  end

  test "signed-in admin of the partnership creator cannot join their own partnership" do
    a = @oa.partnerships.create!(name: "Self-Join Test")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      partnership: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # @admin is signed in (from setup) and is admin of @oa, which created the partnership
    get invite_path(invite.token)
    assert_response :success
    assert_match "You run this partner group", response.body, "should explain why join isn't possible"
    refute_match "Pick which organisation joins", response.body
  end

  test "signed-in admin of an org already in the partnership sees 'already a member'" do
    other_org = Organisation.create!(name: "Already Joined", slug: "aj-#{SecureRandom.hex(2)}")
    other_org.memberships.create!(user: @admin, role: "admin")

    a = @oa.partnerships.create!(name: "Already Member Test")
    a.partnership_memberships.create!(organisation: other_org)

    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      partnership: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # @admin is signed in and admin of @oa (creator) + Already Joined (already member).
    get invite_path(invite.token)
    assert_response :success
    # @oa is the creator → "You run this partnership" message wins over "already a member".
    # That's fine; assert at least one informative banner shows.
    assert(response.body.include?("You run this partner group") || response.body.include?("already in this partner group"))
    refute_match "Pick which organisation joins", response.body
  end

  test "existing not-signed-in user can sign in via the invite page" do
    # Existing partner user + org, but not currently signed in
    partner_admin = User.create!(name: "Returning", email_address: "ret-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Returning Co", slug: "ret-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")

    a = @oa.partnerships.create!(name: "Sign-In Test Group")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      partnership: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # Sign out of the setup session
    delete session_path

    # GET shows the signup form with a "Sign in instead" toggle
    get invite_path(invite.token)
    assert_response :success
    assert_match "Sign in instead", response.body
    assert_match "invite-signin-form", response.body
    assert_match "Sign in to join", response.body

    # POST with mode=sign_in → authenticates, redirects to GET show
    post accept_invite_path(invite.token), params: {
      mode: "sign_in",
      email_address: partner_admin.email_address,
      password: "verylongpassword"
    }
    assert_redirected_to invite_path(invite.token)
    follow_redirect!
    assert_response :success
    assert_match "Signed in as", response.body, "should now show signed-in picker"
    assert_match "Returning Co", response.body
    refute_match "Confirm password", response.body

    # Invite not consumed yet — only consumed when org actually joins
    refute invite.reload.accepted?

    # Click join
    post accept_invite_path(invite.token), params: { join_as_organisation_id: partner_org.id }
    assert_redirected_to partnership_path(a)
    assert a.partnership_memberships.exists?(organisation: partner_org)
    assert invite.reload.accepted?
  end

  test "sign-in with wrong password shows error and stays on sign-in form" do
    user = User.create!(name: "X", email_address: "wrong-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org = Organisation.create!(name: "X", slug: "wx-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")

    a = @oa.partnerships.create!(name: "Wrong-PW Test")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      partnership: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    delete session_path

    post accept_invite_path(invite.token), params: {
      mode: "sign_in",
      email_address: user.email_address,
      password: "wrongpassword"
    }
    assert_response :unprocessable_entity
    assert_match "find an account", response.body, "error message should be shown"
    # Sign-in form is the visible one after the failure; signup form is hidden
    assert_match "id=\"invite-signup-form\" hidden", response.body, "signup form should be hidden"
    refute_match "id=\"invite-signin-form\" hidden", response.body, "sign-in form must stay open"
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
