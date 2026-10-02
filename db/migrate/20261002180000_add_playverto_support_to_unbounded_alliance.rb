# Data migration: add Nick and Jamie to the Unbounded Alliance's account(s), at
# the alliance's request, so the Playverto team can give it tech support from
# inside the account.
#
# Unbounded Alliance signed itself up — nothing in this repository made its
# organisation — so there is no slug to name. It is found by name instead:
# every organisation whose name or slug contains "unbounded", which also covers
# the alliance having opened more than one. The output names each account it
# joined, so the deploy log says exactly what happened.
#
# Admin, as Nick and Jamie are of the managed accounts: support means being
# able to see and fix the members, invites and brand too. Create-only, like
# every account migration here: an existing user keeps their password, an
# existing membership keeps its role. A database without the alliance — every
# dev and test one — gets nothing.
#
# Up-only: stepping back out of the account is done from its Members page.
class AddPlayvertoSupportToUnboundedAlliance < ActiveRecord::Migration[8.1]
  PATTERN = "%unbounded%"
  ADMINS = {
    ManagedAccountProvisioner::NICK_EMAIL  => ManagedAccountProvisioner::NICK_NAME,
    ManagedAccountProvisioner::JAMIE_EMAIL => ManagedAccountProvisioner::JAMIE_NAME
  }.freeze

  def up
    orgs = Organisation.where("LOWER(name) LIKE :p OR LOWER(slug) LIKE :p", p: PATTERN).order(:id).to_a
    return say("Unbounded Alliance: no organisation here — nothing to do") if orgs.empty?

    ActiveRecord::Base.transaction do
      orgs.each do |org|
        ADMINS.each do |email, name|
          Membership.find_or_create_by!(user: find_or_create_user!(email, name), organisation: org) { |m| m.role = "admin" }
        end
        say "Unbounded Alliance: #{ADMINS.keys.join(", ")} are in \"#{org.name}\" (##{org.id}, #{org.slug})"
      end
    end
  rescue => e
    # Data-only migration: never hold a deploy hostage — the memberships can
    # always be granted from the account's Members page.
    say "Unbounded Alliance support access skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; see the header.
  end

  private

  # Credential-free, as ManagedAccountProvisioner creates its people. Both
  # already have accounts wherever this matters; on create only, so an
  # existing password is never touched.
  def find_or_create_user!(email, name)
    User.find_or_create_by!(email_address: email) do |u|
      u.name             = name
      u.password         = SecureRandom.hex(32)
      u.password_pending = true
    end
  end
end
