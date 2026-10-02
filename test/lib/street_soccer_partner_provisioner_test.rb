require "test_helper"
require Rails.root.join("db/migrate/20261002090000_provision_street_soccer_partner_account")

# Street Soccer's partner account, opened by a data migration on deploy, which
# also hands Dan the Unleash Football link he was already sending people to.
# What matters: he ends up an ordinary partner who can see the respondents he
# gathered, the printed address keeps answering, and nothing runs twice —
# least of all the email.
class StreetSoccerPartnerProvisionerTest < ActionDispatch::IntegrationTest
  P = StreetSoccerPartnerProvisioner

  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  setup { ActionMailer::Base.deliveries.clear }

  def unleash
    @unleash ||= Organisation.create!(name: "Unleash Football", slug: "ssp-unleash-#{SecureRandom.hex(3)}")
  end

  def verto(**attrs)
    @verto ||= unleash.surveys.create!({ title: "Unleash", theme: "T", audience_age: "all", key_insight: "x",
                                         default_locale: "en", locales: [ "en" ], cards: CARDS,
                                         publish_token: SecureRandom.urlsafe_base64(18),
                                         published_at: Time.current }.merge(attrs))
  end

  def street_link(**attrs)
    verto.survey_links.create!({ name: "Street Football", slug: P::LINK_SLUG }.merge(attrs))
  end

  def respond(**attrs)
    verto.responses.create!({ session_token: SecureRandom.uuid, answered: true, status: "completed" }.merge(attrs))
  end

  def dan          = User.find_by(email_address: P::ADMIN_EMAIL)
  def street       = Organisation.find_by(slug: P::ORG_SLUG)
  def street_share = SurveyShare.find_by(partner_organisation: street)

  test "a database without the address gets nothing — no account, no email" do
    verto

    assert_nil P.new.call
    assert_nil dan
    assert_nil street
    assert_empty ActionMailer::Base.deliveries
  end

  test "Dan gets his own account, as its admin, and it can create Vertos" do
    street_link
    P.new.call

    assert_equal "Street Soccer", street.name
    assert street.verto_creation_enabled?, "a partner account is an ordinary one — it builds its own Vertos"
    assert_equal "Dan Wood", dan.name
    assert dan.password_pending?, "the password is a throwaway until Dan sets his own"
    assert_equal "admin", dan.memberships.find_by!(organisation: street).role
    assert_not dan.memberships.exists?(organisation: unleash), "a partner, not a member of Unleash Football"
  end

  test "Street Soccer is an active partner of the account that owns the Verto" do
    street_link
    P.new.call

    partnership = unleash.partnerships.sole
    assert_equal P::PARTNERSHIP_NAME, partnership.name
    assert partnership.partnership_memberships.active.exists?(organisation: street)
    assert_equal [ verto ], partnership.surveys.to_a
  end

  test "the link's address moves onto the share, and its respondents with it" do
    link     = street_link
    theirs   = 2.times.map { respond(survey_link: link) }
    direct   = respond
    other    = respond(survey_link: verto.survey_links.create!(name: "Newsletter", slug: "ssp-news-#{SecureRandom.hex(3)}"))

    result = P.new.call

    assert_equal P::LINK_SLUG, street_share.share_token
    assert_not SurveyLink.exists?(slug: P::LINK_SLUG), "two rows must not claim one /play address"
    assert result.link_adopted
    assert_equal 2, result.responses_moved
    theirs.each do |r|
      r.reload
      assert_equal street_share.id, r.survey_share_id
      assert_nil r.survey_link_id
    end
    assert_nil direct.reload.survey_share_id, "the Verto's own respondents stay Unleash Football's"
    assert_nil other.reload.survey_share_id, "another link's respondents are not Dan's"
    assert other.survey_link_id
  end

  test "the printed address still opens the Verto, now as Dan's share" do
    street_link
    P.new.call

    get play_survey_path(P::LINK_SLUG)
    assert_response :success

    session_token = "ssp-#{SecureRandom.hex(4)}"
    post progress_survey_path(P::LINK_SLUG),
         params: { session_token: session_token, answers: { "1" => { "value" => "Yes" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal street_share.id, verto.responses.find_by!(session_token: session_token).survey_share_id
  end

  test "Dan's partner page counts the respondents he had already gathered" do
    link = street_link
    3.times { respond(survey_link: link) }
    respond # one of Unleash Football's own, which is not his
    P.new.call

    dan.update!(password: "a-long-enough-password", password_pending: false)
    post session_path, params: { email_address: P::ADMIN_EMAIL, password: "a-long-enough-password" }
    partnership = unleash.partnerships.sole
    get partnership_partnership_verto_path(partnership, partnership.partnership_vertos.sole)

    assert_response :success
    assert_select "strong", text: "3"
    assert_includes response.body, play_survey_url(P::LINK_SLUG)
  end

  test "Dan is sent the partner welcome, with a link to set his password" do
    street_link
    result = P.new.call

    assert result.welcome_sent
    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ P::ADMIN_EMAIL ], mail.to
    assert_includes mail.subject, P::PARTNERSHIP_NAME
  end

  test "running it again changes nothing and sends nothing" do
    link = street_link
    respond(survey_link: link)
    P.new.call
    ActionMailer::Base.deliveries.clear

    assert_no_difference %w[User.count Organisation.count Partnership.count PartnershipMembership.count
                            SurveyShare.count Membership.count] do
      result = P.new.call
      assert result.link_adopted
      assert_equal 0, result.responses_moved
      assert_not result.user_created
    end
    assert_empty ActionMailer::Base.deliveries
  end

  test "an existing user keeps his password and gets no 'account set up for you' email" do
    User.create!(name: "Daniel", email_address: P::ADMIN_EMAIL, password: "his-own-password-123")
    street_link
    result = P.new.call

    assert_not result.user_created
    assert_equal "Daniel", dan.name
    assert dan.authenticate("his-own-password-123")
    assert_equal "admin", dan.memberships.find_by!(organisation: street).role
    assert_empty ActionMailer::Base.deliveries
  end

  test "a link's pinned settings are reported, since a share follows the Verto" do
    street_link(show_results_comparison: true, share_enabled: false)

    assert_equal({ "results comparison" => true, "Share button" => false }, P.new.call.link_overrides)
  end

  test "a paused link is reported, since the share brings the address back" do
    street_link(active: false)

    assert P.new.call.link_was_paused
  end

  test "the Verto's own custom address is left alone: the account is made, nothing is moved" do
    verto(slug: P::LINK_SLUG)
    mine = respond

    result = P.new.call

    assert_not result.link_adopted
    assert_equal P::LINK_SLUG, verto.reload.slug
    assert_not_equal P::LINK_SLUG, street_share.share_token
    assert_nil mine.reload.survey_share_id
    assert street
  end

  def migrate_up
    ActiveRecord::Migration.suppress_messages { ProvisionStreetSoccerPartnerAccount.new.migrate(:up) }
  end

  test "the migration runs it" do
    street_link
    migrate_up

    assert_equal P::LINK_SLUG, street_share.share_token
  end

  # Unleash Football having already ended a Street Soccer partnership is a
  # decision this must not overturn — and a refusal must neither stop the
  # deploy nor leave the link half-moved.
  test "a refusal never stops a deploy, and moves nothing" do
    link = street_link
    org = Organisation.create!(name: P::ORG_NAME, slug: P::ORG_SLUG)
    partnership = unleash.partnerships.create!(name: P::PARTNERSHIP_NAME)
    partnership.partnership_memberships.create!(organisation: org, status: "revoked")

    assert_nothing_raised { migrate_up }
    assert link.reload.persisted?
    assert_equal P::LINK_SLUG, link.slug
    assert_not SurveyShare.exists?(share_token: P::LINK_SLUG)
    assert_empty ActionMailer::Base.deliveries
  end
end
