class AddDwellMsToResponses < ActiveRecord::Migration[8.1]
  # How long the respondent spent on each card before moving on — "dwell
  # time", the time it takes to answer each question — keyed by card index
  # exactly as `answers` is ({ "3" => 12400 }, whole milliseconds).
  #
  # Its own column rather than a field inside each answer entry, because an
  # answer entry is treated AS an answer everywhere it travels: locked_merge
  # pins it, moderation scrubs it, RespondentRecall seeds the next run from it,
  # the account page compares it. A timing riding inside would be frozen with
  # a quiz answer, replayed into an ask-once seed, and handed back to the
  # respondent as part of "what you answered". Beside the answers, like
  # token_totals and the demographic columns, it is read by the results page
  # and the exports and by nothing that decides what an answer is.
  #
  # The unit is in the name so a reader of the column never has to guess —
  # duration_seconds next door is seconds, and a figure that is three orders of
  # magnitude out is the kind of mistake nothing downstream can catch.
  def change
    add_column :responses, :dwell_ms, :json, default: {}, null: false
  end
end
