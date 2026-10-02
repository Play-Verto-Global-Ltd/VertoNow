# Data migration: open Street Soccer's partner account (Dan Wood) in
# PRODUCTION, as a partner of Unleash Football, and move /play/street-football
# — the Unleash Football link Dan was already sending people to — onto his
# partner share, with the responses it collected.
#
# A migration for the same reason as ProvisionUnleashFootballAccount: Render's
# pre-deploy `db:prepare` migrates and never re-seeds. What it does, and why
# each write is safe to repeat, is on StreetSoccerPartnerProvisioner. A
# database without that address — every dev and test one — gets nothing.
#
# As first deployed it also created Dan's user and emailed him the partner
# welcome; the provisioner no longer does either (see
# RemoveDanWoodFromStreetSoccer), and this body follows it so that it still
# loads — it has already run wherever it matters.
#
# Up-only: ending a partnership is a product decision made on the
# Partnerships page, not a rollback, and the deleted link is not recreated.
class ProvisionStreetSoccerPartnerAccount < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    result = StreetSoccerPartnerProvisioner.new.call
    return say("Street Soccer: no /play/#{StreetSoccerPartnerProvisioner::LINK_SLUG} here — nothing to do") unless result

    say "Street Soccer: partner of #{result.survey.organisation.name} in \"#{result.partnership.name}\" " \
        "for Verto ##{result.survey.id}; admins #{StreetSoccerPartnerProvisioner::ADMINS.keys.join(", ")}"
    if result.link_adopted
      say "Street Soccer: /play/#{result.share.share_token} is now the partner share; " \
          "#{result.responses_moved} response(s) moved from the named link"
    else
      say "Street Soccer: /play/#{StreetSoccerPartnerProvisioner::LINK_SLUG} is the Verto's own address, " \
          "not a named link — left as it is; the partner share is /play/#{result.share.share_token}"
    end
    if result.link_was_paused
      say "Street Soccer: the named link was paused; as the partner share, the address answers again"
    end
    result.link_overrides.each do |setting, value|
      say "Street Soccer: the link had the #{setting} pinned #{value ? "on" : "off"}; it now follows the Verto"
    end
  rescue => e
    # Data-only migration: if model drift ever makes this stale, the deploy
    # must not be held hostage — the account can always be made by hand from
    # the Partnerships page.
    say "Street Soccer partner provisioning skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; see the header.
  end
end
