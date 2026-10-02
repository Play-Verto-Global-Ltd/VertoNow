class PartnershipVertosController < ApplicationController
  include AggregatesSurveyResults
  include ResolvesResultSegments
  layout "fullscreen"

  # date_range_options is a private concern method — exposed to the view the
  # way SurveysController and SharedResultsController expose it.
  helper_method :date_range_options

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
    #
    # Filterable as the owner's page is — a date window, waves, places and the
    # demographic slices, singly or combined — over the PARTNER's respondents,
    # and the same filter is applied to everyone else, so their women are
    # compared with everyone else's women rather than with everyone.
    @date_range = params[:range].presence
    cards    = Array(@survey.cards)
    answered = apply_date_range(@survey.responses.where(answered: true).order(created_at: :desc), @date_range)
    mine     = answered.where(survey_share_id: @share.id)
    others   = answered.where.not(id: mine.reorder(nil).select(:id))

    @segments       = partner_segments(mine)
    @active_segment = select_result_segment(@segments, mine, params[:segment])
    @overall_total  = mine.count
    @mine_total     = @active_segment[:count]
    @mine_results   = aggregate_results(cards, @active_segment[:scope])
    @dwell          = @active_segment[:suppressed] ? {} : DwellTimes.for(cards, @active_segment[:scope])

    others_slice    = matching_slice(others, @active_segment)
    @others_total   = others_slice ? others_slice.count : 0
    @others_results = aggregate_results(cards, others_slice) if @others_total >= BASELINE_MIN
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

  # The owner's segments, less the "links" kind: a share's name is another
  # partner, and a named link's is the owner's own label for an audience
  # (the public results page leaves those out for the same reason).
  def partner_segments(base)
    result_segments(@survey, base, links: false)
      .reject { |s| ResolvesResultSegments.kind_of(s[:id]) == "links" }
  end

  # The same slice of everyone else — their wave 2 for the partner's wave 2,
  # their Austrian women for the partner's — built from everyone else's own
  # segments, so it is held to the small-cell line on their side as well.
  # nil where that slice doesn't exist there or is under the line: then there
  # is nothing to compare with, which the page says, rather than quietly
  # comparing against everybody.
  def matching_slice(others, active)
    return others if active[:id] == "overall"

    ids   = segment_ids(active)
    parts = partner_segments(others).select { |s| ids.include?(s[:id]) }
    return unless parts.size == ids.size

    slice = parts.one? ? parts.first : combine_result_segments(parts, others)
    slice[:scope] unless slice[:suppressed]
  end

  def segment_ids(active)
    Array(active[:parts]).map { |s| s[:id] }.presence || [ active[:id] ]
  end

  def require_creator_admin!
    return if @partnership.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to partnership_path(@partnership), alert: t("flash.partnership_vertos.creator_only")
  end
end
