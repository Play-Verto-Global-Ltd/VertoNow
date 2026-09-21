org = Organisation.find_or_create_by!(slug: "playverto") do |o|
  o.name = "Playverto"
end

# Only seed an admin when a password is explicitly supplied — never bake in a
# default credential. This file runs on initial production DB setup (the Render
# start command runs `db:prepare`), so a hardcoded password would create a
# publicly-known admin login. Set SEED_ADMIN_PASSWORD (and optionally
# SEED_ADMIN_EMAIL) to seed an admin; otherwise only the org is created.
#
# Create-only: an existing admin's password is never reset (this file used to
# run on every production boot and silently reverted password changes).
admin_password = ENV["SEED_ADMIN_PASSWORD"].presence

if admin_password
  email = ENV.fetch("SEED_ADMIN_EMAIL", "admin@playverto.com")
  user  = User.find_or_create_by!(email_address: email) do |u|
    u.name     = "Admin"
    u.password = admin_password
  end

  Membership.find_or_create_by!(user: user, organisation: org) do |m|
    m.role = "admin"
  end

  puts "Seeded: org=#{org.name}, admin=#{user.email_address}"
else
  puts "Seeded: org=#{org.name}. Set SEED_ADMIN_PASSWORD to also seed an admin user."
end

# Comms (the email campaign surface, /comms) is gated by membership of the
# Playverto org — make sure the owner's account is a member wherever seeds
# run. Create-only and credential-free: a missing user is created
# password-pending with a throwaway password (the partner/funder account
# idiom) and claims access through the normal password-reset flow; an
# existing user only gains the membership.
owner = User.find_or_create_by!(email_address: "nick@playverto.com") do |u|
  u.name             = "Nick"
  u.password         = SecureRandom.hex(32)
  u.password_pending = true
end

Membership.find_or_create_by!(user: owner, organisation: org) do |m|
  m.role = "admin"
end

# The Alpbach client account and Jamie's access to it. Needed HERE as well as
# in db/migrate/20260818120001_provision_alpbach_account.rb, and the split is
# not redundancy — the two paths are disjoint:
#
#   * an EXISTING database (production) runs the pending migration and never
#     re-seeds, so the migration is the only thing that provisions it; while
#   * a FRESH database loads db/schema.rb and marks every migration as already
#     run WITHOUT executing it, then seeds — so the migration never fires and
#     this line is the only thing that provisions it.
#
# Same reasoning as the Comms owner grant above, which lives in both places for
# exactly this reason. AlpbachAccountProvisioner is create-only, so whichever
# path runs first, the other is a no-op.
AlpbachAccountProvisioner.new.call

# The Unleash Football client account, and Jamie's and Nick's access to it.
# Same two-path split, and the same create-only provisioner, as the Alpbach
# account above: this line covers a FRESH database,
# db/migrate/20260909090000_provision_unleash_football_account.rb covers an
# existing one.
UnleashFootballAccountProvisioner.new.call

# The History Collab client account, and Jamie's and Nick's access to it. Same
# two-path split, and the same create-only provisioner, as the two accounts
# above: this line covers a FRESH database,
# db/migrate/20260921120000_provision_history_collab_account.rb covers an
# existing one.
HistoryCollabAccountProvisioner.new.call

# The showcase Verto in the Playverto org itself — one deck that plays every
# answer type, with imagery, branching and points on. Same split as the Alpbach
# account above, for the same reason: this line covers a FRESH database,
# db/migrate/20260820120000_provision_showcase_verto.rb covers an existing one.
#
# Create-only by design: it is a real Verto in an account somebody works in, so
# a re-seed must never overwrite edits made to it in the editor. Rebuild
# deliberately with `bin/rails showcase:seed FORCE=1`.
#
# Seeded in Test Mode — a /test/:token link that records nothing and leaves the
# deck editable — and with no simulated respondents: those are demo data the
# rake task seeds on request, not something a boot should invent in a live
# account (and they would lock the deck).
ShowcaseVertoSeeder.new.call

# Internal BI: starter Blazer queries for VertoNow staff (idempotent).
load Rails.root.join("db/seeds/blazer_starter_queries.rb")
