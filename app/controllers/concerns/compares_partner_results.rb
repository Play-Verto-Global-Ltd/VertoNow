# A partner's respondents to a shared Verto, beside everyone else who answered
# it — the comparison the partner results page draws
# (PartnershipVertosController#show) and its AI summary describes
# (PartnershipVertoSummariesController), resolved in one place so the two can
# never be about different people.
#
# Counted on the owner's results page's own terms — anyone who answered a
# question (ResolvesResultSegments#resolve_result_segments), not only those
# who finished — so a partner and the owner never read two different totals
# for one link.
#
# Everyone else is the owner's respondents, and other partners', so the pages
# built on this show it as distributions only, and not at all under the
# small-cell line: with four other people, "everyone else" is four people's
# answers.
#
# Filterable as the owner's page is — a date window, waves, places and the
# demographic slices, singly or combined — over the PARTNER's respondents, and
# the same filter is applied to everyone else, so their women are compared
# with everyone else's women rather than with everyone.
module ComparesPartnerResults
  extend ActiveSupport::Concern
  include ResolvesResultSegments

  # Fewer other respondents than this and the comparison is not drawn — the
  # small-cell line every other slice of a Verto's results is held to.
  BASELINE_MIN = ResolvesResultSegments::MIN_DEMOGRAPHIC_SAMPLE

  private

  # The partnership, for its owner or an active member; nil for anyone else.
  def visible_partnership
    partnership = Partnership.find_by(id: params[:partnership_id])
    partnership if partnership && (
      partnership.organisation_id == current_organisation.id ||
      partnership.partnership_memberships.active.exists?(organisation_id: current_organisation.id)
    )
  end

  # A page: anyone who can't see the partnership is sent back to their list.
  def load_partnership
    @partnership = visible_partnership
    redirect_to partnerships_path, alert: t("flash.partnership_vertos.partnership_not_found") unless @partnership
  end

  # The shared Verto and this organisation's own link to it — nil (and
  # @share unset) for an organisation the Verto was never shared with, which
  # each caller turns away in its own way.
  def load_partner_share(id = params[:id])
    @partnership_verto = @partnership.partnership_vertos.find(id)
    @survey = @partnership_verto.survey
    @share  = @partnership_verto.survey_shares.find_by(partner_organisation_id: current_organisation.id)
  end

  # Sets @date_range, @segments, @active_segment, @overall_total, @mine_total
  # and @others_total, and returns [the partner's slice, everyone else's
  # matching slice or nil when there is nobody to compare with].
  def resolve_partner_comparison(segment_param, range_param)
    @date_range = range_param.presence
    answered = apply_date_range(@survey.responses.where(answered: true).order(created_at: :desc), @date_range)
    mine     = answered.where(survey_share_id: @share.id)
    others   = answered.where.not(id: mine.reorder(nil).select(:id))

    @segments       = partner_segments(mine)
    @active_segment = select_result_segment(@segments, mine, segment_param)
    @overall_total  = mine.count
    @mine_total     = @active_segment[:count]

    others_slice  = matching_slice(others, @active_segment)
    @others_total = others_slice ? others_slice.count : 0
    [ @active_segment[:scope], (others_slice if @others_total >= BASELINE_MIN) ]
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
end
