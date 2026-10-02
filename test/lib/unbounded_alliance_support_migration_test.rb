require "test_helper"
require Rails.root.join("db/migrate/20261002180000_add_playverto_support_to_unbounded_alliance")

# Nick and Jamie join the Unbounded Alliance's self-made account(s) for tech
# support. What matters: every alliance account is found by name, nobody
# else's is touched, an existing password or role is never reset, and a
# database without the alliance is left alone.
class UnboundedAllianceSupportMigrationTest < ActiveSupport::TestCase
  EMAILS = [ ManagedAccountProvisioner::NICK_EMAIL, ManagedAccountProvisioner::JAMIE_EMAIL ].freeze

  def setup
    User.where(email_address: EMAILS).find_each(&:destroy!)
    Organisation.where("LOWER(slug) LIKE ?", "%unbounded%").find_each(&:destroy!)
  end

  def migrate = ActiveRecord::Migration.suppress_messages { AddPlayvertoSupportToUnboundedAlliance.new.up }
  def users   = User.where(email_address: EMAILS)

  test "makes Nick and Jamie admins of every Unbounded Alliance account, and no other" do
    first  = Organisation.create!(name: "Unbounded Alliance", slug: "unbounded-alliance")
    second = Organisation.create!(name: "The UNBOUNDED Alliance – Youth", slug: "ua-youth")
    other  = Organisation.create!(name: "Bounded Co", slug: "bounded-co")

    migrate

    [ first, second ].each do |org|
      assert_equal EMAILS.sort, org.memberships.admin.joins(:user).pluck("users.email_address").sort
    end
    assert_empty other.memberships.where(user: users)
  end

  test "keeps an existing password and an existing role, and runs twice to the same end" do
    org  = Organisation.create!(name: "Unbounded Alliance", slug: "unbounded-alliance")
    nick = User.create!(email_address: ManagedAccountProvisioner::NICK_EMAIL, name: "Nick", password: "secret-password-1")
    Membership.create!(user: nick, organisation: org, role: "member")

    2.times { migrate }

    assert nick.reload.authenticate("secret-password-1")
    assert_equal "member", org.memberships.find_by(user: nick).role
    assert_equal 2, org.memberships.where(user: users).count
  end

  test "does nothing on a database without the alliance" do
    assert_no_difference -> { Membership.count } do
      assert_no_difference(-> { User.count }) { migrate }
    end
  end
end
