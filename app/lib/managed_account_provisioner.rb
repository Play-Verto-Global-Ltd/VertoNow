# Provisions one MANAGED client account and the Playverto people who work in it.
#
# A managed account is one whose Verto the Playverto team builds for the
# client, so the org is created with verto_creation_enabled false. Jamie and
# Nick are both admins of it — but it is their membership of the PLAYVERTO org,
# not their role in the account, that actually lets them create inside a
# restricted account (see PlayvertoStaff). Those Playverto memberships are
# granted here rather than assumed: this class is what makes "both grantees can
# build in the managed account" true, so no account may depend on another's
# provisioner having run first.
#
# A subclass names the account and nothing else:
#
#   class RidersForHealthAccountProvisioner < ManagedAccountProvisioner
#     ORG_SLUG = "riders-for-health"
#     ORG_NAME = "Riders for Health"
#   end
#
# and is listed in .all, which is what db/seeds.rb and LoadTestSeeder read.
# Opening an account is therefore that file, its line in .all, and a data
# migration that calls it (db/migrate/*_provision_*_account*.rb). Called from
# db/migrate AS WELL AS db/seeds.rb because the two paths are disjoint —
# Render's pre-deploy `db:prepare` migrates an existing database and never
# re-seeds, while a fresh database loads the schema (marking every migration as
# already run) and then seeds. Whichever fires, the other is a no-op.
#
# EVERY write is create-only, which is what makes it safe to re-run:
#   * an existing user keeps their password and name (both of these people
#     have accounts — this must never reset one);
#   * the managed flag is set in the find_or_create_by! block, so re-running
#     cannot re-disable creation for an account someone has deliberately
#     enabled;
#   * an existing membership keeps whatever role it has.
#
# Extracted when the fourth and fifth accounts (Riders for Health and The
# Marketing Society) arrived together, from three copies that differed only in
# slug and name.
class ManagedAccountProvisioner
  JAMIE_EMAIL = "jamie@playverto.com"
  JAMIE_NAME  = "Jamie"
  NICK_EMAIL  = "nick@playverto.com"
  NICK_NAME   = "Nick"

  # Every managed account, in the order they were opened. A method rather than
  # a constant so that naming the subclasses here does not autoload them in the
  # middle of defining their superclass.
  def self.all
    [ AlpbachAccountProvisioner, UnleashFootballAccountProvisioner, HistoryCollabAccountProvisioner,
      RidersForHealthAccountProvisioner, MarketingSocietyAccountProvisioner ]
  end

  def self.slugs = all.map { |provisioner| provisioner::ORG_SLUG }

  def call
    org       = find_or_create_org!
    playverto = find_or_create_playverto!

    jamie = find_or_create_user!(JAMIE_EMAIL, JAMIE_NAME)
    nick  = find_or_create_user!(NICK_EMAIL, NICK_NAME)

    # Admin in the account is "full features in that account" — members,
    # invites, brand, sharing.
    Membership.find_or_create_by!(user: jamie, organisation: org) { |m| m.role = "admin" }
    Membership.find_or_create_by!(user: nick,  organisation: org) { |m| m.role = "admin" }

    # Member — not admin — of Playverto for Jamie: the membership itself is the
    # staff capability, and he has no need to administer Playverto's own org.
    # Nick's Playverto membership is created as an ADMIN by db/seeds.rb and by
    # GrantCommsAccessToOwner, and find_or_create_by! leaves it alone — these
    # two lines only matter on a database where none of those has run.
    Membership.find_or_create_by!(user: jamie, organisation: playverto) { |m| m.role = "member" }
    Membership.find_or_create_by!(user: nick,  organisation: playverto) { |m| m.role = "admin" }

    [ org, jamie, nick ]
  end

  private

  def org_slug = self.class::ORG_SLUG
  def org_name = self.class::ORG_NAME

  def find_or_create_org!
    Organisation.find_or_create_by!(slug: org_slug) do |o|
      o.name                   = org_name
      o.verto_creation_enabled = false
    end
  end

  def find_or_create_playverto!
    Organisation.find_or_create_by!(slug: PlayvertoStaff::SLUG) { |o| o.name = "Playverto" }
  end

  # Credential-free: a user we have to create gets a throwaway password and
  # claims the account through the ordinary password-reset flow, the same idiom
  # the partner/funder accounts use. Both of these people already have
  # accounts, so in practice the create branch is the safety net, not the path
  # — and because it only runs on create, an existing password is never touched.
  def find_or_create_user!(email, name)
    User.find_or_create_by!(email_address: email) do |u|
      u.name             = name
      u.password         = SecureRandom.hex(32)
      u.password_pending = true
    end
  end
end
