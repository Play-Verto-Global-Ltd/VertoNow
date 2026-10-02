# Data migration: open the Common Goal client account, with Jamie's and Nick's
# admin memberships, in PRODUCTION.
#
# Render's pre-deploy `db:prepare` migrates an existing database and never
# re-seeds, so the db/seeds.rb line would never run there — this has to ride
# the ordinary migration path, exactly as every earlier managed account's
# provisioning migration does.
#
# Idempotent and credential-free; all the reasoning lives on
# ManagedAccountProvisioner. Up-only: withdrawing an account is a product
# decision made through the Members page, not a rollback.
class ProvisionCommonGoalAccount < ActiveRecord::Migration[8.1]
  def up
    CommonGoalAccountProvisioner.new.call
  rescue => e
    # Data-only migration: if model drift ever makes this stale, the deploy
    # must not be held hostage — an account can always be provisioned by hand.
    say "Common Goal account provisioning skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; see the header.
  end
end
