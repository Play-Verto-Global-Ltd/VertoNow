# The Common Goal client account — managed, with Jamie and Nick as its admins.
# ManagedAccountProvisioner holds everything the account gets and the
# create-only guarantees that make re-running safe; this class is only the
# account's identity.
#
# Opened 2026-10-02: db/migrate/20261002130000 provisions it on an existing
# database, db/seeds.rb (via ManagedAccountProvisioner.all) on a fresh one.
class CommonGoalAccountProvisioner < ManagedAccountProvisioner
  ORG_SLUG = "common-goal"
  ORG_NAME = "Common Goal"
end
