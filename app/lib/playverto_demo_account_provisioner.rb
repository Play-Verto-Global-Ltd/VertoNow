# The PlayVerto Demo account — managed, with Jamie and Nick as its admins.
# ManagedAccountProvisioner holds everything the account gets and the
# create-only guarantees that make re-running safe; this class is only the
# account's identity.
#
# Not the "VertoNow Demo" account (vertonow-demo) that `bin/rails demo:seed`
# wipes and rebuilds: this one is a real, standing account, so nothing ever
# resets it.
#
# Opened 2026-10-02: db/migrate/20261002150000 provisions it on an existing
# database, db/seeds.rb (via ManagedAccountProvisioner.all) on a fresh one.
class PlayvertoDemoAccountProvisioner < ManagedAccountProvisioner
  ORG_SLUG = "playverto-demo"
  ORG_NAME = "PlayVerto Demo"
end
