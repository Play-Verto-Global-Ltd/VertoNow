# Shared by the CSV + Google Sheets export controllers: finds the org-scoped
# Verto and builds a ResultsExport for the requested segment, exactly mirroring
# how SurveysController#results scopes and aggregates responses.
module PreparesResultsExport
  extend ActiveSupport::Concern

  include AggregatesSurveyResults
  include ResolvesResultSegments

  private

  # Org-scoped; includes archived Vertos like the results screen does.
  def export_survey
    Current.organisation.surveys.find(params[:survey_id])
  end

  # Returns [ResultsExport, active_segment].
  def build_results_export(survey, segment_param)
    _base, _segments, active = resolve_result_segments(survey, segment_param, **ResolvesResultSegments::OWNER_VIEW)
    responses  = active[:scope]
    aggregated = aggregate_results(Array(survey.cards), responses)
    [ ResultsExport.new(survey: survey, responses: responses, aggregated: aggregated), active ]
  end
end
