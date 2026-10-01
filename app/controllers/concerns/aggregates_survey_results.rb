module AggregatesSurveyResults
  extend ActiveSupport::Concern

  # How long an aggregate stays cached. Short, because the numbers are meant to
  # move as people answer — this only collapses a burst into one recompute per
  # window. Keyed on updated_at so a deck edit or republish never serves the
  # previous deck's aggregates. race_condition_ttl serves the just-expired
  # value while ONE caller recomputes, so an expiry can't stampede.
  #
  # The key is deliberately shared across every caller: the respondent's
  # end-of-Verto comparison (PlayerController#results) and the same comparison
  # read later from their account (YouController#verto) are the same payload
  # about the same Verto, so the second one to ask should not pay for it again.
  # Access guards stay in the actions, OUTSIDE this — only link-independent
  # payloads live here. (In test the null cache store makes fetch a
  # pass-through.)
  SURVEY_AGGREGATE_TTL = 10.seconds

  private

  def cached_survey_aggregate(kind, survey, &block)
    Rails.cache.fetch([ "player-agg", kind, survey.id, survey.updated_at.to_f ],
                      expires_in: SURVEY_AGGREGATE_TTL,
                      race_condition_ttl: 30.seconds, &block)
  end

  # The payload the end-of-Verto comparison and the account's copy of it both
  # read, built in one place because they share a cache entry (above) and an
  # entry two builders fill differently is one whose contents depend on which
  # page was opened first. YouController used to build its own, without the
  # swipe scale, the rating average or the token rows, so a respondent who
  # opened their account moments after finishing could starve the player of
  # them for the rest of the window.
  #
  # Every responder (answered ≥1 question), not only those who reached Submit —
  # so a respondent compares against all the answers collected per question,
  # matching the creator Results screen. Each row is tallied off its own
  # answers, so partial responses count toward what they reached.
  #
  # Small-cell suppression (P1-14): with only a handful of responders the
  # "comparison" IS the other respondent's answers, attributable to them by
  # anyone who knows who else was asked. Same threshold and reasoning as the
  # map — Response::MIN_REGION_SAMPLE_SIZE. Both surfaces refuse here.
  def survey_results_payload(survey)
    responses = survey.responses.where(answered: true)
    total     = responses.count

    if total < Response::MIN_REGION_SAMPLE_SIZE
      { suppressed: true, total_responses: total, results: [] }
    else
      { total_responses: total,
        results: aggregate_rows(survey, responses) + token_comparison_rows(survey, responses) }
    end
  end

  # The flat row shape the player JS renders comparisons from, and the account
  # page pairs a respondent's answers against (ResultsComparison).
  def aggregate_rows(survey, responses)
    aggregate_results(Array(survey.cards), responses).map.with_index do |row, idx|
      {
        index:  idx,
        type:   row[:type],
        prompt: row[:card]["text"] || row[:card]["prompt"] || row[:card]["title"],
        options: row[:card]["options"],
        # What a free-text card is FOR ("location" packs "CC|Label"), so the
        # account page can say "Gauteng" rather than the stored "ZA|Gauteng".
        input:  row[:card]["input"],
        total:  row[:total],
        counts: row[:counts],
        avg:    row[:avg],
        # A tap card's counts are keyed by response key; the bars need the words
        # and the order that go with them, and the client has no other way to
        # learn a scale the creator wrote. Key + label only — the colours are
        # already on the card the respondent just answered.
        responses: (TapScales.for_card(row[:card]).map { |r| r.slice("key", "label") } if row[:type] == "tap_card")
      }.compact
    end
  end

  # Tokenisation: one synthetic row per token type, appended after the
  # per-question rows — this is how "compare your tokens" folds into the
  # existing results-comparison panel instead of a separate endpoint/panel.
  # A histogram of each response's cached token_totals[id], the same shape
  # `scores`' score histogram uses.
  def token_comparison_rows(survey, responses)
    return [] unless survey.tokenisation_enabled?
    token_types = Array(survey.token_types)
    return [] if token_types.empty?

    dist  = Hash.new { |h, k| h[k] = Hash.new(0) }
    total = 0
    responses.reorder(nil).select(:id, :token_totals).find_each(batch_size: 500) do |r|
      total += 1
      totals = r.token_totals || {}
      token_types.each { |t| dist[t["id"]][totals[t["id"]].to_i] += 1 }
    end

    token_types.map do |t|
      {
        index:    "token:#{t['id']}",
        type:     "token_total",
        token_id: t["id"],
        prompt:   [ t["icon"], t["name"] ].compact_blank.join(" "),
        total:    total,
        counts:   dist[t["id"]]
      }
    end
  end

  # Builds the per-card results distribution. Iterates the responses ONCE
  # (batched, answers-column only, for AR relations) and accumulates every
  # card's tallies in the same pass — instead of re-enumerating the full
  # response set twice per card, which held every Response object resident in
  # memory for the whole loop. Output is identical to the previous per-card
  # filter_map implementation.
  #
  # `responses` may be an ActiveRecord relation (the common case) or a plain
  # array of Response objects (e.g. CommonQuestionAggregator builds in-memory
  # Response.new rows) — each_response handles both.
  def aggregate_results(cards, responses)
    types  = cards.map { |card| card["type"].to_s }
    states = cards.each_with_index.map { |card, i| new_card_state(types[i], card) }
    total  = 0

    each_response(responses) do |answers|
      total += 1
      cards.each_index do |idx|
        a = answers[idx.to_s]
        next unless a.is_a?(Hash)

        st    = states[idx]
        value = a["value"]
        # Mirror the old `filter_map { ...dig("value") }`: drop nil/false only
        # (so 0 and "" are kept, exactly as before).
        unless value.nil? || value == false
          # Counted only if it was banked: a wrong-shaped answer at a scale
          # index (see scalar_answer?) is dropped from the tallies AND from the
          # card's total, so the header never says "2 answers" over one bar.
          st[:value_count] += 1 if accumulate_value(st, types[idx], value)
        end
        other = a["other"]
        st[:other_texts] << other if other.respond_to?(:presence) && other.presence
        # Free text the moderator is holding (or removed): answered, so it
        # counts toward the card's total exactly as the text would have, but
        # there is nothing to list — see Moderation::Hold for the marker.
        held = a["held"]
        if held.is_a?(Hash)
          st[:held_values] += 1 if held["value"]
          st[:held_others] += 1 if held["other"]
        end
      end
    end

    cards.map.with_index { |card, idx| finalize_card(card, types[idx], states[idx], total) }
  end

  # Yield each response's answers Hash (and, second, when it arrived). For
  # relations, load only id+answers+created_at in batches so the whole set is
  # never resident at once; for arrays (in-memory Response objects), iterate
  # directly. The tallies above ignore the second argument; the freeform
  # answers panel (SurveyTextAnswersController) sorts by it, and walks rows
  # through here so it accepts exactly the answers the tallies counted.
  def each_response(responses)
    if responses.respond_to?(:find_each)
      responses.reorder(nil).select(:id, :answers, :created_at).find_each(batch_size: 500) do |r|
        yield(r.answers || {}, r.created_at)
      end
    else
      responses.each { |r| yield(r.answers || {}, r.created_at) }
    end
  end

  # A tap card carries its own answer keys into the state, because they are the
  # only thing that says what an answer to THIS card can be — a five-point scale
  # and the historic yes/unsure/no are both tap cards, and a tally seeded with
  # the wrong set drops every answer it has no slot for.
  def new_card_state(type, card = nil)
    # sum_count is the number of answers actually banked into sum — the same as
    # value_count except when a wrong-shaped answer is skipped (scalar_answer?),
    # so a rating average never divides by an answer it didn't add.
    st = { value_count: 0, other_texts: [], counts: Hash.new(0), texts: [], sum: 0.0, sum_count: 0,
           held_values: 0, held_others: 0 }
    st[:response_keys] = TapScales.keys_for(card) if type == "tap_card"
    st
  end

  # Returns whether the value was accepted for this card's tally. Every branch
  # accepts — including the no-op ones, whose totals have always counted the
  # answer — except a scale card handed a wrong-shaped value, which is refused
  # rather than coerced (scalar_answer?).
  def accumulate_value(st, type, value)
    case type
    when "multiple_choice", "yes_no", "select_one_grid", "scenario"
      st[:counts][value.to_s] += 1
    when "select_many", "select_many_grid"
      Array(value).each { |v| st[:counts][v.to_s] += 1 }
    when "prioritise"
      # value is the ordered list, highest priority first. Bank each option's
      # 1-based rank so we can average positions later (lower mean = higher
      # priority).
      Array(value).each_with_index { |label, i| st[:counts][label.to_s] += (i + 1) }
    when "tap_card"
      if value.is_a?(Hash)
        keys = st[:response_keys] || TapScales.keys_for(nil)
        value.each do |label, dir|
          # st[:counts] has a 0 default (for the scalar types), so guard on
          # is_a?(Hash) rather than ||= when nesting per-statement tallies.
          # Seeded from the card's own scale so every response shows on the
          # results page, including the ones nobody picked.
          st[:counts][label] = keys.index_with { 0 } unless st[:counts][label].is_a?(Hash)
          st[:counts][label][dir.to_s] += 1 if st[:counts][label].key?(dir.to_s)
        end
      end
    when "range", "nps"
      return false unless scalar_answer?(value)
      st[:counts][value.to_i] += 1
    when "rating"
      return false unless scalar_answer?(value)
      st[:counts][value.to_i] += 1
      st[:sum] += value.to_f
      st[:sum_count] += 1
    when "open_ended"
      str = value.to_s
      st[:texts] << str unless str.blank?
    when "contact_form"
      # The submitted field-object, whole — the results view renders these as
      # a lead table rather than counting anything.
      st[:texts] << value if value.is_a?(Hash) && value.present?
    end
    true
  end

  # A scale answer is a number (or the string of one). Anything else at a
  # range/nps/rating index — a select_many's array, a tap card's hash — is an
  # answer recorded against a DIFFERENT card that used to sit at this position,
  # which a deck edited under the live-edit override (LiveEditAccess) can leave
  # behind. It is skipped rather than coerced: Array#to_i would 500 the whole
  # results page, and re-pointed answers are the owner's accepted cost, not a
  # reason the page can't render.
  def scalar_answer?(value)
    value.is_a?(Numeric) || value.is_a?(String)
  end

  def finalize_card(card, type, st, total_responses)
    # A held "Other" write-in still chose Other, so it is in the Other bar and
    # the total; a held open_ended value is in that card's total. `held` says
    # how many of a card's answers are not being shown, for the results page.
    other_count = st[:other_texts].size + st[:held_others]
    held        = st[:held_values] + st[:held_others]
    base = { type:, card:, other_texts: st[:other_texts], held: }

    case type
    when "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid", "scenario"
      counts = st[:counts]
      counts["Other"] = other_count if other_count.positive?
      base.merge(total: st[:value_count] + other_count, counts:)
    when "tap_card"
      base.merge(total: st[:value_count] + other_count, counts: st[:counts])
    when "prioritise"
      # counts[label] = sum of ranks; total = responders, so mean rank =
      # counts[label] / total. Lower mean = higher priority.
      base.merge(total: st[:value_count], counts: st[:counts])
    when "range", "nps"
      base.merge(total: st[:value_count] + other_count, counts: st[:counts])
    when "rating"
      avg = st[:sum_count].positive? ? (st[:sum] / st[:sum_count]).round(1) : 0.0
      base.merge(total: st[:value_count] + other_count, counts: st[:counts], avg:)
    when "open_ended"
      base.merge(total: st[:value_count] + st[:held_values] + other_count, texts: st[:texts])
    when "contact_form"
      base.merge(total: st[:value_count], entries: st[:texts])
    else
      base.merge(total: total_responses, counts: {})
    end
  end
end
