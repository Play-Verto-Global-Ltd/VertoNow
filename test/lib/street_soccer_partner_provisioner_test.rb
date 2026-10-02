require "test_helper"
require Rails.root.join("db/migrate/20261002090000_provision_street_soccer_partner_account")
require Rails.root.join("db/migrate/20261002120000_add_owner_to_street_soccer_account")
require Rails.root.join("db/migrate/20261002170000_remove_dan_wood_from_street_soccer")

# Street Soccer's partner account, opened by a data migration on deploy, which
# also hands it the Unleash Football link its people were already sending
# respondents to. What matters: it ends up an ordinary partner account, held
# by Nick and Jamie until Street Soccer's own people are invited, that can see
# the respondents it gathered; the printed address keeps answering; nothing
# runs twice.
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
    verto.responses.create!({ session_token: SecureRandom.uuid, status: "completed",
                              answers: { "1" => { "value" => "Yes" } } }.merge(attrs))
  end

  def dan          = User.find_by(email_address: RemoveDanWoodFromStreetSoccer::DAN_EMAIL)
  def nick         = User.find_by(email_address: ManagedAccountProvisioner::NICK_EMAIL)
  def jamie        = User.find_by(email_address: ManagedAccountProvisioner::JAMIE_EMAIL)
  def street       = Organisation.find_by(slug: P::ORG_SLUG)
  def street_share = SurveyShare.find_by(partner_organisation: street)

  test "a database without the address gets nothing" do
    verto

    assert_nil P.new.call
    assert_nil street
    assert_empty ActionMailer::Base.deliveries
  end

  test "Street Soccer is an ordinary account that can create Vertos, held by Nick and Jamie" do
    User.create!(name: "Nick", email_address: ManagedAccountProvisioner::NICK_EMAIL, password: "nicks-own-password")
    User.create!(name: "Jamie", email_address: ManagedAccountProvisioner::JAMIE_EMAIL, password: "jamies-own-password")
    street_link
    P.new.call

    assert_equal "Street Soccer", street.name
    assert street.verto_creation_enabled?, "a partner account is an ordinary one — it builds its own Vertos"
    assert_equal [ ManagedAccountProvisioner::JAMIE_EMAIL, ManagedAccountProvisioner::NICK_EMAIL ],
                 street.memberships.where(role: "admin").map { |m| m.user.email_address }.sort
    assert nick.authenticate("nicks-own-password"), "an existing account keeps its password"
    assert jamie.authenticate("jamies-own-password")
    assert_nil dan, "Street Soccer's own people are invited through the platform"
    assert_empty ActionMailer::Base.deliveries, "nobody is emailed"
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
    assert_nil other.reload.survey_share_id, "another link's respondents are not Street Soccer's"
    assert other.survey_link_id
  end

  test "the printed address still opens the Verto, now as Street Soccer's share" do
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

  test "Street Soccer's partner page counts the respondents it had already gathered" do
    User.create!(name: "Nick", email_address: ManagedAccountProvisioner::NICK_EMAIL, password: "nicks-own-password")
    link = street_link
    3.times { respond(survey_link: link) }
    respond # one of Unleash Football's own, which is not Street Soccer's
    P.new.call

    post session_path, params: { email_address: ManagedAccountProvisioner::NICK_EMAIL, password: "nicks-own-password" }
    partnership = unleash.partnerships.sole
    get partnership_partnership_verto_path(partnership, partnership.partnership_vertos.sole)

    assert_response :success
    assert_select "strong", text: "3"
    assert_includes response.body, play_survey_url(P::LINK_SLUG)
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
    end
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

  # Production's state after the first deploy: the account as the first
  # version of the provisioner made it, with Dan as its admin and a throwaway
  # password he never replaced.
  def first_deploy_state
    street_link
    migrate_up
    street.memberships.where(user: jamie).delete_all
    dan = User.create!(name: "Dan Wood", email_address: RemoveDanWoodFromStreetSoccer::DAN_EMAIL,
                       password: SecureRandom.hex(32), password_pending: true)
    street.memberships.create!(user: dan, role: "admin")
    dan
  end

  def remove_dan
    ActiveRecord::Migration.suppress_messages { RemoveDanWoodFromStreetSoccer.new.migrate(:up) }
  end

  test "Dan's account is removed, and Nick and Jamie keep the account" do
    first_deploy_state

    remove_dan

    assert_nil dan
    assert_equal [ ManagedAccountProvisioner::JAMIE_EMAIL, ManagedAccountProvisioner::NICK_EMAIL ],
                 street.memberships.map { |m| m.user.email_address }.sort
    assert_equal P::LINK_SLUG, street_share.share_token, "the partner link and its respondents stay Street Soccer's"
  end

  # With no account left at his address, an invite from the Members page makes
  # him a fresh one — rather than asking for a password he never set.
  test "after the removal Dan can be invited to Street Soccer like anyone else" do
    first_deploy_state
    remove_dan
    invite = Invite.create!(organisation: street, invited_by: nick, kind: "member", role: "admin",
                            email_address: RemoveDanWoodFromStreetSoccer::DAN_EMAIL, expires_at: 7.days.from_now)

    post accept_invite_path(invite.token), params: { name: "Dan Wood", password: "dans-own-password",
                                                     password_confirmation: "dans-own-password" }

    assert dan, "the invite made his account"
    assert dan.authenticate("dans-own-password")
    assert_equal "admin", dan.memberships.find_by!(organisation: street).role
  end

  test "a Dan who has made something keeps his account, and the deploy carries on" do
    dan = first_deploy_state
    Invite.create!(organisation: street, invited_by: dan, kind: "member", role: "member",
                   email_address: "colleague@example.com", expires_at: 7.days.from_now)

    assert_nothing_raised { remove_dan }
    assert dan.reload.persisted?, "refused whole, not half-deleted"
    assert street.memberships.exists?(user: dan)
  end

  test "removing Dan where he never existed does nothing" do
    street_link
    migrate_up

    assert_no_difference -> { User.count } do
      remove_dan
    end
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
