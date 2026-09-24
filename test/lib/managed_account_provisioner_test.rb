require "test_helper"

# The two accounts opened together on 2026-09-24 — Riders for Health and The
# Marketing Society — and the base class they are the first to be built on
# rather than copied from. Each account is provisioned from two disjoint
# places (the data migration for an existing database, db/seeds.rb for a fresh
# one), so the properties that matter are all about running MORE THAN ONCE
# without doing damage — most sharply, never resetting the password of a user
# who already has an account, which both of these people do. The three older
# accounts keep their own tests; these run the same checks over the new pair.
class ManagedAccountProvisionerTest < ActiveSupport::TestCase
  NEW_ACCOUNTS = [ RidersForHealthAccountProvisioner, MarketingSocietyAccountProvisioner ].freeze

  def setup    = destroy_managed_accounts!
  def teardown = destroy_managed_accounts!

  def destroy_managed_accounts!
    Organisation.where(slug: ManagedAccountProvisioner.slugs).find_each(&:destroy!)
    User.where(email_address: [ ManagedAccountProvisioner::JAMIE_EMAIL,
                                ManagedAccountProvisioner::NICK_EMAIL ]).find_each(&:destroy!)
  end

  def playverto = Organisation.find_by(slug: PlayvertoStaff::SLUG)
  def jamie     = User.find_by(email_address: ManagedAccountProvisioner::JAMIE_EMAIL)
  def nick      = User.find_by(email_address: ManagedAccountProvisioner::NICK_EMAIL)
  def org_of(provisioner) = Organisation.find_by(slug: provisioner::ORG_SLUG)

  # .all is what db/seeds.rb and LoadTestSeeder read, so an account missing
  # from it is seeded nowhere and trips the load-test guard on scratch.
  test "lists every managed account once, each under its own slug" do
    assert_includes ManagedAccountProvisioner.all, RidersForHealthAccountProvisioner
    assert_includes ManagedAccountProvisioner.all, MarketingSocietyAccountProvisioner
    assert_equal ManagedAccountProvisioner.slugs, ManagedAccountProvisioner.slugs.uniq
    ManagedAccountProvisioner.all.each do |provisioner|
      assert_operator provisioner, :<, ManagedAccountProvisioner
    end
  end

  test "names the new accounts the way their clients do" do
    assert_equal "Riders for Health",     RidersForHealthAccountProvisioner::ORG_NAME
    assert_equal "riders-for-health",     RidersForHealthAccountProvisioner::ORG_SLUG
    assert_equal "The Marketing Society", MarketingSocietyAccountProvisioner::ORG_NAME
    assert_equal "the-marketing-society", MarketingSocietyAccountProvisioner::ORG_SLUG
  end

  NEW_ACCOUNTS.each do |provisioner|
    name = provisioner::ORG_NAME

    test "creates a managed #{name} org" do
      provisioner.new.call

      org = org_of(provisioner)
      assert org, "expected the #{name} organisation"
      assert_equal name, org.name
      refute org.verto_creation_enabled?,
             "#{name} is a managed account — its whole point is that it cannot create Vertos"
    end

    test "puts Jamie in #{name} as an admin and in Playverto as a member" do
      provisioner.new.call

      assert jamie, "expected Jamie's user"
      assert_equal "admin",  jamie.memberships.find_by(organisation: org_of(provisioner)).role
      assert_equal "member", jamie.memberships.find_by(organisation: playverto).role

      # The Playverto membership is what actually lets him create inside the account.
      assert PlayvertoStaff.member?(jamie)
    end

    test "puts Nick in #{name} as an admin, with his Playverto admin role" do
      provisioner.new.call

      assert nick, "expected Nick's user"
      assert_equal "admin", nick.memberships.find_by(organisation: org_of(provisioner)).role
      assert_equal "admin", nick.memberships.find_by(organisation: playverto).role
      assert PlayvertoStaff.member?(nick)
    end

    # Both of them are Playverto staff, so neither is bound by the account's
    # own restriction — that is the whole reason they can work in it. The
    # provisioner grants those memberships itself rather than leaning on an
    # older account's having run, so the property holds on a database where
    # it is the only thing that has.
    test "both grantees can create inside #{name}" do
      provisioner.new.call

      [ jamie, nick ].each do |user|
        assert PlayvertoStaff.member?(user), "#{user.email_address} should be able to create in #{name}"
      end
    end

    test "running #{name} twice changes nothing" do
      provisioner.new.call

      assert_no_difference [ "Organisation.count", "User.count", "Membership.count" ] do
        assert_nothing_raised { provisioner.new.call }
      end
    end

    # Both of these people already have accounts — the older provisioners each
    # created them. A provisioner that reset a password on every deploy would
    # lock them out silently, and the deploy would still be green.
    test "#{name}: an existing user keeps their password, name and claimed status" do
      [ ManagedAccountProvisioner::JAMIE_EMAIL, ManagedAccountProvisioner::NICK_EMAIL ].each do |email|
        User.create!(name: "Already #{email}", email_address: email, password: "verylongpassword")
      end

      provisioner.new.call

      [ ManagedAccountProvisioner::JAMIE_EMAIL, ManagedAccountProvisioner::NICK_EMAIL ].each do |email|
        user = User.find_by(email_address: email)
        assert user.authenticate("verylongpassword"), "#{email}: password was reset by provisioning"
        assert_equal "Already #{email}", user.name, "#{email}: name was overwritten by provisioning"
        refute user.password_pending?, "#{email}: a claimed account was marked password-pending again"
      end
    end

    # If someone deliberately turns creation on for the account, the next
    # deploy must not quietly turn it back off.
    test "#{name}: does not re-disable creation for an org an operator has enabled" do
      provisioner.new.call
      org_of(provisioner).update!(verto_creation_enabled: true)

      provisioner.new.call

      assert org_of(provisioner).verto_creation_enabled?,
             "a re-run fought the operator's decision instead of leaving it alone"
    end

    # An existing membership must keep whatever role it has been given since.
    test "#{name}: does not change an existing membership's role" do
      provisioner.new.call
      jamie.memberships.find_by(organisation: playverto).update!(role: "admin")
      nick.memberships.find_by(organisation: org_of(provisioner)).update!(role: "member")

      provisioner.new.call

      assert_equal "admin",  jamie.memberships.find_by(organisation: playverto).role
      assert_equal "member", nick.memberships.find_by(organisation: org_of(provisioner)).role
    end
  end

  # Every managed account shares both of its people. Opening the new pair must
  # not disturb the older accounts' memberships, and the pair must not collapse
  # into one another — they are separate accounts that happen to be staffed by
  # the same two admins.
  test "opening the new pair leaves the older accounts alone and keeps the pair apart" do
    older = ManagedAccountProvisioner.all - NEW_ACCOUNTS
    older.each { |provisioner| provisioner.new.call }
    older_orgs = older.map { |provisioner| org_of(provisioner) }

    NEW_ACCOUNTS.each { |provisioner| provisioner.new.call }

    older_orgs.each do |org|
      assert_equal "admin", jamie.memberships.find_by(organisation: org).role
      assert_equal "admin", nick.memberships.find_by(organisation: org).role
    end
    assert_equal ManagedAccountProvisioner.all.size,
                 Organisation.where(slug: ManagedAccountProvisioner.slugs).distinct.count(:id)
    refute_equal org_of(RidersForHealthAccountProvisioner).id, org_of(MarketingSocietyAccountProvisioner).id
  end
end
