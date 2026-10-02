# One Verto's membership of the Ask Verto corpus, and the two consent gates that
# decide it.
#
# THE RULE, and there is only one:
#
#   A Verto's data may be used to answer a question when its creator has opted in,
#   has not withdrawn, AND VertoNow has approved it. All three, every time.
#
# `citable` (the scope) and `citable?` (the predicate) are the single expression of
# that rule. Every read of corpus data starts from the scope — CorpusTools has no
# other entry point — so there is exactly one place to get this right and exactly
# one place to test it.
#
# Two properties that are easy to lose and expensive to lose:
#
#   * Withdrawal is a READ-TIME filter, not a rebuild. Clearing withdrawn_at is what
#     restores a Verto; deleting its index is not required and must not be relied on.
#     A withdrawal that only took effect at the next re-index would leave a window
#     where a creator has said no and the product is still answering from their data.
#   * A decline does NOT clear the creator's opt-in. The creator said yes; if the
#     reason (too few responses, say) is later fixed, they should not have to say it
#     again. review_status moves back to pending, the opt-in stays where it was.
class CorpusEntry < ApplicationRecord
  belongs_to :survey
  belongs_to :organisation
  belongs_to :opted_in_by, class_name: "User", optional: true

  has_many :corpus_questions, dependent: :destroy

  REVIEW_STATUSES = %w[pending approved declined].freeze
  validates :review_status, inclusion: { in: REVIEW_STATUSES }

  # Small-cell suppression: the smallest group Ask Verto will publish a figure
  # about. Below it, a distribution starts describing identifiable individuals
  # rather than a population — the same reasoning behind
  # Response::MIN_REGION_SAMPLE_SIZE, and it matters more here because this data
  # crosses an organisation boundary rather than staying inside the account that
  # collected it.
  #
  # It is a setting rather than a constant because the account owner decides how
  # their own respondents may be published. The default is 10, the floor the
  # Privacy Notice promises for "a report, the Data Commons or an Ask Verto
  # answer", and the owner's decision of 2026-10-02 to make the product keep
  # that promise. It replaces the 2026-08-08 instruction to suppress nothing,
  # under which a segment containing one child was publishable to anyone with
  # an account. `ASK_VERTO_MIN_CELL` still overrides it per deployment (30 was
  # the original floor); setting it below 10 breaks the notice's promise.
  #
  # Importing is unaffected either way — every response is stored whatever this
  # says. The floor only ever governed what may be cited.
  DEFAULT_MIN_SAMPLE_SIZE = [ ENV.fetch("ASK_VERTO_MIN_CELL", Response::MIN_REGION_SAMPLE_SIZE).to_i, 1 ].max

  class << self
    attr_writer :min_sample_size

    def min_sample_size = @min_sample_size || DEFAULT_MIN_SAMPLE_SIZE

    # Run a block with a different floor. The setting is read at call time
    # rather than load time so this can exist: the suppression machinery still
    # has to be provably correct even on a deployment that has turned it off.
    def with_min_sample_size(value)
      previous = @min_sample_size
      @min_sample_size = value
      yield
    ensure
      @min_sample_size = previous
    end
  end

  # The submit-your-data picker's eligibility bar: published, with at least
  # this many responses carrying answers. PROVISIONAL — the Verto team is
  # still deciding the final rules (owner's note, 2026-08-11) — which is why
  # it is one constant with one call site (`submittable_state`) rather than
  # anything structural. Distinct from min_sample_size: that governs what may
  # be CITED, this governs what may be OFFERED from the picker.
  SUBMISSION_MIN_RESPONSES = 50

  # The creator's half of the gate: offered and not taken back.
  scope :offered, -> { where.not(opted_in_at: nil).where(withdrawn_at: nil) }

  # THE scope. Nothing reads corpus data except through this.
  scope :citable, -> { offered.where(review_status: "approved") }

  # What the review queue works through, freshest offer last so the oldest wait is
  # at the top.
  scope :awaiting_review, -> { offered.where(review_status: "pending").order(opted_in_at: :asc) }

  scope :withdrawn, -> { where.not(withdrawn_at: nil) }

  def opted_in?  = opted_in_at.present? && withdrawn_at.nil?
  def withdrawn? = withdrawn_at.present?
  def approved?  = review_status == "approved"
  def declined?  = review_status == "declined"
  def pending?   = review_status == "pending"

  # Must agree with the `citable` scope, exactly. The model test asserts that for
  # every combination rather than trusting the two to stay in step.
  def citable?
    opted_in? && approved?
  end

  # What the creator's editor panel shows. One value, so the view has no logic to
  # get subtly different from this.
  #
  #   :off        never offered, or withdrawn — the resting state
  #   :pending    offered, waiting on us
  #   :live       citable
  #   :declined   offered, we said no (review_note carries why)
  def creator_state
    return :off if opted_in_at.blank? || withdrawn?
    return :declined if declined?
    return :live if approved?

    :pending
  end

  # ── Offered scope: question-set granularity ────────────────────────────────
  # `offered_scope` narrows WHAT was offered, the way opted_in_at records THAT
  # it was. `{}` — the default, and every pre-existing row — means the whole
  # Verto. A narrowed scope looks like:
  #
  #   { "common_question_set_ids" => [3], "own_questions" => false }
  #
  # The indexer asks this predicate per card, so a question outside the offer
  # never becomes a corpus row — the boundary is enforced where the data
  # crosses, not in the picker UI.
  def offers_card?(card)
    return true if offered_scope.blank?

    set_id = card["common_question_set_id"]
    if set_id.present?
      Array(offered_scope["common_question_set_ids"]).include?(set_id)
    else
      offered_scope["own_questions"] == true
    end
  end

  def whole_verto_offered? = offered_scope.blank?

  # Why a Verto can (or cannot) be picked in the submit-your-data modal.
  # One value so the picker renders states without re-deriving consent logic:
  #
  #   :ready      selectable
  #   :unpublished, :too_few_responses   locked, with the reason
  #   :pending, :live                    already offered — locked, informative
  #   :declined   SELECTABLE — declined last time, the review note shown on
  #               the row, and resubmitting restarts review (opt_in! moves a
  #               declined entry back to pending). The base bar still applies
  #               first: a declined Verto that is now unpublished or under the
  #               floor locks on that reason, as any fresh offer would.
  def self.submittable_state(survey, answered_count:)
    entry = find_by(survey_id: survey.id)
    if entry&.opted_in?
      return :live    if entry.approved?
      return :pending if entry.pending?
    end

    return :unpublished       unless survey.published?
    return :too_few_responses if answered_count < SUBMISSION_MIN_RESPONSES

    entry&.opted_in? && entry.declined? ? :declined : :ready
  end

  # ── Transitions ────────────────────────────────────────────────────────────
  # Each one is a whole statement about consent, so each is its own method rather
  # than callers assembling update! calls that drift apart.

  # The creator offers the Verto. Re-offering after a withdrawal clears the
  # withdrawal and starts review again: our previous approval was granted against
  # a consent that has since been revoked, so it does not carry over. Re-offering
  # after a DECLINE also restarts review — the class comment always promised
  # that ("if the reason is later fixed, they should not have to say it again"),
  # and the picker's resubmit path (2026-08-11) is where it comes true. The
  # decline's note stays on the row until the next decision overwrites it, so
  # the reviewer sees what was objected to last time.
  #
  # `scope` narrows the offer to question sets (see offers_card?). nil means
  # "don't touch what's stored" so the survey page's whole-Verto toggle keeps
  # its meaning; pass {} explicitly to widen a narrowed offer back out.
  def opt_in!(user, scope: nil)
    update!(
      opted_in_at:   opted_in_at.presence || Time.current,
      opted_in_by:   opted_in_by || user,
      withdrawn_at:  nil,
      review_status: withdrawn? || declined? ? "pending" : review_status,
      **(scope.nil? ? {} : { offered_scope: scope })
    )
  end

  # The creator takes it back. The row stays — a withdrawal is a fact worth
  # keeping, and re-offering later should not look like a first offer.
  def withdraw!
    update!(withdrawn_at: Time.current)
  end

  def approve!(reviewer_email)
    update!(review_status: "approved", reviewed_at: Time.current,
            reviewed_by_email: reviewer_address(reviewer_email), review_note: nil)
  end

  # A reason is required. The creator reads it verbatim, and "not accepted" tells
  # them nothing they can act on.
  def decline!(reviewer_email, note)
    update!(review_status: "declined", reviewed_at: Time.current,
            reviewed_by_email: reviewer_address(reviewer_email),
            review_note: note.to_s.strip.presence || "No reason given.")
  end

  # The audit column is an address, but a caller holds a User as naturally as a
  # string — accept either and refuse everything else, because ActiveRecord
  # would otherwise cast whatever arrives with to_s, and "#<User:0x…>" in
  # reviewed_by_email is an audit trail that names nobody. (The import rake
  # task did exactly that, silently, until this guard.)
  def reviewer_address(reviewer)
    reviewer = reviewer.email_address if reviewer.respond_to?(:email_address)
    raise ArgumentError, "reviewer must be an email String or respond to #email_address, got #{reviewer.class}" unless reviewer.is_a?(String)

    reviewer
  end
  private :reviewer_address

  # Find-or-build for a survey, without persisting: the opt-in action creates the
  # row, and merely rendering the editor panel must not.
  def self.for(survey)
    find_by(survey_id: survey.id) ||
      new(survey: survey, organisation_id: survey.organisation_id)
  end
end
