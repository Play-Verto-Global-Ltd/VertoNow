# One respondent's answers paired with the per-card aggregate, a card at a time:
# what the account page (/you/v/:id) draws under "your answers next to
# everyone's".
#
# It is the server-side twin of player_controller.js's _buildRow, _formatMine,
# _buildDistribution and _isMineMatch, and the rules are the player's on
# purpose — a respondent should recognise the screen they saw when they
# finished. The reason it is a table of types rather than one loop is that the
# aggregator (AggregatesSurveyResults#accumulate_value) does not store every
# card the same way:
#
#   choice cards      label        => number who chose it
#   rating            1..N         => tally, keyed by the integer
#   range, nps        step index   => tally (0-based; the words are `options`)
#   prioritise        label        => SUM of ranks, not a tally — lower is higher
#   tap_card          statement    => { response key => tally }
#
# Reading all of them as a flat label => count map is what drew 0% bars for a
# scale, 100/200/300% for a ranking, and raised on a swipe card (Hash#to_i) for
# anyone who had answered one.
#
# A row is { prompt:, mine:, bars: [{ label:, pct:, mine:, text:, heading: }] }.
# `bars` is empty where a distribution would mean something else — a written
# answer has no bars to draw. `text` replaces "NN%" in a bar's figure, for the
# one type (a ranking) whose figure is not a share; `heading` starts a group of
# bars (a swipe card's statement) with a line of its own.
module ResultsComparison
  module_function

  CHOICE = %w[multiple_choice yes_no select_one_grid select_many select_many_grid scenario].freeze

  # Never drawn. A contact form's value is the respondent's own details (and
  # nobody else's belong on this page); the token rows are not keyed to an
  # answer, and the wallet already says what someone collected.
  SKIPPED = (CardTypes::NON_QUESTION_TYPES + %w[contact_form token_total]).freeze

  def rows(results, answers)
    answers = answers.to_h
    Array(results).filter_map { |row| row_for(row, answers) }
  end

  def row_for(row, answers)
    type = row[:type].to_s
    return if SKIPPED.include?(type)

    mine = answers[row[:index].to_s]
    mine = mine["value"] if mine.is_a?(Hash)
    return if mine.nil? || mine == "" || mine == false || (mine.respond_to?(:empty?) && mine.empty?)
    # A Hash is a swipe card's answer and nothing else's. Anything else carrying
    # one is an answer recorded against a different card that used to sit here
    # (LiveEditAccess), which has no honest rendering.
    return if mine.is_a?(Hash) && type != "tap_card"

    { prompt: row[:prompt], mine: format_mine(type, row, mine), bars: bars_for(type, row, mine) }
  end

  # ── What they said ────────────────────────────────────────────────────────

  def format_mine(type, row, mine)
    case type
    when "prioritise" then Array(mine).join(" › ")
    when "rating"     then "#{mine} ★"
    when "range", "nps"
      options = row[:options]
      step    = Integer(mine.to_s, exception: false)
      (options.is_a?(Array) && step && options[step]) || mine.to_s
    when "tap_card"
      scale = scale_for(row)
      mine.map { |statement, key| "#{statement}: #{scale[key.to_s] || key}" }.join(", ")
    when "open_ended"
      row[:input] == "location" ? location_label(mine) : Array(mine).join(", ")
    else
      Array(mine).join(", ")
    end
  end

  # A location answer is stored as "CC|Label" (and a stale client may append a
  # third segment, which PlayerController#sync_region_from_answers! discards
  # the same way). Said as the place, not the packing.
  def location_label(value)
    country, label = value.to_s.split("|", 3)
    label.to_s.strip.presence || WorldRegions.name_for(country).presence || value.to_s
  end

  # ── What everyone said ────────────────────────────────────────────────────

  def bars_for(type, row, mine)
    return [] unless row[:counts].respond_to?(:to_h)

    case type
    when *CHOICE      then choice_bars(row, mine)
    when "rating"     then rating_bars(row, mine)
    when "range", "nps" then step_bars(row, mine)
    when "prioritise" then ranking_bars(row)
    when "tap_card"   then swipe_bars(row, mine)
    else []
    end
  end

  # Their option marked, in the card's own order. Cards that store no `options`
  # (a yes/no seeded without any) fall back to what was answered, most chosen
  # first, as the player draws them. Share of RESPONDERS, so a select-many's
  # bars can each be high at once.
  def choice_bars(row, mine)
    counts  = row[:counts].to_h.transform_keys(&:to_s)
    total   = row[:total].to_i
    options = Array(row[:options]).map(&:to_s)
    labels  = options.any? ? options : counts.keys.sort_by { |l| [ -counts[l].to_i, l ] }
    return [] unless total.positive?

    picked = Array(mine).map(&:to_s)
    labels.map do |label|
      { label: label, pct: percent(counts[label].to_i, total), mine: picked.include?(label) }
    end
  end

  # 1..N stars, N at least 5 — whatever the card's `options` say, which are
  # captions for the ends rather than the number of points.
  def rating_bars(row, mine)
    counts = tally(row[:counts])
    top    = [ 5, counts.keys.max.to_i ].max
    grand  = counts.values.sum
    own    = Integer(mine.to_s, exception: false)

    (1..top).map do |i|
      { label: "#{i} ★", pct: percent(counts[i].to_i, grand), mine: own == i }
    end
  end

  # One bar per step the card names, by position: the tallies are keyed by the
  # step's 0-based index and the words are only ever labels. With no words
  # there is nothing to name a bar by, and none is invented.
  def step_bars(row, mine)
    options = row[:options]
    return [] unless options.is_a?(Array) && options.any?

    counts = tally(row[:counts])
    grand  = counts.values.sum
    own    = Integer(mine.to_s, exception: false)

    options.each_with_index.map do |label, i|
      { label: label.to_s, pct: percent(counts[i].to_i, grand), mine: own == i }
    end
  end

  # counts[label] is a SUM of ranks over the people who ranked, so the mean
  # position is sum / total (lower is higher). Ordered by it, bar length is how
  # near the top the group put it, and the figure is the mean itself — the same
  # reading the player gives. Nothing is marked as theirs: their answer is the
  # whole list, so every option would qualify.
  def ranking_bars(row)
    total = row[:total].to_i
    return [] unless total.positive?

    ranked = row[:counts].to_h.map { |label, sum| [ label.to_s, sum.to_f / total ] }
                         .sort_by { |label, mean| [ mean, label ] }
    n = ranked.size

    ranked.each_with_index.map do |(label, mean), i|
      share = ((n - mean + 1) / n).clamp(0.0, 1.0)
      { label: "#{i + 1}. #{label}", pct: (share * 100).round, mine: false,
        text: I18n.t("you.avg_position", n: format("%.1f", mean)) }
    end
  end

  # A bar per response on the card's own scale, per statement — so the figures
  # are each statement's share of its own answers, not of the whole card. The
  # statement is a `heading` on its first bar and the label is only the answer:
  # "statement — answer" in one label truncates before the answer, and three
  # bars that all read "Renting is always wa…" say nothing.
  def swipe_bars(row, mine)
    scale  = scale_for(row)
    counts = row[:counts].to_h
    statements = Array(row[:options]).map(&:to_s)
    statements |= counts.keys.map(&:to_s)
    given = mine.is_a?(Hash) ? mine.transform_keys(&:to_s) : {}

    statements.flat_map do |statement|
      tallies = counts[statement].is_a?(Hash) ? counts[statement] : {}
      grand   = scale.keys.sum { |key| tallies[key].to_i }
      scale.each_with_index.map do |(key, caption), i|
        { label: caption, pct: percent(tallies[key].to_i, grand),
          mine: given[statement].to_s == key, heading: (statement if i.zero?) }.compact
      end
    end
  end

  # key => caption, in the card's order. The payload carries the scale for every
  # swipe card; the historic yes/unsure/no is what a payload without one means.
  def scale_for(row)
    entries = Array(row[:responses]).presence || TapScales.for_card(nil).map { |r| r.slice("key", "label") }
    entries.to_h { |r| [ r["key"].to_s, r["label"].to_s ] }
  end

  # Integer-keyed tallies as stored, tolerating the string keys a JSON
  # round-trip would turn them into.
  def tally(counts)
    counts.to_h.each_with_object(Hash.new(0)) do |(key, n), out|
      step = Integer(key.to_s, exception: false)
      out[step] += n.to_i if step
    end
  end

  def percent(count, of)
    of.positive? ? (count * 100.0 / of).round : 0
  end
end
