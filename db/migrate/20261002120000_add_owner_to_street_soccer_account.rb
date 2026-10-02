# Data migration: give nick@playverto.com admin access to the Street Soccer
# partner account.
#
# A follow-up rather than an edit to 20261002090000, for the reason
# AddOwnerToAlpbachAccount gives: that migration has already run wherever this
# deploys, and a migration only ever runs once.
#
# StreetSoccerPartnerProvisioner now grants Nick too, and every write in it is
# create-only, so re-running it adds exactly the missing membership and leaves
# everything the first pass made untouched — Dan's welcome email included,
# which only goes to a user the run itself creates.
class AddOwnerToStreetSoccerAccount < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    result = StreetSoccerPartnerProvisioner.new.call
    return say("Street Soccer: no /play/#{StreetSoccerPartnerProvisioner::LINK_SLUG} here — nothing to do") unless result

    say "Street Soccer: #{StreetSoccerPartnerProvisioner::ADMINS.keys.join(", ")} are admins of #{result.organisation.name}"
  rescue => e
    # Data-only migration: never hold a deploy hostage — the membership can
    # always be granted by hand, or through the Members page.
    say "Street Soccer owner grant skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing — removing someone's access is a product decision.
  end
end
