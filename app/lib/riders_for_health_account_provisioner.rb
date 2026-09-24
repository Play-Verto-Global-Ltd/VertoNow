# The Riders for Health client account — managed, with Jamie and Nick as its
# admins. ManagedAccountProvisioner holds everything the account gets and the
# create-only guarantees that make re-running safe; this class is only the
# account's identity.
#
# Opened 2026-09-24 alongside The Marketing Society: db/migrate/20260924120000
# provisions it on an existing database, db/seeds.rb (via
# ManagedAccountProvisioner.all) on a fresh one.
class RidersForHealthAccountProvisioner < ManagedAccountProvisioner
  ORG_SLUG = "riders-for-health"
  ORG_NAME = "Riders for Health"
end
