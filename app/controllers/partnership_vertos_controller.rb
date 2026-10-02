class PartnershipVertosController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"

  # Fewer other respondents than this and the comparison is not drawn — the
  # small-cell line every other slice of a Verto's results is held to.
  BASELINE_MIN = ResolvesResultSegments::MIN_DEMOGRAPHIC_SAMPLE

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

  def show
    @partnership_verto = @partnership.partnership_vertos.find(params[:id])
    @survey = @partnership_verto.survey

    @share = @partnership_verto.survey_shares.find_by(partner_organisation_id: current_organisation.id)
    unless @share
      redirect_to partnership_path(@partnership), alert: t("flash.partnership_vertos.no_share_link")
      return
    end

    # The owner's results page, for the partner's own respondents, beside
    # everyone else who answered the Verto. Counted on the owner's page's own
    # terms — anyone who answered a question (ResolvesResultSegments#
    # resolve_result_segments), not only those who finished — so a partner and
    # the owner never read two different totals for one link.
    #
    # Everyone else is the owner's respondents, and another partner's, so it
    # is shown as distributions only (surveys/_result_cards never draws a
    # baseline's free text) and not at all under the small-cell line: with
    # four other people, "everyone else" is four people's answers.
    cards  = Array(@survey.cards)
    base   = @survey.responses.where(answered: true)
    mine   = base.where(survey_share_id: @share.id)
    others = base.where.not(id: mine.select(:id))

    @mine_total     = mine.count
    @others_total   = others.count
    @mine_results   = aggregate_results(cards, mine)
    @others_results = aggregate_results(cards, others) if @others_total >= BASELINE_MIN
    @dwell          = DwellTimes.for(cards, mine)
  end

  private

  def load_partnership
    @partnership = Partnership.find_by(id: params[:partnership_id])
    unless @partnership && (
      @partnership.organisation_id == current_organisation.id ||
      @partnership.partnership_memberships.active.exists?(organisation_id: current_organisation.id)
    )
      redirect_to partnerships_path, alert: t("flash.partnership_vertos.partnership_not_found")
    end
  end

  def require_creator_admin!
    return if @partnership.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to partnership_path(@partnership), alert: t("flash.partnership_vertos.creator_only")
  end
end
