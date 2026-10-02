# The review state of one card's wording in one language. See the migration
# for why it is keyed by cid and why content_digest exists.
class LanguageCheck < ApplicationRecord
  belongs_to :survey
  belongs_to :reviewed_by_user, class_name: "User", optional: true
  belongs_to :language_check_link, optional: true

  STATUSES = %w[pending approved changes_requested].freeze
  MAX_NAME = 60
  # A translator note says what a word MEANS, in a sentence or two; it rides
  # along with the card on every translation call, so it is kept short.
  MAX_TRANSLATOR_NOTE = 500

  validates :cid, :locale, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :approved, -> { where(status: "approved") }

  # Find-or-build for one line. Not find_or_create_by: the screen renders a
  # line for every (card, language) pair in the deck, and materialising a row
  # per line on a page VIEW would write hundreds of rows for a Verto nobody has
  # reviewed yet. Rows appear when somebody acts.
  def self.for_line(survey, cid, locale)
    find_or_initialize_by(survey_id: survey.id, cid: cid.to_s, locale: locale.to_s)
  end

  # Every stored row for a Verto, indexed the way the views want it.
  def self.index_for(survey)
    where(survey_id: survey.id).index_by { |r| [ r.cid, r.locale ] }
  end

  # Has the wording moved since this row was decided? An approval is an
  # approval of particular words (LanguageCheckLines.digest), so text edited
  # afterwards leaves the tick behind — the row stays `approved` and the screen
  # shows it as stale rather than silently downgrading a reviewer's decision to
  # pending, which would erase the fact that somebody did look at it.
  #
  # Two ways a line goes stale, and both have to count. Its OWN words changing
  # is the obvious one. The other is the primary language underneath it
  # changing: approving a Spanish line is a judgement that it says what the
  # English says, so a rewritten English question invalidates it just as surely
  # as a rewritten Spanish one. source_digest is null on primary-language rows
  # (nothing above them) and on rows decided before this was recorded, where
  # the honest answer is "we cannot tell" and the tick is left alone.
  def stale_for?(digest, source_digest_now = nil)
    return false if status == "pending"
    return true if content_digest.present? && digest.present? && content_digest != digest
    source_digest.present? && source_digest_now.present? && source_digest != source_digest_now
  end

  # The state a line is actually IN, given the words on screen right now.
  # One method so the owner's screen, the reviewer's screen and the progress
  # counter can never disagree about what a line's badge says.
  def self.state_for(row, digest, source_digest_now = nil)
    return "pending" if row.nil? || row.status == "pending"
    return "stale" if row.stale_for?(digest, source_digest_now)
    row.status
  end

  # Is this translation older than the original it was made from? See the
  # migration: translated_from_digest is the primary wording the words on this
  # line were produced against, and nil — every line translated before this
  # was recorded — is "we cannot tell", which shows nothing rather than guess.
  def outdated_for?(source_digest_now)
    translated_from_digest.present? && source_digest_now.present? &&
      translated_from_digest != source_digest_now
  end

  # Note which original each of these translations was made from: `pairs` is
  # [[cid, locale, source_digest], ...]. One statement for a whole deck, and it
  # touches only the provenance column, so a row carrying a reviewer's
  # decision keeps it — a fresh translation of an approved line shows as
  # changed since approval, which is the truth.
  #
  # `revision:` is for a write the open editor did not make (a translation job,
  # an import's translation pass): it stamps edit_revision, so an editor tab
  # rendered before it carries these lines forward on autosave rather than
  # deleting them — the same guard a reviewer's edit gets. The editor's own
  # save passes none; it cannot be stale about what it just wrote.
  def self.record_translated!(survey_id, pairs, revision: nil)
    pairs = Array(pairs).uniq { |cid, locale, _| [ cid.to_s, locale.to_s ] }
    return if survey_id.nil? || pairs.empty?

    now  = Time.current
    rows = pairs.map do |cid, locale, digest|
      row = { survey_id: survey_id, cid: cid.to_s, locale: locale.to_s, status: "pending",
              translated_from_digest: digest, created_at: now, updated_at: now }
      revision ? row.merge(edit_revision: revision) : row
    end
    update_only = revision ? %i[translated_from_digest edit_revision] : %i[translated_from_digest]
    upsert_all(rows, unique_by: %i[survey_id cid locale], update_only: update_only)
  end

  # { cid => note } for every card whose author has said what it means. Read
  # off the primary-language rows, which are the only ones that carry one.
  def self.translator_notes_for(survey)
    where(survey_id: survey.id, locale: survey.default_locale)
      .where.not(translator_note: [ nil, "" ])
      .pluck(:cid, :translator_note).to_h
  end

  def reviewer_label
    reviewed_by_user&.name.presence || reviewed_by_name.presence
  end
end
