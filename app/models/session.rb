class Session < ApplicationRecord
  belongs_to :user

  # How often a live session records that it is still being used.
  #
  # A Session row was written at sign-in and never written again —
  # Authentication#find_session_by_cookie is a plain find_by — so `updated_at`
  # stayed equal to `created_at` for the whole life of a login, and every
  # "last active" the database could answer actually meant "last SIGNED IN".
  # Someone who signs in once and then works in the product daily for a month
  # left exactly one timestamp, a month old. On 17 September 2026 a customer
  # whose last sign-in was 23 days earlier had been in the editor that morning,
  # and every usage figure we had said they were gone; three separate readings
  # of retention were wrong in the same direction because of it.
  #
  # This is also the only signal that covers READING. Creating, editing,
  # sharing and inviting all leave their own rows; opening the results of a
  # Verto that is already collecting writes nothing anywhere, and that is most
  # of what a customer does once their Verto is live.
  #
  # Throttled rather than per-request, the same shape as
  # LanguageCheckLink#touch_seen!: at most one write per session per hour,
  # which is a rounding error beside the queries the same page already runs,
  # and an hour is far finer than the weekly buckets a retention question asks.
  SEEN_EVERY = 1.hour

  # `update_column` on purpose: no validations, no callbacks, no touching of
  # anything else, and a row a concurrent sign-out has already deleted simply
  # updates nothing instead of raising. It writes the in-memory attribute too,
  # so the guard above holds for the rest of the request — `authenticated?`
  # calls resume_session again on every render that asks.
  def touch_seen!
    return if updated_at.nil? || updated_at > SEEN_EVERY.ago
    update_column(:updated_at, Time.current)
  end
end
