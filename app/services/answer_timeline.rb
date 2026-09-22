# The series behind a result card's "over time" tab: one closed question's
# answer counts, bucketed by when each response arrived, for every answer the
# card draws a row for. Counted by the aggregator's own rules
# (AggregatesSurveyResults#accumulate_value / #finalize_card, one state per
# period), so a period's numbers are exactly what the card would show for that
# period on its own — the same denominators, the same "Other" row, the same
# scale seeded with the answers nobody picked.
#
# What comes back is counts, not shares: the tab divides on the client, where
# the reader can switch between the two without another request.
class AnswerTimeline
  include AggregatesSurveyResults

  # The card types whose rows are answers with a count. open_ended and
  # contact_form have no rows; prioritise's rows are average ranks, which is a
  # different measure and not this tab's.
  COUNTABLE = %w[multiple_choice yes_no select_one_grid select_many select_many_grid scenario
                 range nps rating tap_card].freeze

  # The segments' small-cell line, applied per period: a period with fewer
  # answers than this has its counts withheld — not dimmed, withheld — because
  # "2 of 3 picked X" in one named week is the disclosure the rest of the page
  # refuses to make.
  MIN_PERIOD_ANSWERS = Response::MIN_REGION_SAMPLE_SIZE

  # Buckets by the window's span: days up to a month, weeks up to about half a
  # year, months beyond — enough points to see a shape, few enough to read.
  DAY_SPAN_MAX  = 31
  WEEK_SPAN_MAX = 200
  # A ten-year window is 120 months; nothing asks for more points than that.
  MAX_PERIODS   = 120

  Result = Struct.new(:granularity, :series, :periods, keyword_init: true)

  def self.countable?(card)
    card.is_a?(Hash) && COUNTABLE.include?(card["type"].to_s)
  end

  # card:      the card Hash, at `index` in the deck
  # scope:     the responses to count (the page's segment, already narrowed to
  #            the window by the caller — the dates here only pick the buckets)
  # from, to:  Dates, inclusive
  # statement: a tap card's statement, whose scale is the answer set
  def initialize(card:, index:, scope:, from:, to:, statement: nil)
    @card      = card
    @type      = card["type"].to_s
    @index     = index
    @scope     = scope
    @from      = from
    @to        = to
    @statement = statement
  end

  def call
    granularity = granularity_for(@from, @to)
    starts      = period_starts(granularity)
    states      = Hash.new { |h, k| h[k] = new_card_state(@type, @card) }
    key         = @index.to_s

    each_response(@scope) do |answers, created_at|
      a = answers[key]
      next unless a.is_a?(Hash)

      date = created_at.to_date
      next if date < @from || date > @to

      st    = states[bucket(date, granularity)]
      value = a["value"]
      st[:value_count] += 1 if !(value.nil? || value == false) && accumulate_value(st, @type, value)
      other = a["other"]
      st[:other_texts] << other if other.respond_to?(:presence) && other.presence
      held = a["held"]
      if held.is_a?(Hash)
        st[:held_values] += 1 if held["value"]
        st[:held_others] += 1 if held["other"]
      end
    end

    finalized = starts.index_with { |d| states.key?(d) ? finalize_card(@card, @type, states[d], 0) : nil }
    series    = series_for(finalized.values.compact)
    periods   = starts.map do |d|
      result = finalized[d]
      counts = result ? counts_for(result, series) : series.map { 0 }
      thin   = (result ? result[:total].to_i : 0) < MIN_PERIOD_ANSWERS
      {
        start:  d.iso8601,
        label:  label_for(d, granularity),
        thin:   thin,
        n:      thin ? nil : counts.sum,
        counts: thin ? nil : counts
      }
    end

    Result.new(granularity: granularity.to_s, series: series, periods: periods)
  end

  private

  def granularity_for(from, to)
    span = (to - from).to_i + 1
    if span <= DAY_SPAN_MAX then :day
    elsif span <= WEEK_SPAN_MAX then :week
    else :month
    end
  end

  def bucket(date, granularity)
    case granularity
    when :day   then date
    when :week  then date.beginning_of_week
    when :month then date.beginning_of_month
    end
  end

  def period_starts(granularity)
    starts = []
    d      = bucket(@from, granularity)
    last   = bucket(@to, granularity)
    while d <= last
      starts << d
      d = case granularity
      when :day   then d + 1
      when :week  then d + 7
      when :month then d.next_month
      end
    end
    starts.last(MAX_PERIODS)
  end

  def label_for(date, granularity)
    granularity == :month ? date.strftime("%b %Y") : date.strftime("%-d %b")
  end

  # The rows the card draws, in the order it draws them, as { key:, label: }.
  # key is what a row on the page carries to open the tab on itself, and what
  # counts_for reads each period's tally by.
  def series_for(results)
    case @type
    when "range", "nps"
      labels = Array(@card["options"]).presence || (@type == "nps" ? (0..10).map(&:to_s) : [])
      [ labels.size, 2 ].max.times.map { |i| { key: i.to_s, label: labels[i] || "Step #{i + 1}" } }
    when "rating"
      5.downto(1).map { |star| { key: star.to_s, label: "★" * star } }
    when "tap_card"
      TapScales.for_card(@card).map { |r| { key: r["key"].to_s, label: r["label"].to_s } }
    else
      # The card sorts its rows by count over the whole window; so does the
      # tab's legend, and a row that only ever appears in one period ("Other",
      # once) still gets a line.
      totals = Hash.new(0)
      results.each { |r| r[:counts].each { |label, n| totals[label.to_s] += n.to_i } }
      totals.sort_by { |label, n| [ -n, label ] }.map { |label, _| { key: label, label: label } }
    end
  end

  def counts_for(result, series)
    counts = result[:counts]
    case @type
    when "range", "nps", "rating"
      series.map { |s| counts[s[:key].to_i].to_i }
    when "tap_card"
      tallies = counts[@statement]
      tallies = {} unless tallies.is_a?(Hash)
      series.map { |s| tallies[s[:key]].to_i }
    else
      series.map { |s| counts[s[:key]].to_i }
    end
  end
end
