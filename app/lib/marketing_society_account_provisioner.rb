# The Marketing Society client account — managed, with Jamie and Nick as its
# admins. ManagedAccountProvisioner holds everything the account gets and the
# create-only guarantees that make re-running safe; this class is only the
# account's identity.
#
# The slug keeps the client's "The" and the class name drops it, exactly as
# The History CoLab's does: the slug is the row's identity and reads as the
# client writes their name, the constant is internal.
#
# Opened 2026-09-24 alongside Riders for Health: db/migrate/20260924120000
# provisions it on an existing database, db/seeds.rb (via
# ManagedAccountProvisioner.all) on a fresh one.
class MarketingSocietyAccountProvisioner < ManagedAccountProvisioner
  ORG_SLUG = "the-marketing-society"
  ORG_NAME = "The Marketing Society"
end
