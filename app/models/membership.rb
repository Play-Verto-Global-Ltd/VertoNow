class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organisation

  # Three roles, in ascending order of what they may do:
  #
  #   viewer — shares Vertos and sees their results, and nothing else: no
  #            editor, no creation, no publish/unpublish, no settings. The
  #            role for a colleague who sends the link out and reads what
  #            comes back.
  #   member — creates and edits Vertos as well.
  #   admin  — also manages members, invites, the brand, partnerships and
  #            the account-level sharing decisions (named links, results
  #            links, Ask Verto opt-in).
  #
  # What each role is refused is enforced at the controller boundary
  # (OrganisationScope#require_admin!, #require_verto_editing!,
  # #require_verto_creation!) and mirrored by the view predicates that hide the
  # corresponding affordances (current_membership&.admin?, can_edit_vertos?,
  # can_create_vertos?). The database carries the same list as a CHECK
  # constraint (chk_memberships_role), so a value outside it fails loudly
  # whichever way it was written.
  ROLES = %w[viewer member admin].freeze

  enum :role, { viewer: "viewer", member: "member", admin: "admin" }

  # Everyone but a viewer: the roles that may open the editor and create.
  # Defined by exclusion, exactly as can_edit_vertos? is, so a fourth role
  # can't land in one and not the other.
  scope :editing, -> { where.not(role: "viewer") }

  # Most recently acted-in first. Only rows that HAVE a visit: a membership
  # nobody has opened since the column arrived is not "least recent", it is
  # unknown, and the two engines disagree about where a NULL sorts under DESC
  # (last in SQLite, FIRST in Postgres), so leaving them in would put every
  # never-opened account at the top of the list in production alone.
  scope :recently_visited, -> { where.not(last_visited_at: nil).order(last_visited_at: :desc) }

  # How often a request inside an account re-records that the person is
  # still there. Same shape and reasoning as Session#touch_seen!: at most
  # one write per membership per hour, which is nothing beside the queries
  # the same page runs, and far finer than "which two clients did I open
  # most recently" needs.
  VISITED_EVERY = 1.hour

  # Records that this person is acting in this account now. Called from the
  # request that resolves the acting organisation (throttled), and from the
  # Workspaces switcher with force: true — switching IS the moment of choice,
  # and a throttled write there would leave "the two most recent" wrong for
  # anyone who hops between accounts inside an hour (A at 10:00, B at 10:05,
  # back to A at 10:10 would still read B as the more recent).
  #
  # `update_column` on purpose: no validations, no callbacks, no touching of
  # updated_at (which is when the ROLE last changed), and it writes the
  # in-memory attribute too, so the throttle holds for the rest of the request.
  def touch_visited!(force: false)
    return if !force && last_visited_at && last_visited_at > VISITED_EVERY.ago

    update_column(:last_visited_at, Time.current)
  end

  # May this membership create or edit Vertos in its organisation? Admin and
  # member both can; viewer is the one that can't. The account-level creation
  # switch (Organisation#verto_creation_enabled) is a separate question, asked
  # by OrganisationScope#can_create_vertos?.
  def can_edit_vertos?
    !viewer?
  end
end
