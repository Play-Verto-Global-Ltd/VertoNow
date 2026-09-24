# The History CoLab client account — managed, with Jamie and Nick as its
# admins; see ManagedAccountProvisioner for what that grants and for the
# create-only guarantees.
#
# THE SPELLING IS "CoLab", and only ORG_NAME carries it. The slug and this
# class keep the original "collab", deliberately:
#
#   * ORG_SLUG is the identity find_or_create_by! matches on, and it is
#     internal — no route or view reads an organisation's slug. Changing it
#     would mean a window in which the old row is findable under neither
#     spelling, and the next provisioner run creates a SECOND account rather
#     than finding the first. The rename migration (20260921140000) swallows
#     its own errors by design (see its header), so that window is not
#     hypothetical.
#   * The class name is referenced by an already-landed migration
#     (20260921120000). Renaming the constant would leave that migration
#     pointing at something that no longer exists.
#
# Neither is user-visible; ORG_NAME is the one that reaches a screen.
class HistoryCollabAccountProvisioner < ManagedAccountProvisioner
  ORG_SLUG = "the-history-collab"
  ORG_NAME = "The History CoLab"
end
