# "Is this user Playverto staff?" — answered by membership of the Playverto
# organisation itself (slug "playverto"), which encodes the requirement exactly
# (the owner and the members of the Playverto org) with nothing to configure,
# and is DENY-BY-DEFAULT: no user, no membership, no access.
#
# This is a deliberate CROSS-TENANT capability, so it is worth stating what it
# now grants:
#
#   * Comms — the platform-wide email campaign surface (see CommsAccess, which
#     is this predicate under its original name); and
#   * creating a Verto inside an account whose own
#     Organisation#verto_creation_enabled is false (see
#     OrganisationScope#can_create_vertos?).
#
# The second one is the point: a managed client account has its Vertos built for
# it by the Playverto team, so the person doing the building needs to create
# inside an account where the client themselves cannot. Membership of the
# Playverto org is therefore a privileged thing to hand out — it reaches into
# every restricted customer account, not just one.
module PlayvertoStaff
  module_function

  SLUG = "playverto"

  def member?(user)
    return false if user.nil?

    Membership.joins(:organisation)
              .where(user_id: user.id, organisations: { slug: SLUG })
              .exists?
  end

  # Routing-constraint predicate, for a surface that should not exist (404)
  # for anyone but staff — the Clients dashboard, as /comms and /blazer are
  # gated. Resolves the user from the same signed session cookie the app's
  # Authentication concern issues (BlazerAccess already knows how).
  def member_request?(request)
    member?(BlazerAccess.user_for(request))
  end

  # The Playverto workspace itself — the one account that is not a client.
  # nil on a database that has never been seeded, which no caller treats as
  # an error: with no Playverto org there is no staff either.
  def home_organisation
    Organisation.find_by(slug: SLUG)
  end
end
