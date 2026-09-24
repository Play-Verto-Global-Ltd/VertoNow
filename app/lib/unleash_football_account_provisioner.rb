# The Unleash Football client account — managed, with Jamie and Nick as its
# admins; see ManagedAccountProvisioner for what that grants and for the
# create-only guarantees.
#
# Referenced by name from db/migrate (20260909090000), so the class stays even
# though it now holds nothing but the account's identity.
class UnleashFootballAccountProvisioner < ManagedAccountProvisioner
  ORG_SLUG = "unleash-football"
  ORG_NAME = "Unleash Football"
end
