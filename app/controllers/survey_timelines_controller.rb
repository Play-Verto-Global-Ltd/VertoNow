# GET /surveys/:id/results/timeline?card_index=&statement=&segment=&range=&from=&to=
# The series behind a result card's "over time" tab (answer_timeline_controller):
# every answer's count per period, within the page's segment, for the window
# the tab asks for — one of the page's own presets, or a From/To of the
# reader's. AnswerTimeline does the counting; this resolves what to count.
#
# Owner-side only, like the freeform answers panel: the public shared page
# draws no tab. Any role in the account may read it — seeing results is what a
# viewer is for.
class SurveyTimelinesController < ApplicationController
  include ResolvesResultSegments

  # A custom window can reach back as far as it likes within reason; ten years
  # is 120 monthly points, AnswerTimeline's ceiling.
  MAX_SPAN_DAYS = 3660

  # One batched read of the answers column, but reachable from every click on
  # a row, so a plain abuse cap.
  rate_limit to: 120, within: 1.minute,
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }

  def show
    survey = Current.organisation.surveys.without_report_text.find(params[:id])
    idx    = params[:card_index].to_i
    # Never a card from the end of the deck: a negative index would pass the
    # type check and then count answers under a key no response has.
    card   = idx.negative? ? nil : Array(survey.cards)[idx]

    unless AnswerTimeline.countable?(card)
      return render json: { ok: false, error: "Not a question with counted answers." }, status: :unprocessable_entity
    end

    statement = params[:statement].presence
    if card["type"].to_s == "tap_card" && statement.blank?
      return render json: { ok: false, error: "Which statement?" }, status: :unprocessable_entity
    end

    custom = custom_window
    if (params[:from].present? || params[:to].present?) && custom.nil?
      return render json: { ok: false, error: "That date range doesn't make sense." }, status: :unprocessable_entity
    end

    # The same resolver the page used to draw the pills, so "this segment" is
    # exactly the one the card was counted in — a combination included, and a
    # combination under the small-cell line comes back as no rows at all. The
    # preset narrows the base the way the page's own window does; a custom
    # From/To narrows it the same way.
    range  = custom ? nil : params[:range].presence
    _base, _segments, segment = resolve_result_segments(survey, params[:segment], range, window: custom)
    scope  = segment[:scope]

    to   = custom ? custom.end : Date.current
    from = if custom then custom.begin
    elsif (preset = DATE_RANGES[range.to_s]) then preset.last.days.ago.to_date
    else scope.reorder(nil).minimum(:created_at)&.to_date || to
    end

    timeline = AnswerTimeline.new(card: card, index: idx, scope: scope, from: from, to: to, statement: statement).call

    render json: {
      ok:          true,
      question:    card["text"].to_s,
      statement:   statement,
      from:        from.iso8601,
      to:          to.iso8601,
      granularity: timeline.granularity,
      min_answers: AnswerTimeline::MIN_PERIOD_ANSWERS,
      series:      timeline.series,
      periods:     timeline.periods
    }
  end

  private

  # from..to as Dates, or nil when the pair is absent, unparseable, inverted
  # or absurdly long. Both halves are needed: half a window is no window.
  def custom_window
    from = parse_date(params[:from])
    to   = parse_date(params[:to])
    return nil unless from && to && from <= to && (to - from) <= MAX_SPAN_DAYS

    from..to
  end

  def parse_date(value)
    Date.iso8601(value.to_s) if value.present?
  rescue Date::Error
    nil
  end
end
