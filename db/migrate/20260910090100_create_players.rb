# A respondent's own account — the first identity in this app that belongs to
# the person answering rather than the person asking.
#
# It is deliberately NOT the creator `User`. Keeping the two tables apart is
# what keeps respondent addresses out of org memberships, Comms audiences,
# `all_users` campaigns and the whole studio surface; a role flag on `users`
# would have put them one careless scope away from all of it.
#
# No password column at all, and none is coming: sign-in is a link in an
# email (see player_sign_in_links). Two Vertos can be six months apart, which
# is long enough that a password would be forgotten by the second one.
class CreatePlayers < ActiveRecord::Migration[8.1]
  def change
    create_table :players do |t|
      # Stored already normalised — dev/test run SQLite and production runs
      # Postgres, and LOWER() over a column is exactly the sort of thing the
      # two engines disagree about. Every email_* table here does the same.
      t.string :email_address, null: false

      # Optional, and only ever used to greet them.
      t.string :name

      # Applied explicitly when a mailer renders: a mailer runs in a Solid
      # Queue job with no request and therefore no Current.locale.
      t.string :preferred_locale

      # Stamped when they first follow a link from their own inbox. Until
      # then the address is unproven, and nothing may be sent to it beyond
      # a link that proves it — the sign-in link, or (since 2026-09-23) the
      # one address confirmation the password signup sends.
      t.datetime :email_verified_at

      t.timestamps
    end

    add_index :players, :email_address, unique: true
  end
end
