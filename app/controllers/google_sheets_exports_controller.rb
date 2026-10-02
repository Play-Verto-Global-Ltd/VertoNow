# POST /surveys/:survey_id/results/google_sheet?segment=…
# Creates a Google Sheet in the current user's Drive from the Verto's results
# and returns its URL as JSON (the front-end opens it in a new tab). When the
# user isn't connected (or their token was revoked) it returns reconnect:true
# with the connect URL.
class GoogleSheetsExportsController < ApplicationController
  include PreparesResultsExport

  def create
    survey = export_survey

    unless GoogleOauthService.configured?
      return render json: { ok: false, error: "Google Sheets isn't configured." }, status: :service_unavailable
    end
    return render_reconnect(survey) unless Current.user.google_connected?

    export, active = build_results_export(survey, params[:segment])
    result = GoogleSheetsWriter.call(
      user:          Current.user,
      title:         sheet_title(survey, active),
      response_rows: export.response_rows,
      summary_rows:  export.summary_rows
    )

    render json: { ok: true, url: result.url }
  rescue GoogleOauthService::NotConnected
    Current.user.disconnect_google!
    render_reconnect(survey)
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Verto not found." }, status: :not_found
  rescue => e
    ErrorReporting.report("GoogleSheetsExportsController", e)
    render json: { ok: false, error: "Couldn't create the Google Sheet — please try again." }, status: :unprocessable_entity
  end

  private

  def render_reconnect(survey)
    render json: {
      ok: false, reconnect: true,
      connect_url: google_connect_path(survey_id: survey&.id || params[:survey_id], segment: params[:segment])
    }, status: :unprocessable_entity
  end

  def sheet_title(survey, active)
    base = survey.theme.presence || survey.title.presence || "Verto"
    seg  = active && active[:id] != "overall" ? " (#{active[:label]})" : ""
    # As the download's filename does: a sheet outlives the page that made it.
    low  = survey.excluding_low_integrity? ? " — excluding Low integrity" : ""
    "#{base} — Verto results#{seg}#{low}"
  end
end
