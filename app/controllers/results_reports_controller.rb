# The downloadable AI results report. JSON returns the rendered report body for
# the on-page preview; PDF streams the report as a file (wicked_pdf). Both reuse
# the generate-and-cache helper in GeneratesResultsReport. PATCH saves the
# creator's hand-edited markdown over the cached AI text.
class ResultsReportsController < ApplicationController
  include GeneratesResultsReport

  # Reading the report (and having one generated) is seeing results, which
  # every role does. Rewriting its text by hand is editing, which a viewer
  # doesn't — the results page draws no Edit button for them, and this is the
  # half that holds when the button isn't there.
  gate_verto_editing only: %i[ update ]

  # Persist an edited report. Syncing results_report_response_count to the
  # CURRENT completed count is what keeps the edit alive: the count-keyed cache
  # only regenerates (overwriting the edit) once responses genuinely change
  # again — not on the next page view because the count had already drifted
  # between generation and the edit.
  def update
    survey   = Current.organisation.surveys.find(params[:survey_id])
    markdown = params[:markdown].to_s
    if markdown.strip.blank?
      return render json: { ok: false, error: "The report can't be empty." }, status: :unprocessable_entity
    end

    total = survey.integrity_filtered(survey.responses.where(status: "completed")).count
    survey.update_columns(
      results_report:                markdown,
      results_report_response_count: total,
      results_report_edited_at:      Time.current,
      updated_at:                    Time.current
    )
    render json: { ok: true, body_html: results_report_body_html(markdown) }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Verto not found." }, status: :not_found
  end

  def show
    survey   = Current.organisation.surveys.find(params[:survey_id])
    markdown = results_report_markdown(survey)

    # PDF lives on ReportRendersController now: the wkhtmltopdf render spawns a
    # native process using 100-200MB transiently, which is no longer allowed to
    # happen on a request thread. Leaving a synchronous route to it would defeat
    # the point of moving it.
    render json: { ok: true, body_html: results_report_body_html(markdown) }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Verto not found." }, status: :not_found
  rescue ReportBusy
    render json: { ok: false, error: LimitsConcurrentStreams::BUSY_MESSAGE }, status: :service_unavailable
  rescue => e
    ErrorReporting.report("ResultsReportsController", e)
    render json: { ok: false, error: "Couldn't generate the report — please try again." }, status: :unprocessable_entity
  end
end
