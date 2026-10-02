require "csv"

# GET /surveys/:survey_id/results/export?kind=responses|summary&segment=…
# Streams the Verto's results as a CSV download. `kind` picks the raw-responses
# table or the aggregated summary; `segment` matches the on-screen filter.
class ResultsExportsController < ApplicationController
  include PreparesResultsExport

  def show
    survey          = export_survey
    export, _active = build_results_export(survey, params[:segment])

    summary = params[:kind].to_s == "summary"
    label   = summary ? "summary" : "responses"
    # A file is passed on without the page that made it, so its name says
    # when Low responses were left out of it.
    label   = "#{label}-excluding-low" if survey.excluding_low_integrity?

    if params[:format].to_s == "xlsx"
      send_xlsx(export, survey, label, summary)
    else
      send_csv(export, survey, label, summary)
    end
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    ErrorReporting.report("ResultsExportsController", e)
    redirect_to survey_results_path(params[:survey_id]), alert: t("flash.results_exports.export_failed", reason: e.message)
  end

  private

  def send_csv(export, survey, label, summary)
    filename = "verto-#{survey.id}-#{label}-#{Date.current.iso8601}.csv"

    response.headers["Content-Type"]        = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: filename)
    response.headers["X-Accel-Buffering"]   = "no"

    # Stream the CSV row-by-row so the generated CSV string is never held in
    # memory. Raw-response rows are buffered once inside export.each_row to be
    # grouped by responder — the same footprint the XLSX/Sheets paths already
    # have. Lead with a UTF-8 BOM for Excel.
    self.response_body = Enumerator.new do |out|
      out << "﻿"
      export.each_row(summary: summary) { |row| out << CSV.generate_line(row) }
    end
  end

  # Unlike the CSV path this can't stream — Axlsx builds the whole workbook in
  # memory before it can be serialised (see ResultsExportXlsx). Fine at survey
  # scale; keep CSV as the streaming path if that ever stops being true.
  def send_xlsx(export, survey, label, summary)
    filename = "verto-#{survey.id}-#{label}-#{Date.current.iso8601}.xlsx"
    send_data ResultsExportXlsx.new(export, summary: summary).to_stream,
      filename: filename,
      type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      disposition: "attachment"
  end
end
