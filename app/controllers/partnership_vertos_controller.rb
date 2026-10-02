class PartnershipVertosController < ApplicationController
  include AggregatesSurveyResults
  include ComparesPartnerResults
  layout "fullscreen"

  # date_range_options is a private concern method — exposed to the view the
  # way SurveysController and SharedResultsController expose it.
  helper_method :date_range_options

  before_action :load_partnership
  before_action :require_creator_admin!, only: [ :create, :destroy ]

  def create
    survey = current_organisation.surveys.kept.find(params[:survey_id])
    @partnership.partnership_vertos.find_or_create_by!(survey_id: survey.id)
    PartnershipShareSync.ensure_shares_for(partnership: @partnership)
    redirect_to partnership_path(@partnership), notice: t("flash.partnership_vertos.added", verto: survey.title.presence || "Verto", partnership: @partnership.name)
  end

  def destroy
    av = @partnership.partnership_vertos.find(params[:id])
    av.destroy!
    redirect_to partnership_path(@partnership), notice: t("flash.partnership_vertos.removed", partnership: @partnership.name)
  end

  # The owner's results page for the partner's own respondents, with everyone
  # else drawn beside every answer — see ComparesPartnerResults for who is in
  # which group and why.
  def show
    unless load_partner_share
      redirect_to partnership_path(@partnership), alert: t("flash.partnership_vertos.no_share_link")
      return
    end

    mine, others    = resolve_partner_comparison(params[:segment], params[:range])
    cards           = Array(@survey.cards)
    @mine_results   = aggregate_results(cards, mine)
    @others_results = aggregate_results(cards, others) if others
    @dwell          = @active_segment[:suppressed] ? {} : DwellTimes.for(cards, mine)
  end

  private

  def require_creator_admin!
    return if @partnership.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to partnership_path(@partnership), alert: t("flash.partnership_vertos.creator_only")
  end
end
