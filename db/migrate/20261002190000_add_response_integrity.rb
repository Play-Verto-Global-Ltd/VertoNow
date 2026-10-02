class AddResponseIntegrity < ActiveRecord::Migration[8.1]
  # The Verto Integrity Score (ResponseIntegrity). Raw signals, the score, the
  # band and the scoring version on each response; each Verto's timing
  # baseline on the survey.
  #
  # The signals sit in json beside the answers, never inside them, for the
  # reason dwell_ms does: an answer entry is treated as an answer everywhere it
  # travels. The score and band are real columns because they are what gets
  # FILTERED — by the exclude-Low results filter and the Commons gate — and
  # filtering on a value inside json is dialect-specific (Postgres has no json
  # equality operator), the same reason `answered` and the demographic
  # columns were lifted out of `answers`.
  #
  # The band is NOT NULL with a default of "unscored". A nullable band would
  # make `where.not(integrity_band: "low")` silently drop every NULL row —
  # every response collected before this, and every import, which never
  # passes through the scorer (insert_all! runs no callbacks) — the moment a
  # creator excluded Low responses. "unscored" is the honest state of those
  # rows, and the one the Commons gate is designed to let through.
  def change
    add_column :responses, :integrity, :json, default: {}, null: false
    add_column :responses, :integrity_score, :integer
    add_column :responses, :integrity_band, :string, default: "unscored", null: false
    add_column :responses, :integrity_version, :integer
    add_index :responses, [ :survey_id, :integrity_band ], name: "index_responses_on_survey_and_integrity_band"
    add_check_constraint :responses,
                         "integrity_band IN ('high', 'medium', 'low', 'unscored', 'unverified')",
                         name: "chk_responses_integrity_band"

    add_column :surveys, :integrity_baseline, :json, default: {}, null: false
  end
end
