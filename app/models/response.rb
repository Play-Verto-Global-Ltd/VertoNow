class Response < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_share, optional: true
  # Which named send link this respondent arrived through, if any. Optional:
  # everyone on the Verto's own /play link has none, and so does every response
  # collected before send links existed.
  belongs_to :survey_link, optional: true
  # Free-text answers lifted out of `answers` until moderation passes them —
  # see HeldText and Moderation. Gone with the response, in one DELETE.
  has_many :held_texts, dependent: :delete_all
  # Respondent accounts that have claimed this response. delete_all rather than
  # nothing: the foreign key is RESTRICT (this repo has six ON DELETE CASCADEs
  # in total and none on a responses FK), so without this the GDPR erasure in
  # RespondentDataController#destroy raises InvalidForeignKey instead of
  # erasing. The claim goes; the account does not.
  has_many :player_claims, dependent: :delete_all
  validates :session_token, presence: true, uniqueness: true

  # The only two states a response is ever in: "started" once it has an answer,
  # "completed" once the respondent reaches the end. Every other model with a
  # status column already declared its values; this one didn't, so the P2-8
  # database CHECK would have surfaced a bad value as a raw DB exception rather
  # than an ordinary validation error.
  STATUSES = %w[started completed].freeze
  validates :status, inclusion: { in: STATUSES }

  # Small-cell suppression for region groupings: any region/results view
  # grouped by region_country should drop groups smaller than this before
  # display, so a single respondent (or a handful) is never singled out on a
  # map or in a per-country breakdown.
  #
  # 10 since 2026-10-02 (it was 5): the Privacy Notice tells respondents that
  # no result is produced from a group of fewer than 10, and the owner chose
  # to make the product match the notice rather than the other way round. One
  # constant, so the map, the segment pills, the respondent's end-of-Verto
  # comparison, the account page, the answer timeline, the partner page and
  # the public results link all move together.
  MIN_REGION_SAMPLE_SIZE = 10

  # Keep the denormalised `answered` flag (answered ≥1 question with a value) in
  # sync on every save, so the dashboard can count responders with a grouped SQL
  # query instead of loading every response's answers JSON. See the
  # add_answered_to_responses migration.
  before_save :sync_answered

  # Live results. Deliberately NOT on every save: /progress can write on every
  # card (it does under No going back), so a single respondent may save a dozen
  # times and broadcasting each one would
  # put a burst of renders on the instance for no new information.
  #
  # Only two transitions actually change what a creator sees — a response
  # becoming a responder (its first real answer) and a responder finishing — so
  # those are what broadcast, at most twice per respondent.
  after_commit :broadcast_results_activity, on: [ :create, :update ]

  # Keep the precomputed leaderboard (LeaderboardStanding) trailing reality by
  # at most a few seconds. Same posture as the broadcast above: fires only on
  # the transitions that change a board — a run completing, or an identity
  # vanishing (the consent-decline purge nils player_key_digest) — and a cache
  # debounce coalesces a burst of finishers into one refresh per window.
  after_commit :refresh_leaderboard_standings, on: [ :create, :update ]

  # How long the respondent took, in whole seconds, or nil until both ends are
  # stamped. Derived rather than stored so there's no third column to keep in
  # sync with the two timestamps.
  #
  # Caveat worth knowing before reading these as engagement data: a submit that
  # was queued offline drains whenever the device next has a network, so
  # completed_at is server-receipt time and the duration can be wildly long.
  def duration_seconds
    return nil if started_at.blank? || completed_at.blank?

    (completed_at - started_at).round
  end

  # ── Dwell time ─────────────────────────────────────────────────────────────
  # How long the respondent spent on each card before moving on, keyed by card
  # index like `answers` ({ "3" => 12400 }, whole milliseconds) — the time it
  # took to answer each question. Measured by the player (its clock stops
  # while the tab is hidden and once a quiz answer is checked; see
  # _bankDwell in player_controller.js) and sent with every save.
  #
  # Self-reported by the client, like every answer, so the server bounds it
  # rather than trusts it: a figure above this is junk (a day on one card is
  # not a measurement), and an entry for a card the deck doesn't have is
  # dropped. In milliseconds, like the column.
  DWELL_CAP_MS = 24 * 60 * 60 * 1000

  # The stored dwell for one card, folded with what a save just sent. Per key
  # the LARGER wins. Within one page load the player's totals only grow, and
  # max is the backstop for whatever arrives out of order (a grade and a
  # progress racing, a submit drained from the service worker's queue after
  # a later save): nothing can shrink a figure, and a save that arrives
  # without one leaves the stored value standing. The player keeps its totals
  # in memory only, as it keeps the answers, so a reload starts them again;
  # for a card timed on both sides of a reload, the larger of the two stands. Keys are strings of digits naming a QUESTION card in `cards` —
  # the player times every card with an index, welcome and checkpoint cards
  # included, but nothing reports those, so nothing holds them. Values are
  # numbers from zero to the cap. Anything else is ignored, never coerced —
  # this endpoint is public JSON.
  def self.merge_dwell(stored, incoming, cards:)
    merged = stored.is_a?(Hash) ? stored.dup : {}
    return merged unless incoming.is_a?(Hash)

    cards = Array(cards)
    incoming.each do |key, value|
      key = key.to_s
      # Canonical digits only: "07" would be looked up as card 7 and stored
      # under a key nothing reads, and a crafted client could grow a row with
      # as many such keys as it liked.
      next unless key.match?(/\A\d+\z/) && key == key.to_i.to_s
      card = cards[key.to_i]
      next unless card.is_a?(Hash) && CardTypes.question?(card["type"])

      ms = value.is_a?(Numeric) ? value.to_f : (value.is_a?(String) && value.match?(/\A\d+(\.\d+)?\z/) ? value.to_f : nil)
      # finite? refuses NaN and ±Infinity, either of which would raise on round.
      next unless ms&.finite? && ms >= 0

      ms = [ ms.round, DWELL_CAP_MS ].min
      merged[key] = ms if ms > (merged[key].is_a?(Numeric) ? merged[key] : 0)
    end
    merged
  end

  # Seconds spent on the card at `index`, to one decimal, or nil where the
  # player recorded nothing (a response collected before dwell existed, a
  # card never shown, a replay that arrived without it).
  def dwell_seconds_at(index)
    ms = dwell_ms.is_a?(Hash) ? dwell_ms[index.to_s] : nil
    return nil unless ms.is_a?(Numeric) && ms.positive?

    (ms / 1000.0).round(1)
  end

  # THE definition of "this card was answered", for the whole app.
  #
  # It used to exist twice in Ruby and once in JavaScript, and all three
  # disagreed. This one is the canonical Ruby copy: PlayerController#answered?
  # delegates to it, and _isAnswered in player_controller.js mirrors it (pinned
  # by test/system/answer_parity_test.rb).
  #
  # The two things it must get right, because getting them wrong is silent:
  #
  #   * an "Other" write-in IS an answer. `content_answered?` used to check only
  #     `value`, so a respondent whose single answer was typed into the Other
  #     box was stored with `answered = false` and disappeared from every
  #     responder-scoped view — undercounting real, completed responses.
  #   * `present?` is the wrong test for a value. `false.present?` is false in
  #     Rails, so a boolean answer read as unanswered. Emptiness is checked by
  #     shape here instead.
  def self.answered_entry?(entry)
    return false unless entry.is_a?(Hash)
    return true if entry["other"].to_s.strip != ""
    # A free-text answer the moderator is holding (or has removed) was GIVEN —
    # the respondent typed it and the row exists; only its text is elsewhere.
    # Counting it keeps responder counts, the quiz/token locks and the results
    # totals identical whether or not the text has been passed yet. See
    # Moderation::Hold for the marker's shape.
    return true if held_entry?(entry)

    v = entry["value"]
    return v.any? if v.is_a?(Array) || v.is_a?(Hash)
    !(v.nil? || (v.is_a?(String) && v.strip.empty?))
  end

  # Does this answer carry a moderation marker for either slot?
  def self.held_entry?(entry)
    entry.is_a?(Hash) && entry["held"].is_a?(Hash) && entry["held"].values.any?
  end

  # Declining consent is not just a timestamp — it means "do not collect my
  # data", so the data goes.
  #
  # A consent gate can sit after some questions on a deck built before gates
  # were hoisted ahead of the first question, and /progress persists answers on
  # every advance. So by the time a respondent read the sheet and declined,
  # their earlier answers were already stored, already counted as a responder,
  # and already feeding the public /results and /regions aggregates. Stamping
  # consent_declined_at changed none of that.
  #
  # The row itself stays: consent_declined_at plus the wording they saw is the
  # evidence that a decline was honoured, and the decline rate is worth knowing.
  # Everything they gave is cleared, including the denormalised region and
  # demographic columns — those are copies of answers, and leaving them would
  # keep exactly the personal data the gate exists to protect. Clearing
  # `answers` also drops `answered` to false via sync_answered, which is what
  # takes the row out of every responder-scoped view.
  def purge_for_declined_consent!
    self.answers = {}
    # The held copies of their free text are their data too, and the only
    # place it still exists once `answers` is cleared.
    held_texts.delete_all if persisted?
    # status is deliberately left alone: STATUSES is a closed set with a DB
    # CHECK constraint behind it, and a declined respondent is by definition
    # mid-deck, so the row is "started" and already excluded from every
    # status: "completed" count. `answered` going false is what removes it from
    # the responder counts, which is the number that was wrong.
    self.region_country = nil
    self.region_label = nil
    self.demographic_gender = nil
    self.demographic_birth_year = nil
    self.demographic_age_band = nil
    self.demographic_heritage = nil
    self.demographic_neurodiversity = nil
    self.score = nil
    self.quiz_max = nil
    self.token_totals = {}
    # How long they lingered on each question is behavioural data about them,
    # collected on the same promise as the answers it timed.
    self.dwell_ms = {}
    self.respondent_code_digest = nil
    # The leaderboard identity is a durable handle on this person's plays —
    # exactly the kind of thing the decline purge exists to drop.
    self.player_key_digest = nil
  end

  # Whether this response holds a real answer to at least one question.
  # Drives the `answered` column / responder counts.
  def content_answered?
    answers.is_a?(Hash) && answers.values.any? { |a| self.class.answered_entry?(a) }
  end

  private

  def sync_answered
    self.answered = content_answered?
  end

  # Whether the live results tally is currently shed. DISABLE_RESULTS_BROADCAST=1
  # sets the boot default (turn it off from the start of a window); the cache
  # flag "degrade:results-broadcast" flips it live from a console with no deploy
  # or restart. Fails open (keep broadcasting) if the cache read errors, so a
  # cache blip never silences the tally on an ordinary day.
  def self.results_broadcast_disabled?
    return true if ENV["DISABLE_RESULTS_BROADCAST"] == "1"

    Rails.cache.read("degrade:results-broadcast") ? true : false
  rescue StandardError
    false
  end

  def broadcast_results_activity
    return unless saved_change_to_answered? || saved_change_to_status?
    # Broadcast when a response BECOMES answered, and also when it STOPS being
    # answered — the decline purge flips answered true→false, and that is the
    # one transition where a creator's live results screen is showing numbers
    # that must go DOWN. The old `return unless answered?` suppressed exactly
    # that broadcast. Still silent for an empty session that never answered.
    return unless answered? || saved_change_to_answered?

    # Event degrade switch. The creator's live tally is a nicety and the first
    # thing to shed under a burst; the leaderboard refresh below is NOT gated
    # because it is respondent-facing. Checked at runtime so it can be flipped
    # from a Rails console mid-event, without a deploy or a restart (the runbook's
    # "disable the live broadcast" step) — env sets the boot default.
    return if self.class.results_broadcast_disabled?

    # Off the request thread and coalesced: the broadcast used to run its two
    # COUNTs, a partial render and a cable INSERT inline here, twice per
    # respondent, whether or not anyone was watching. Same claim-a-window
    # debounce as the standings refresh below — one broadcast per survey per
    # window, fired after the window closes so the last transition is captured.
    claimed = Rails.cache.write("results-activity:#{survey_id}", 1,
                                unless_exist: true, expires_in: REFRESH_STANDINGS_DEBOUNCE)
    return unless claimed

    BroadcastResultsActivityJob.set(wait: REFRESH_STANDINGS_DEBOUNCE).perform_later(survey_id)
  rescue => e
    # A live counter is a nicety. It must never be able to fail the write that
    # stored a respondent's answers.
    ErrorReporting.report("Response#broadcast_results_activity", e, survey_id: survey_id)
  end

  REFRESH_STANDINGS_DEBOUNCE = 3.seconds

  def refresh_leaderboard_standings
    relevant = (saved_change_to_status? && status == "completed") ||
               (saved_change_to_player_key_digest? && status == "completed")
    return unless relevant
    return unless player_key_digest.present? || saved_change_to_player_key_digest?
    return unless survey.leaderboard_active?

    # unless_exist makes the cache write a claim on this window: the first
    # finisher schedules the refresh, everyone else inside the window skips.
    # The job runs AFTER the window closes, so the trailing completion is
    # always captured; when the key expires the next finisher opens a new one.
    claimed = Rails.cache.write("leaderboard-refresh:#{survey_id}", 1,
                                unless_exist: true, expires_in: REFRESH_STANDINGS_DEBOUNCE)
    return unless claimed

    RefreshLeaderboardStandingsJob.set(wait: REFRESH_STANDINGS_DEBOUNCE).perform_later(survey_id)
  rescue => e
    # Derived data — never allowed to fail the write that stored the answers.
    ErrorReporting.report("Response#refresh_leaderboard_standings", e, survey_id: survey_id)
  end
end
