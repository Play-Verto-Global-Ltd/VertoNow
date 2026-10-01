# Per-question dwell time across a set of responses — how long respondents
# typically took to answer each card — for the results page and the summary
# export.
#
# The headline is the MEDIAN, not the mean. Response#duration_seconds already
# carries the warning: a submit drained from the offline queue lands whenever
# the device next has a network, and one such row can put an hour into an
# average of twelve seconds. The mean rides along for the tooltip and the
# export, where a reader can weigh it against the median themselves.
#
# "Time to answer" means exactly that: a card only contributes a respondent's
# time when that respondent ANSWERED it (Response.answered_entry?, the one
# definition). Someone who read a question and moved on without answering is
# in the per-response export's dwell column — their time is real — but not in
# this figure, which the results page presents beside the answer count and
# which must therefore be over the same people.
#
# Deliberately not folded into AggregatesSurveyResults#aggregate_results: that
# output is shared by the player's end-of-Verto comparison, the account page,
# CommonQuestionAggregator, the wave deltas and the AI report, and none of
# them want timings. One extra batched pass over id/answers/dwell_ms, on the
# two surfaces that do.
module DwellTimes
  module_function

  # cards:     the deck (Array of card Hashes), so only question cards count
  # responses: an AR relation (batched, three columns) or an Array of Response
  #            objects — the same duality the aggregator's each_response has.
  #
  # Returns { card_index(Integer) => { n:, median_ms:, mean_ms: } } for every
  # question card at least one respondent both answered and was timed on.
  def for(cards, responses)
    cards   = Array(cards)
    indices = cards.each_index.select { |i| cards[i].is_a?(Hash) && CardTypes.question?(cards[i]["type"]) }
    return {} if indices.empty?

    samples = Hash.new { |h, k| h[k] = [] }
    each_response(responses) do |answers, dwell|
      next unless dwell.is_a?(Hash)
      answers = {} unless answers.is_a?(Hash)

      indices.each do |idx|
        key = idx.to_s
        ms  = dwell[key]
        next unless ms.is_a?(Numeric) && ms.positive?
        next unless Response.answered_entry?(answers[key])

        samples[idx] << ms
      end
    end

    samples.transform_values { |list| stats_for(list) }
  end

  # Only rows that carry any dwell at all are read. Every response collected
  # before the measurement existed (an imported Verto is a hundred thousand
  # of them) holds `{}`, and a second full scan of their answers JSON to
  # produce an empty hash is the results page's cost doubled for nothing.
  #
  # The guard is a text comparison on purpose. `where.not(dwell_ms: {})` is
  # the obvious spelling, and it is the Postgres 500 CLAUDE.md warns about:
  # the `json` type has no equality operator there, while SQLite is happy —
  # the exact divergence that took Ask Verto down. CAST to TEXT runs on both,
  # and both store an empty map as the two characters `{}` (ActiveRecord
  # serialises with JSON.generate; the column default is the same literal).
  def each_response(responses)
    if responses.respond_to?(:find_each)
      responses.where("CAST(responses.dwell_ms AS TEXT) <> '{}'").reorder(nil)
               .select(:id, :answers, :dwell_ms).find_each(batch_size: 500) do |r|
        yield(r.answers, r.dwell_ms)
      end
    else
      responses.each { |r| yield(r.answers, r.dwell_ms) }
    end
  end

  def stats_for(list)
    sorted = list.sort
    n      = sorted.size
    median = n.odd? ? sorted[n / 2] : (sorted[(n / 2) - 1] + sorted[n / 2]) / 2.0
    { n: n, median_ms: median.round, mean_ms: (sorted.sum.to_f / n).round }
  end
end
