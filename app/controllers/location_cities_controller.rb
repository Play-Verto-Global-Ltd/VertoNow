# The editor's city picker for a location card's "Limit to cities" setting
# (see LocationScope). Signed-in creators only — ApplicationController's
# Authentication requires a session — and it answers with city names and each
# city's public boundary box, which the editor stores on the card.
#
# Not survey-scoped: which cities exist doesn't depend on which Verto is open,
# and the card is saved through the ordinary autosave, which is where
# Survey.sanitize_cards_images! decides what of this is kept.
class LocationCitiesController < ApplicationController
  # Shares NominatimClient's app-wide outbound budget with every respondent's
  # search, so one creator hammering the picker is bounded here first.
  rate_limit to: 30, within: 1.minute, by: -> { Current.user&.id || request.remote_ip },
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }

  # GET /location_cities?q=nairo&countries[]=KE
  def index
    results = NominatimClient.search_cities(
      query: params[:q].to_s.first(80),
      countries: Array(params[:countries]).first(LocationScope::MAX_COUNTRIES),
      locale: I18n.locale.to_s
    )
    render json: { ok: true, results: results }
  end
end
