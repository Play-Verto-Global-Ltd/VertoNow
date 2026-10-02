# Data migration: hand the Street Soccer partner account to Nick and Jamie,
# and remove the account 20261002090000 created for Dan Wood — so that Street
# Soccer's own people, Dan first, are added through the platform (the
# account's Members page) like anyone else's.
#
# Deleted, not just taken out of the organisation: an invite to an address
# that already has an account asks for that account's password, and Dan never
# set one, so a leftover user would have stranded his invite.
#
# The provisioner runs first and grants both admins (create-only), so the
# account is never left without one. Dan's user goes in one destroy — its
# memberships, sessions and sign-in identities with it, all or nothing. Should
# he have made anything that a user may not be deleted from under (a draft, an
# Ask Verto thread, an invite), the delete is refused, nothing changes, and the
# output says so: then he is removed from the Members page instead.
#
# Up-only, like every account migration here.
class RemoveDanWoodFromStreetSoccer < ActiveRecord::Migration[8.1]
  DAN_EMAIL = "danieljwood9@gmail.com"

  def up
    if (result = StreetSoccerPartnerProvisioner.new.call)
      say "Street Soccer: #{StreetSoccerPartnerProvisioner::ADMINS.keys.join(", ")} are admins of #{result.organisation.name}"
    end

    dan = User.find_by(email_address: DAN_EMAIL)
    return say("Street Soccer: no account for #{DAN_EMAIL} here — nothing to remove") unless dan

    set_password = !dan.password_pending?
    dan.destroy!
    say "Street Soccer: removed #{DAN_EMAIL}'s account " \
        "(#{set_password ? "he HAD set a password" : "never activated"}) — invite him from Street Soccer's Members page"
  rescue => e
    # Data-only migration: never hold a deploy hostage.
    say "Street Soccer: removing #{DAN_EMAIL} skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing — an account is not recreated by a rollback.
  end
end
