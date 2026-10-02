# PATCH /surveys/:id/integrity_filter — the creator's switch for leaving Low
# and unverified responses out of a Verto's results (ResponseIntegrity).
#
# Admin-only, like sharing the results (ResultsSharesController): it changes
# what the results page, its exports, the AI report, the public results link
# and the partner page all count, for everyone who looks, so it is an
# account-level call rather than a per-editor view setting. Refused while
# scores are not visible, so the switch cannot be thrown blind.
class IntegrityFiltersController < ApplicationController
  before_action :require_admin!

  def update
    survey = Current.organisation.surveys.kept.without_report_text.find(params[:id])
    if ResponseIntegrity.visible?
      exclude = ActiveModel::Type::Boolean.new.cast(params[:exclude])
      survey.update!(exclude_low_integrity: exclude) unless exclude.nil?
    end
    redirect_to survey_results_path(survey, params.permit(:segment, :range).to_h.compact_blank)
  end
end
