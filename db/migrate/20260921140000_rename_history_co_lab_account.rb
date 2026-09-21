# Data migration: correct the spelling of The History CoLab's name in
# PRODUCTION.
#
# The account shipped this morning as "The History Collab" (20260921120000).
# The client spells it "CoLab", and the provisioner's ORG_NAME alone cannot
# fix the row that already exists: find_or_create_by! only runs its block on
# CREATE, so a name change there reaches a fresh database and nothing else.
# Hence this — the existing-database half of the same two-path split the
# provision migration describes.
#
# Only the NAME moves. The slug stays "the-history-collab" on purpose; the
# reasoning is on HistoryCollabAccountProvisioner, but the short version is
# that it is the identity this and every other path matches on, it is not
# user-visible, and changing it is how you end up with two accounts.
#
# Narrow on purpose, in both directions:
#   * it renames only a row still carrying the exact old name, so an operator
#     who has since renamed the account by hand is not overruled — the same
#     posture as the provisioner refusing to re-disable creation someone
#     enabled;
#   * it is a no-op when the account does not exist yet, which is every
#     database that will seed it with the correct name a moment later.
#
# update_column, not update!: no callbacks, no validations, one write. An
# organisation whose logo would fail today's attachment validations is not a
# reason a rename cannot land.
class RenameHistoryCoLabAccount < ActiveRecord::Migration[8.1]
  SLUG     = "the-history-collab".freeze
  OLD_NAME = "The History Collab".freeze
  NEW_NAME = "The History CoLab".freeze

  def up  = rename_to(NEW_NAME, from: OLD_NAME)
  def down = rename_to(OLD_NAME, from: NEW_NAME)

  private

  def rename_to(new_name, from:)
    org = Organisation.find_by(slug: SLUG)
    return say("no #{SLUG} organisation yet — nothing to rename") if org.nil?
    return say("#{SLUG} is named #{org.name.inspect}, not #{from.inspect} — left alone") if org.name != from

    org.update_column(:name, new_name)
    say "#{SLUG}: #{from.inspect} → #{new_name.inspect}"
  rescue => e
    # Data-only migration: if model drift ever makes this stale, the deploy
    # must not be held hostage — the name can always be fixed by hand.
    say "The History CoLab rename skipped: #{e.class}: #{e.message}"
  end
end
