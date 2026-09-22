class AddResultsInsightsToSurveys < ActiveRecord::Migration[8.1]
  # One reading per question, cached beside the whole-survey summary that has
  # sat in `results_summary` since the results page got its Ask Verto blurb.
  #
  # A single JSON column rather than a column per part, because the cache key
  # is a COMPOUND one and splitting it invites a half-updated pair: a reading
  # is only replayable for the same segment AND the same response count, and
  # keeping the three together means they are written in one statement and can
  # never disagree. Shape:
  #
  #   { "segment" => "region_GB", "count" => 128,
  #     "questions" => { "8" => "Two thirds say cost…", "9" => "…" } }
  #
  # Keyed by CARD INDEX, as a string, which is the same positional key every
  # answer is already stored under (see the deck-order note in CLAUDE.md) — so
  # a reordered deck invalidates these exactly as it re-points everything else,
  # and nothing here is more fragile than the answers themselves.
  def change
    add_column :surveys, :results_insights, :json
  end
end
