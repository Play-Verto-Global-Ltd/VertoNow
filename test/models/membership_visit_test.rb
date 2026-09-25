require "test_helper"

# Membership#last_visited_at: when this person last acted in this account,
# the signal behind the picker's recent clients and the Clients dashboard.
class MembershipVisitTest < ActiveSupport::TestCase
  def setup
    org  = Organisation.create!(name: "Org", slug: "mv-#{SecureRandom.hex(3)}")
    user = User.create!(name: "U", email_address: "mv-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @membership = org.memberships.create!(user: user, role: "admin")
  end

  test "a first visit is recorded" do
    assert_nil @membership.last_visited_at

    @membership.touch_visited!

    assert_in_delta Time.current, @membership.reload.last_visited_at, 2.seconds
  end

  test "a visit inside the hour is not re-recorded" do
    stamp = 10.minutes.ago
    @membership.update_column(:last_visited_at, stamp)

    @membership.touch_visited!

    assert_in_delta stamp, @membership.reload.last_visited_at, 1.second
  end

  test "a visit after the hour is" do
    @membership.update_column(:last_visited_at, 2.hours.ago)

    @membership.touch_visited!

    assert_in_delta Time.current, @membership.reload.last_visited_at, 2.seconds
  end

  test "force records the visit whatever the last stamp says" do
    @membership.update_column(:last_visited_at, 10.minutes.ago)

    @membership.touch_visited!(force: true)

    assert_in_delta Time.current, @membership.reload.last_visited_at, 2.seconds
  end

  # update_column: the role's own timestamp says when the ROLE last changed.
  test "recording a visit does not move updated_at" do
    updated = @membership.updated_at

    travel 3.hours do
      @membership.touch_visited!
    end

    assert_equal updated, @membership.reload.updated_at
  end

  test "recently_visited orders by stamp and leaves the unvisited out" do
    org = @membership.organisation
    later   = org.memberships.create!(user: User.create!(name: "L", email_address: "mv-l-#{SecureRandom.hex(3)}@test.com",
                                                          password: "verylongpassword"), role: "member")
    never   = org.memberships.create!(user: User.create!(name: "N", email_address: "mv-n-#{SecureRandom.hex(3)}@test.com",
                                                          password: "verylongpassword"), role: "member")
    @membership.update_column(:last_visited_at, 2.hours.ago)
    later.update_column(:last_visited_at, 1.hour.ago)

    listed = org.memberships.recently_visited.to_a
    assert_equal [ later, @membership ], listed
    assert_not_includes listed, never
  end
end
