require "test_helper"

# The History Collab client account is provisioned from two disjoint places
# (the data migration for an existing database, db/seeds.rb for a fresh one),
# so the properties that matter are all about running MORE THAN ONCE without
# doing damage — most sharply, never resetting the password of a user who
# already has an account, which both of these people do.
class HistoryCollabAccountProvisionerTest < ActiveSupport::TestCase
  def setup
    destroy_history_collab!
  end

  def teardown
    destroy_history_collab!
  end

  def destroy_history_collab!
    Organisation.where(slug: HistoryCollabAccountProvisioner::ORG_SLUG).find_each(&:destroy!)
    User.where(email_address: [ HistoryCollabAccountProvisioner::JAMIE_EMAIL,
                                HistoryCollabAccountProvisioner::NICK_EMAIL ]).find_each(&:destroy!)
  end

  def history_collab = Organisation.find_by(slug: HistoryCollabAccountProvisioner::ORG_SLUG)
  def playverto      = Organisation.find_by(slug: PlayvertoStaff::SLUG)
  def jamie          = User.find_by(email_address: HistoryCollabAccountProvisioner::JAMIE_EMAIL)
  def nick           = User.find_by(email_address: HistoryCollabAccountProvisioner::NICK_EMAIL)

  test "creates a managed History Collab org" do
    HistoryCollabAccountProvisioner.new.call

    assert history_collab, "expected The History Collab organisation"
    assert_equal "The History Collab", history_collab.name
    refute history_collab.verto_creation_enabled?,
           "The History Collab is a managed account — its whole point is that it cannot create Vertos"
  end

  test "puts Jamie in The History Collab as an admin and in Playverto as a member" do
    HistoryCollabAccountProvisioner.new.call

    assert jamie, "expected Jamie's user"
    assert_equal "admin",  jamie.memberships.find_by(organisation: history_collab).role
    assert_equal "member", jamie.memberships.find_by(organisation: playverto).role

    # The Playverto membership is what actually lets him create inside the account.
    assert PlayvertoStaff.member?(jamie)
  end

  test "puts Nick in The History Collab as an admin, with his Playverto admin role" do
    HistoryCollabAccountProvisioner.new.call

    assert nick, "expected Nick's user"
    assert_equal "admin", nick.memberships.find_by(organisation: history_collab).role
    assert_equal "admin", nick.memberships.find_by(organisation: playverto).role
    assert PlayvertoStaff.member?(nick)
  end

  # Both of them are Playverto staff, so neither is bound by the account's own
  # restriction — that is the whole reason they can work in it. This provisioner
  # grants those memberships itself rather than leaning on the Alpbach or
  # Unleash Football one having run, so the property holds on a database where
  # it is the only thing that has.
  test "both grantees can create inside the managed account" do
    HistoryCollabAccountProvisioner.new.call

    [ jamie, nick ].each do |user|
      assert PlayvertoStaff.member?(user),
             "#{user.email_address} should be able to create in The History Collab"
    end
  end

  test "running twice changes nothing" do
    HistoryCollabAccountProvisioner.new.call

    assert_no_difference [ "Organisation.count", "User.count", "Membership.count" ] do
      assert_nothing_raised { HistoryCollabAccountProvisioner.new.call }
    end
  end

  # Both of these people already have accounts — Alpbach and Unleash Football
  # each provisioned them. A provisioner that reset a password on every deploy
  # would lock them out silently, and the deploy would still be green.
  test "an existing user keeps their password, name and claimed status" do
    [ HistoryCollabAccountProvisioner::JAMIE_EMAIL,
      HistoryCollabAccountProvisioner::NICK_EMAIL ].each do |email|
      User.where(email_address: email).find_each(&:destroy!)
      User.create!(name: "Already #{email}", email_address: email, password: "verylongpassword")
    end

    HistoryCollabAccountProvisioner.new.call

    [ HistoryCollabAccountProvisioner::JAMIE_EMAIL,
      HistoryCollabAccountProvisioner::NICK_EMAIL ].each do |email|
      user = User.find_by(email_address: email)
      assert user.authenticate("verylongpassword"), "#{email}: password was reset by provisioning"
      assert_equal "Already #{email}", user.name, "#{email}: name was overwritten by provisioning"
      refute user.password_pending?, "#{email}: a claimed account was marked password-pending again"
    end
  end

  # If someone deliberately turns creation on for the account, the next deploy
  # must not quietly turn it back off.
  test "does not re-disable creation for an org an operator has enabled" do
    HistoryCollabAccountProvisioner.new.call
    history_collab.update!(verto_creation_enabled: true)

    HistoryCollabAccountProvisioner.new.call

    assert history_collab.reload.verto_creation_enabled?,
           "a re-run fought the operator's decision instead of leaving it alone"
  end

  # An existing membership must keep whatever role it has been given since.
  test "does not change an existing membership's role" do
    HistoryCollabAccountProvisioner.new.call
    jamie.memberships.find_by(organisation: playverto).update!(role: "admin")
    nick.memberships.find_by(organisation: history_collab).update!(role: "member")

    HistoryCollabAccountProvisioner.new.call

    assert_equal "admin",  jamie.memberships.find_by(organisation: playverto).role
    assert_equal "member", nick.memberships.find_by(organisation: history_collab).role
  end

  # All three managed accounts share both of their people. Provisioning this one
  # must not disturb the others' memberships — they are separate accounts that
  # happen to be staffed by the same two admins.
  test "leaves the Alpbach and Unleash Football accounts and their memberships alone" do
    AlpbachAccountProvisioner.new.call
    UnleashFootballAccountProvisioner.new.call
    alpbach          = Organisation.find_by(slug: AlpbachAccountProvisioner::ORG_SLUG)
    unleash_football = Organisation.find_by(slug: UnleashFootballAccountProvisioner::ORG_SLUG)

    HistoryCollabAccountProvisioner.new.call

    [ alpbach, unleash_football ].each do |org|
      assert_equal "admin", jamie.memberships.find_by(organisation: org).role
      assert_equal "admin", nick.memberships.find_by(organisation: org).role
      refute_equal org.id, history_collab.id
    end
  end
end
