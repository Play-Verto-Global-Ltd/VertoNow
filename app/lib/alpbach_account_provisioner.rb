# The Alpbach client account — the first managed account, and the provisioner
# the next two were copied from until ManagedAccountProvisioner absorbed the
# shape. Jamie builds its Verto and Nick (the owner) works in it too, so both
# are admins; the superclass says what that does and does not grant, and why
# every write is create-only.
#
# Referenced by name from db/migrate (20260818120001, 20260818130000), so the
# class stays even though it now holds nothing but the account's identity.
class AlpbachAccountProvisioner < ManagedAccountProvisioner
  ORG_SLUG = "alpbach"
  ORG_NAME = "Alpbach"
end
