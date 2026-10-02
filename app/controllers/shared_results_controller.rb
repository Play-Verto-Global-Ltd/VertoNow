# Public, read-only view of a Verto's aggregated results — the /results/:token
# counterpart to PlayerController's /play/:token, but for handing an owner's
# results to someone who shouldn't need a Playverto account to see them (a
# funder, a partner, a board). Reuses the exact aggregation stack the owner's
# own results page uses (AggregatesSurveyResults / ResolvesResultSegments) so
# nothing about what counts as a segment, or small-cell suppression, can drift
# between the two views.
#
# PII posture (see app/views/surveys/_result_cards.html.erb, shared: true):
# closed-question distributions, the regions map, the cached AI summary and
# response counts are shown. open_ended texts, "other" free text and
# contact_form lead tables are NOT — each replaced by a count-only line. The
# leaderboard, exports, Ask Verto, and the report's edit/regenerate controls
# never render on this controller's views at all.
#
# AI spend: the report is shown read-only, and only once the owner has
# already generated and cached one (survey.results_report present) — this
# controller never calls ResultsReportGenerator. The PDF path is guarded the
# same way one layer down, in RenderReportPdfJob (render.shared_request?).
#
# No turbo_stream_from here: ResultsActivity's signed stream name is meant
# for an org-scoped page only (a public page would keep pushing counts after
# a pause) — counts are static at render time, refreshed by reloading.
class SharedResultsController < ApplicationController
  include AggregatesSurveyResults
  include ResolvesResultSegments
  include GeneratesResultsReport

  # date_range_options is a private concern method — SurveysController exposes
  # it to results.html.erb the same way for the owner's page.
  helper_method :date_range_options

  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  # create_render is the one state-changing action here, posted anonymously
  # by shared_report_download_controller.js — no session exists to carry a
  # CSRF token, same reasoning as PlayerController's submit/progress.
  protect_from_forgery with: :null_session, only: :create_render

  before_action :set_survey

  # Distinct `name:`s or the three limits share one per-IP counter (Rails
  # keys on [scope, name, ip] and name defaults to nil) — a viewer polling
  # render_status would otherwise burn the page's own 120/min budget. Same
  # bug class the k6 baseline caught in PlayerController.
  rate_limit to: 120, within: 1.minute, only: %i[ show report ], name: "reads",
             with: -> { render plain: "Too many requests — please slow down.", status: :too_many_requests }
  rate_limit to: 30, within: 1.minute, only: :render_status, name: "render_status",
             with: -> { render json: { ok: false, error: "Too many requests." }, status: :too_many_requests }
  # Every call either reuses an in-flight/recent render or spawns a
  # wkhtmltopdf job (100-200MB transient) — tighter than the owner's
  # equivalent (ReportRendersController#create) because nobody signed this
  # request.
  rate_limit to: 5, within: 1.minute, only: :create_render, name: "create_render",
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }

  # GET /results/:token
  def show
    @date_range = params[:range].presence
    # links: false — custom-link names are the owner's internal audience labels
    # (see ResolvesResultSegments#result_segments); a crafted ?segment=link_N
    # falls back to Overall like any unknown id.
    base, @segments, @active_segment = resolve_result_segments(@survey, params[:segment], @date_range, links: false)
    @overall_total = base.count
    # The Privacy Notice's promise — no result from a group of fewer than
    # Response::MIN_REGION_SAMPLE_SIZE — holds for the whole Verto here, not
    # only for segments: this page is public, and "3 responses, 2 said yes" on
    # an open link is a statement about people a reader may know. Under the
    # line, nothing derived from the answers renders: no cards, no map, no
    # cached summary, no report.
    @too_few = @overall_total < Response::MIN_REGION_SAMPLE_SIZE
    @total         = @active_segment[:count]
    @aggregated    = aggregate_results(Array(@survey.cards), @active_segment[:scope])
    # Typical time to answer per question — aggregate timing, no free text,
    # so it is shown here on the same terms as the distributions.
    @dwell         = @active_segment[:suppressed] ? {} : DwellTimes.for(Array(@survey.cards), @active_segment[:scope])

    # without_report_text (set_survey) excludes both of these columns —
    # #show only needs to know whether a report exists and show the cached
    # summary text, not repeat the report's own (possibly long) markdown, so
    # a targeted pick avoids widening every viewer's request for the sake of
    # the rare report-download click.
    report_text, @cached_summary = Survey.where(id: @survey.id).pick(:results_report, :results_summary)
    @has_report = report_text.present? && !too_few_for_report?
    @cached_summary = nil if @too_few
  end

  # GET /results/:token/report — the same self-contained document template
  # used for the PDF/Google Doc export, shown as an ordinary page. Cached
  # markdown only: this action never generates a report (see class comment).
  def report
    survey = full_survey
    return render_unavailable(:not_found) if survey.results_report.blank? || too_few_for_report?

    render html: results_report_document(survey, survey.results_report).html_safe, layout: false
  end

  # POST /results/:token/report/renders — ask for a PDF of the cached report.
  # Dedupes against an in-flight or still-fresh succeeded render for this
  # survey before spawning a new job, so repeat clicks (or two visitors
  # reading the same link) don't each queue their own wkhtmltopdf process.
  def create_render
    if full_survey.results_report.blank? || too_few_for_report?
      return render json: { ok: false, error: "This report hasn't been generated yet." }, status: :unprocessable_entity
    end

    reusable = @survey.report_renders
                      .where(status: %w[ pending running succeeded ])
                      .order(created_at: :desc)
                      .find { |r| !r.succeeded? || (r.created_at >= ReportRender::KEEP_FOR.ago && r.document.attached?) }

    render_row = reusable || @survey.report_renders.create!(user: nil)
    RenderReportPdfJob.perform_later(render_row.id) unless reusable

    render json: { ok: true, id: render_row.id,
                   poll_url: shared_results_render_path(token: @survey.results_share_token, id: render_row.id) }
  end

  # GET /results/:token/report/renders/:id
  def render_status
    render_row = @survey.report_renders.find(params[:id])
    # This instance restarts its worker at 85% RSS, and a PDF render is
    # exactly the kind of spike that trips it — surface a dead job instead of
    # letting an anonymous visitor poll it forever.
    render_row.fail!("That took longer than expected. Please try again.") if render_row.stale?

    payload = { ok: true, status: render_row.status }
    payload[:download_url] = download_shared_results_render_path(token: @survey.results_share_token, id: render_row.id) if render_row.succeeded?
    payload[:error]        = render_row.error_message if render_row.failed?
    render json: payload
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "That download expired — please try again." }, status: :not_found
  end

  # GET /results/:token/report/renders/:id/download
  def render_download
    render_row = @survey.report_renders.find(params[:id])
    return head :not_found unless render_row.succeeded? && render_row.document.attached?

    send_data render_row.document.download,
              filename:    render_row.document.filename.to_s,
              type:        "application/pdf",
              disposition: "attachment"
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  # The report is written about every answered response, whatever window the
  # page is showing, so it is held to the floor over all of them. Checked on
  # every path that can hand it out, not only on the page that links to it.
  def too_few_for_report?
    @survey.responses.where(answered: true).count < Response::MIN_REGION_SAMPLE_SIZE
  end

  # without_report_text (below) excludes results_report/results_summary — a
  # deliberate cost-saving for #show, which never needs the text itself, only
  # whether one exists. #report/#create_render need the actual markdown, so
  # they reload the full row on demand rather than widening every request.
  def full_survey
    @full_survey ||= Survey.find(@survey.id)
  end

  def set_survey
    @survey = Survey.without_report_text.find_by(results_share_token: params[:token])
    return render_unavailable(:not_found) unless @survey
    return render_unavailable(:gone) if @survey.deleted?
    # Covers "never enabled", "paused" and "revoked" alike — from the outside
    # these are indistinguishable, exactly like a paused SurveyLink on /play.
    render_unavailable(:not_found) unless @survey.results_share_live?
  end

  def render_unavailable(status)
    @oops_gone = (status == :gone)
    render :unavailable, status: status
  end
end
