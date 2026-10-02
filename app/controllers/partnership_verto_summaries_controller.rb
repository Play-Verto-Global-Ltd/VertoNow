# GET /partnerships/:partnership_id/partnership_vertos/:partnership_verto_id/summary?segment=&range=
#
# The AI summary on a partner's results page: what the partner's own
# respondents said, and where they differ from everyone else who answered —
# for exactly the slice the page is showing (ComparesPartnerResults), so the
# prose is never about numbers that are not on the screen. Streamed, like the
# owner's summary (SurveySummariesController#show), into the same card.
#
# Everyone else goes to the model as figures only (ResultsSummariser
# #call_for_partner, results_digest texts: false): the partner may read their
# numbers on this page, never their words, and a summary that quoted them
# would hand over what the page withholds.
#
# Cached per link, slice and count, so a revisit costs nothing until somebody
# else answers; a slice under the small-cell line is never sent at all.
class PartnershipVertoSummariesController < ApplicationController
  include ActionController::Live
  include AggregatesSurveyResults
  include ComparesPartnerResults
  include LimitsConcurrentStreams
  include ThrottlesAiSpend

  limit_concurrent_streams only: :show
  # The owner's summary's own limit: most requests replay the cache, so this
  # only bounds the cold case.
  throttle_ai to: 30, within: 1.hour, name: "ai-partner-summary", respond: :plain, only: :show

  # A 404, not the page's redirect: this is fetched into a card, and a
  # followed redirect would paint a whole HTML page into it as text.
  before_action { head :not_found unless (@partnership = visible_partnership) }

  # Bumped when the prompt or the digest it reads changes, so a cached
  # summary written by an older one is regenerated rather than replayed.
  CACHE_VERSION = 1

  def show
    return head(:not_found) unless load_partner_share(params[:partnership_verto_id])

    mine, others = resolve_partner_comparison(params[:segment], params[:range])

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    if @active_segment[:suppressed]
      response.stream.write(t("results.combination_suppressed_title"))
      return
    end

    key = [ "partner-summary", CACHE_VERSION, @share.id, @active_segment[:id], @date_range || "all",
            @mine_total, others ? @others_total : 0 ]
    if (cached = Rails.cache.read(key))
      response.stream.write(cached)
      return
    end

    cards     = Array(@survey.cards)
    full_text = +""
    ResultsSummariser.new.call_for_partner(
      survey: @survey, aggregated: aggregate_results(cards, mine), total: @mine_total,
      baseline: (aggregate_results(cards, others) if others), baseline_total: @others_total
    ) do |chunk|
      response.stream.write(chunk)
      full_text << chunk
    end

    Rails.cache.write(key, full_text, expires_in: 30.days) if full_text.present?
  rescue ActiveRecord::RecordNotFound
    raise # a clean 404 before any stream is opened
  rescue => e
    ErrorReporting.report("PartnershipVertoSummariesController", e)
    response.stream.write("Insights unavailable.") rescue nil
  ensure
    response.stream.close if response.committed?
  end
end
