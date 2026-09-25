class AddLastVisitedAtToMemberships < ActiveRecord::Migration[8.1]
  # When this person last acted inside this account. Written by
  # Membership#touch_visited! from the request that resolves the acting
  # organisation (throttled) and from the Workspaces switcher (every time), so
  # a staff member who works in many client accounts gets a picker that leads
  # with the two they were in most recently, and the Clients dashboard can say
  # when each account was last opened.
  #
  # Nullable and no backfill: nothing recorded this before, and a guessed
  # value (memberships.updated_at is when the ROLE last changed) would put a
  # client the person has not opened in months at the top of the list.
  def change
    add_column :memberships, :last_visited_at, :datetime
  end
end
