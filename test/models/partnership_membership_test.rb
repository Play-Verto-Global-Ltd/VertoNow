require "test_helper"

class PartnershipMembershipTest < ActiveSupport::TestCase
  # The "Setup pending" badge on the owner's partnership page is about the
  # partner the account was made for — its first admin. A partner account can
  # carry a second admin (Playverto staff, say), and the association has no
  # order, so "the first admin found" could be the second one, who has no
  # setup to do.
  test "setup pending asks about the earliest admin, whichever row the database returns first" do
    owner   = Organisation.create!(name: "Owner", slug: "pm-owner-#{SecureRandom.hex(3)}")
    partner = Organisation.create!(name: "Partner", slug: "pm-partner-#{SecureRandom.hex(3)}")
    pending = User.create!(name: "New", email_address: "pm-new-#{SecureRandom.hex(3)}@test.com",
                           password: SecureRandom.hex(16), password_pending: true)
    staff   = User.create!(name: "Staff", email_address: "pm-staff-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    partner.memberships.create!(user: pending, role: "admin", created_at: 2.minutes.ago)
    later = partner.memberships.create!(user: staff, role: "admin")
    later.update_columns(id: 0) # the later admin's row first in id order
    membership = owner.partnerships.create!(name: "Group").partnership_memberships.create!(organisation: partner)

    assert PartnershipMembership.find(membership.id).setup_pending?

    pending.update!(password: "a-long-enough-password", password_pending: false)
    assert_not PartnershipMembership.find(membership.id).setup_pending?
  end
end
