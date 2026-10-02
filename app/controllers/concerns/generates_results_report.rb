# Shared report plumbing for the PDF download (ResultsReportsController) and the
# Google Doc export (GoogleDriveExportsController): generate + cache the report
# markdown, and render it as a body fragment (for the on-page preview) or a full
# styled HTML document (for the PDF and the Google Doc).
module GeneratesResultsReport
  extend ActiveSupport::Concern
  include AggregatesSurveyResults

  private

  # Raised when a cold-cache generation can't get a slot. The caller turns it
  # into a "try again in a moment", which is what the streaming endpoints already
  # say in the same situation.
  class ReportBusy < StandardError; end

  # The report markdown for `survey`, generating + caching it when missing or
  # stale (cache is keyed to the completed-response count, like the summary).
  def results_report_markdown(survey)
    responses = survey.integrity_filtered(survey.responses.where(status: "completed"))
    total     = responses.count

    if survey.results_report.present? && survey.results_report_response_count == total
      return survey.results_report
    end

    # A cold cache means a full ResultsReportGenerator call — Claude, on a Puma
    # request thread, in an action that (unlike the streaming report) had no
    # bound at all. It shares the streaming pool, because it's the same scarce
    # resource: this process's threads.
    #
    # Deliberately only on THIS branch. Bulkheading the whole action would make a
    # warm cache — a single column read, and the overwhelmingly common case —
    # queue behind someone else's generation, trading a rare outage for a
    # frequent 503.
    raise ReportBusy unless LimitsConcurrentStreams::POOL.acquire

    begin
      aggregated = aggregate_results(Array(survey.cards), responses.order(created_at: :desc))
      markdown   = ResultsReportGenerator.call(survey: survey, aggregated: aggregated, total: total,
                                               brief: survey.results_report_brief_data)
      if markdown.present?
        survey.update_columns(results_report: markdown, results_report_response_count: total,
                              results_report_edited_at: nil)
      end
      markdown
    ensure
      LimitsConcurrentStreams::POOL.release
    end
  end

  # Streams the report markdown chunk-by-chunk (yielding to the block) while
  # generating, caching the full text on completion. Replays the cache in one
  # write when it's still fresh. Mirrors the insights-summary streaming.
  # `force: true` (the modal's explicit Generate click) skips the cache;
  # `brief` is the creator's goal/audience/length answers, persisted so later
  # regenerations — forced or count-triggered — reuse them.
  def stream_results_report(survey, brief: nil, force: false)
    responses = survey.integrity_filtered(survey.responses.where(status: "completed"))
    total     = responses.count

    if !force && survey.results_report.present? && survey.results_report_response_count == total
      yield survey.results_report
      return
    end

    survey.update_columns(results_report_brief: brief.to_json) if brief.present?

    aggregated = aggregate_results(Array(survey.cards), responses.order(created_at: :desc))
    full       = +""
    ResultsReportGenerator.call(survey: survey, aggregated: aggregated, total: total,
                                brief: survey.results_report_brief_data) do |chunk|
      full << chunk
      yield chunk
    end
    if full.present?
      survey.update_columns(results_report: full, results_report_response_count: total,
                            results_report_edited_at: nil)
    end
  end

  # Just the report body (Markdown → HTML) for the on-page preview, which styles
  # it for the dark results theme.
  def results_report_body_html(markdown)
    # kramdown's default parser covers the report's Markdown (## / ### headings,
    # bullet lists, bold) — no GFM-only features are used. The markdown is
    # model-generated and can fold in respondent free-text, so we sanitize the
    # rendered HTML rather than trusting it as raw (the sanitizer keeps the
    # report's formatting tags and drops scripts / event handlers).
    html = Kramdown::Document.new(markdown.to_s).to_html
    ActionController::Base.helpers.sanitize(html)
  end

  # A self-contained, light-themed HTML document — used for both the PDF
  # (wicked_pdf) and the Google Doc (Drive converts HTML → a Doc).
  # `charts: false` for the Google Doc export: Drive converts the HTML into a
  # Doc, and div-width bars don't survive that conversion — it gets the same
  # figures as tables instead, which do.
  def results_report_document(survey, markdown, charts: true)
    render_to_string(
      template: "results_reports/document",
      formats:  [ :html ],
      layout:   false,
      locals:   {
        survey:       survey,
        body_html:    results_report_body_html(markdown),
        generated_at: Time.current,
        charts:       charts,
        aggregated:   report_figures_for(survey)
      }
    )
  end

  # The per-question tallies the report's figures draw. Completed responses
  # only, matching the set the narrative was generated from — a report whose
  # charts and prose counted different people would be worse than no charts.
  def report_figures_for(survey)
    aggregate_results(
      Array(survey.cards),
      survey.integrity_filtered(survey.responses.where(status: "completed")).order(created_at: :desc)
    )
  end

  def results_report_filename(survey, ext)
    base = (survey.theme.presence || survey.title.presence || "verto").parameterize.presence || "verto"
    "#{base}-report.#{ext}"
  end

  # Serialize wkhtmltopdf renders process-wide. Each call spawns a wkhtmltopdf
  # native process that transiently uses ~100-200MB; two running at once can
  # OOM the 512MB instance (and 502 the whole app). Downloading a report is
  # rare and takes only a few seconds, so we serialize (a concurrent request
  # waits) rather than reject — the UX is unchanged and peak memory is capped
  # at a single render. The cached markdown means the expensive AI step never
  # runs inside this lock.
  PDF_RENDER_LOCK = Mutex.new

  def render_report_pdf(html, **opts)
    PDF_RENDER_LOCK.synchronize do
      WickedPdf.new.pdf_from_string(html, **opts)
    end
  end

  # The share card (RenderInfographicJob): a fixed square page rather than a
  # flowing multi-page document, so it reads as one shareable image even
  # though it's still a PDF under the hood.
  #
  # This was meant to be a PNG — imgkit + wkhtmltoimage-binary, the sibling of
  # the wicked_pdf/wkhtmltopdf-binary pair above — but wkhtmltoimage-binary's
  # newest release (0.12.5, older than wkhtmltopdf-binary's own 0.12.6.10 and
  # not maintained further) bundles a binary that fails to start on a modern
  # Linux base image: `libpng12.so.0: cannot open shared object file` —
  # libpng12 was dropped from distro repositories years ago in favour of
  # libpng16. Confirmed directly (IMGKit::CommandFailedError) rather than
  # assumed; there's no newer gem release to try. Shipping the same template
  # through the ALREADY-PROVEN wkhtmltopdf path — same lock, same binary
  # that's rendering the full report right now — beats gambling a new,
  # unmaintained native dependency onto the deploy image untested. A real PNG
  # remains possible later via ruby-vips (once it's part of the deploy image
  # the tests can run against) or a hosted rasterizer; see the roadmap.
  def render_infographic_pdf(html)
    render_report_pdf(html, page_width: "148mm", page_height: "148mm",
                            margin: { top: 0, bottom: 0, left: 0, right: 0 })
  end
end
