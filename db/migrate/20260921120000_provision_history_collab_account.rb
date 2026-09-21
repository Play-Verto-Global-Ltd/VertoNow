# Data migration: create The History Collab client account and Jamie's and
# Nick's memberships in PRODUCTION.
#
# Render's pre-deploy `db:prepare` migrates an existing database and never
# re-seeds, so the db/seeds.rb line would never run there — this has to ride
# the ordinary migration path, exactly as ProvisionAlpbachAccount and
# ProvisionUnleashFootballAccount do.
#
# Idempotent and credential-free; all the reasoning lives on
# HistoryCollabAccountProvisioner. Up-only: withdrawing an account is a
# product decision made through the Members page, not a rollback.
#
# No reset_column_information needed: every column this touches
# (verto_creation_enabled, memberships.role, users.password_pending) has
# existed for many migrations, so no eager-loaded model cache can predate them.
class ProvisionHistoryCollabAccount < ActiveRecord::Migration[8.1]
  def up
    HistoryCollabAccountProvisioner.new.call
  rescue => e
    # Data-only migration: if model drift ever makes this stale, the deploy
    # must not be held hostage — the account can always be provisioned by hand.
    say "The History Collab account provisioning skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; see the header.
  end
end
