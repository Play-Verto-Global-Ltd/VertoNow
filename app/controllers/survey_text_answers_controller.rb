# Every answer to one freeform (open_ended) question, for the results page's
# "View all answers" panel. The result card itself only previews the first
# few; this pages through all of them, newest first, within the same segment
# and date range the page is showing, optionally narrowed by a search.
#
# Owner-side only. The public shared-results page never links here — its
# freeform cards are count-only (see _result_cards' `shared`) because free
# text is where respondents put their names — and the route lives under the
# signed-in results namespace, scoped to the current organisation like every
# other results path. Any role in the account may read it: seeing results is
# what a viewer is for.
class SurveyTextAnswersController < ApplicationController
  include AggregatesSurveyResults
  include ResolvesResultSegments

  PER_PAGE = 100

  # Cheap (one batched read of the answers column) but reachable from a
  # keystroke-debounced search box, so a plain abuse cap, not an AI throttle.
  rate_limit to: 120, within: 1.minute,
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }

  # GET /surveys/:id/results/answers?card_index=&kind=&segment=&range=&q=&page=
  def index
    survey = Current.organisation.surveys.without_report_text.find(params[:id])
    idx    = params[:card_index].to_i
    # A negative index would read a card from the END of the deck, and then
    # look every answer up under a key ("-1") no response has.
    card   = idx.negative? ? nil : Array(survey.cards)[idx]

    # Two things a card collects as free text: its answer, when it is a
    # freeform question, and the "Other" a closed question lets a respondent
    # write in instead of picking one of its options. The same panel serves
    # both — paged, newest first, searched on the server — and kind=other
    # reads the second. Any card can carry write-ins, so that kind takes any
    # card that exists.
    #
    # The demographic tail (birth month, location) is open_ended too, and is
    # served here like any other freeform card. It used to be refused on the
    # grounds that its values are structured picks rather than answers anyone
    # reads one by one — but a creator looking at 292 birth months wants to
    # page and search them exactly as they would any other column, and
    # DemographicQuestions.display_answer now renders them as words.
    other = params[:kind].to_s == "other"
    unless card.is_a?(Hash) && (other || card["type"] == "open_ended")
      return render json: { ok: false, error: "Not a freeform question." }, status: :unprocessable_entity
    end

    # The same resolver the page used to draw the pills, so "this segment"
    # here is exactly the segment the card was counted in. It builds every
    # segment's count to find one — the cost every results endpoint pays.
    _base, _segments, segment = resolve_result_segments(survey, params[:segment], params[:range].presence)
    query = params[:q].to_s.strip.downcase
    page  = [ params[:page].to_i, 1 ].max

    answers = collect_answers(segment[:scope], idx, card, other: other)
    matched = query.blank? ? answers : answers.select { |a| a[:text].downcase.include?(query) }
    slice   = matched[(page - 1) * PER_PAGE, PER_PAGE] || []

    render json: {
      ok:       true,
      question: card["text"].to_s,
      total:    answers.size,
      matched:  matched.size,
      page:     page,
      per_page: PER_PAGE,
      has_more: page * PER_PAGE < matched.size,
      # Formatted for the page that goes out, not for every row collected.
      answers:  slice.map { |a| { text: a[:text], at: a[:at].iso8601 } }
    }
  end

  private

  # Every non-blank answer at this card's index, newest first. Walks the
  # rows through the aggregator's own batched reader and accepts a value on
  # the aggregator's own terms (nil and false are not answers; anything else
  # is its text), so the card's "View all answers (N)" and this panel's "of N"
  # are counting the same thing. The batch walker orders by id, so the list
  # is sorted by arrival afterwards rather than trusting ids to follow it —
  # an import writes its rows in file order, not in time order.
  # Formatted HERE rather than on the way out, so the search filters the words
  # the panel actually shows: a demographic location is stored "ES|Catalunya",
  # and a creator typing "Spain" into a box listing "Catalunya, Spain" and
  # getting nothing back would be right to call that broken. Every other
  # card's text comes through display_answer unchanged.
  def collect_answers(scope, idx, card, other: false)
    key = idx.to_s
    out = []
    each_response(scope) do |answers, created_at|
      a = answers[key]
      next unless a.is_a?(Hash)

      text = other ? other_text(a) : answer_text(a, card)
      next if text.blank?

      out << { text: text, at: created_at }
    end
    out.sort_by! { |a| -a[:at].to_f }
  end

  def answer_text(a, card)
    value = a["value"]
    return nil if value.nil? || value == false

    DemographicQuestions.display_answer(card, value.to_s.strip).strip
  end

  # A write-in on the aggregator's own terms too (aggregate_results keeps a
  # present string and nothing else), so the section's "N free-text" and this
  # panel's "of N" count the same thing.
  def other_text(a)
    other = a["other"]
    other.respond_to?(:presence) ? other.presence&.strip : nil
  end
end
