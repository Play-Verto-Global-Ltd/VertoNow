# Data migration: open the Riders for Health and The Marketing Society client
# accounts, with Jamie's and Nick's admin memberships, in PRODUCTION.
#
# Render's pre-deploy `db:prepare` migrates an existing database and never
# re-seeds, so the db/seeds.rb line would never run there — this has to ride
# the ordinary migration path, exactly as the Alpbach, Unleash Football and
# History CoLab provisioning migrations do.
#
# Idempotent and credential-free; all the reasoning lives on
# ManagedAccountProvisioner. Up-only: withdrawing an account is a product
# decision made through the Members page, not a rollback.
#
# No reset_column_information needed: every column this touches
# (verto_creation_enabled, memberships.role, users.password_pending) has
# existed for many migrations, so no eager-loaded model cache can predate them.
class ProvisionRidersForHealthAndMarketingSocietyAccounts < ActiveRecord::Migration[8.1]
  def up
    [ RidersForHealthAccountProvisioner, MarketingSocietyAccountProvisioner ].each do |provisioner|
      provisioner.new.call
    rescue => e
      # Data-only migration: if model drift ever makes this stale, the deploy
      # must not be held hostage — an account can always be provisioned by
      # hand. Rescued per account so one refusing cannot skip the other.
      say "#{provisioner::ORG_NAME} account provisioning skipped: #{e.class}: #{e.message}"
    end
  end

  def down
    # Intentionally nothing; see the header.
  end
end
