# The Share panel and the named links it manages.
#
# #show renders the panel itself into a Turbo Frame the dashboard opens as a
# modal; every mutation redirects straight back to it, so the frame re-renders
# from the same code path that drew it in the first place and there is no
# second, JSON-shaped copy of this screen to keep in step.
#
# Share links exist to hand different audiences different terms (see SurveyLink),
# which is an account-level decision about who sees whose answers — hence
# every mutation here is admin-only, the same bar as partner shares and Ask
# Verto opt-in.
#
# The panel itself (#show) is open to every role. Handing the link on is the
# one thing every seat in an account is for — it is the whole job of a viewer
# — and the panel is where the link, the QR and the share sheet live. A
# non-admin gets it read-only: the view draws the addresses and the copy
# buttons and none of the forms, on the same admin? answer that refuses the
# forms' endpoints here.
class SurveyLinksController < ApplicationController
  before_action :require_admin!, except: [ :show ]
  before_action :set_survey

  FRAME_ID = "share-modal".freeze

  # GET /surveys/:id/share
  def show
    load_links
    render layout: false
  end

  # POST /surveys/:survey_id/links
  def create
    if @survey.survey_links.count >= SurveyLink::MAX_PER_SURVEY
      return redirect_back_to_panel(error: "limit")
    end

    link = @survey.survey_links.new(
      name: params[:name].presence || t("share_modal.new_link_default_name"),
      show_results_comparison: tri_state(params[:show_results_comparison]),
      share_enabled:           tri_state(params[:share_enabled]),
      regions_enabled:         tri_state(params[:regions_enabled])
    )
    # Minted rather than validated-and-rejected: a creator who typed a custom
    # URL someone else already holds wants a working link, not a form error in
    # a modal they opened to share something. The suffix is visible in the list
    # the moment it renders, so nothing is hidden from them.
    link.slug = SurveyLink.mint_slug(params[:slug], fallback: link.name)
    link.save!
    redirect_back_to_panel
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_back_to_panel(error: "create")
  end

  # PATCH /surveys/:survey_id/links/:id
  #
  # Each control in the panel submits the single field it owns, matching the
  # editor's settings forms — so only what was sent is touched.
  def update
    link  = @survey.survey_links.find(params[:id])
    attrs = {}
    attrs[:name]   = params[:name].to_s.strip.first(SurveyLink::MAX_NAME) if params.key?(:name)
    attrs[:active] = ActiveModel::Type::Boolean.new.cast(params[:active])  if params.key?(:active)
    %i[show_results_comparison share_enabled regions_enabled].each do |flag|
      attrs[flag] = tri_state(params[flag]) if params.key?(flag)
    end
    # A renamed link keeps its address: the URL is already out in the world on
    # a poster or in someone's inbox, and rewriting it would silently kill it.
    # Changing the address is an explicit act — the slug field of its own.
    if params.key?(:slug)
      desired = Survey.normalize_slug(params[:slug])
      if desired.blank?
        return redirect_back_to_panel(error: "slug_blank")
      elsif desired != link.slug && Survey.play_key_taken?(desired, excluding_link_id: link.id)
        return redirect_back_to_panel(error: "taken")
      end
      attrs[:slug] = desired
    end

    link.update!(attrs) if attrs.any?
    redirect_back_to_panel
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_back_to_panel(error: "taken")
  end

  # DELETE /surveys/:survey_id/links/:id
  # The link dies; the responses that came in through it don't (dependent:
  # :nullify), they just stop being attributable to it.
  def destroy
    @survey.survey_links.find(params[:id]).destroy!
    redirect_back_to_panel
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:survey_id] || params[:id])
  end

  def load_links
    @links = @survey.survey_links.ordered.to_a
    # One grouped count for the whole panel rather than a query per row.
    @link_responder_counts =
      Response.where(survey_link_id: @links.map(&:id), answered: true)
              .group(:survey_link_id).count
    # Responders who arrived on the Verto's own link — the count for the
    # default row. Same "answered at least one question" basis as everywhere
    # else on the dashboard. A partner's share link is not the Verto's own link
    # either: its respondents are counted on the partnership's page, and here
    # they would read as this account's own traffic.
    @default_responder_count =
      @survey.responses.where(answered: true, survey_link_id: nil, survey_share_id: nil).count
  end

  # A checkbox can't say "inherit", so the three-state overrides are selects
  # posting "", "1" or "0". Anything else (including a missing param) reads as
  # inherit, which is the safe default: it follows the Verto.
  def tri_state(value)
    case value.to_s
    when "1" then true
    when "0" then false
    end
  end

  def redirect_back_to_panel(error: nil)
    redirect_to share_survey_path(@survey, link_error: error)
  end
end
