# The Clients dashboard: every client account a Playverto staff member works
# in, with each one's Vertos, responders and seats at a glance, and a door
# into it (the Workspaces switch). Reached from the picker's "See all clients"
# row and the ⌘K palette.
#
# A staff surface, gated the way /comms is: a routing CONSTRAINT in
# config/routes.rb 404s anyone who is not Playverto staff (the existence of a
# cross-account overview is itself something customers have no reason to
# learn), and this before_action repeats the check as defence in depth,
# raising RecordNotFound so a request that bypasses the router still renders
# the same 404 the router gives.
class ClientsController < ApplicationController
  layout "fullscreen"

  before_action :require_playverto_staff

  def index
    @clients = ClientWorkspaces.for(Current.user)
    @stats   = ClientWorkspaces.stats_for(@clients.map(&:organisation))
  end

  private

  def require_playverto_staff
    raise ActiveRecord::RecordNotFound unless PlayvertoStaff.member?(Current.user)
  end
end
