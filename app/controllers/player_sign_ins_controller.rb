# The link from the sign-in email, and the only way into a respondent account.
#
# GET renders a confirm page and consumes nothing; POST does the work. That
# split is not ceremony — corporate link scanners and inbox prefetchers follow
# GETs, and a single-use link that a scanner can spend is a link the person it
# was sent to can never use. Comms::UnsubscribesController splits for the same
# reason.
#
# The POST keeps ordinary CSRF protection rather than the null_session that
# controller uses. Unsubscribe needs null_session because RFC 8058 one-click
# POSTs arrive straight from mail clients with no token; this one comes from a
# form on a page Rails has just rendered. It matters: under null_session a
# failed check swaps in a cookie jar whose write is a no-op, so the link would
# be spent and the session silently never set.
class PlayerSignInsController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  allow_signed_out_players
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # A link is a bearer credential, and the address it was sent to is the only
  # thing bounding who can try one. Distinct names because Rails keys the
  # counter on [controller_path, name, ip] — see PlayerController's comment.
  #
  # Scaled by PLAYER_JOIN_RATE_LIMIT_SCALE, the same lever PlayerController's
  # join gates read, because the join journey does not end there. #join mints a
  # link and returns its path; the player JS navigates here; and THIS is where
  # the account actually begins. Scaling the door and leaving the corridor flat
  # meant a venue crowd cleared a 250-per-5-minutes gate and then hit a
  # 20-per-5-minutes one, five seconds later — found on the morning of the
  # event it would have happened at, with the first fix already in production.
  #
  # Read from the env rather than referenced as
  # PlayerController::JOIN_RATE_LIMIT_SCALE deliberately: a cross-controller
  # constant would make this class's limits depend on another controller having
  # been loaded first, which is a load-order bug waiting for the one request
  # that arrives in the wrong order. A test pins the two to the same variable
  # instead, which is the property that actually matters.
  #
  # What this widens, stated rather than glossed: the cap also bounds how many
  # EMAILED links one address may spend, which is the brute-force bound on a
  # bearer credential. A token is SecureRandom.urlsafe_base64(32) — 256 bits —
  # so 500 attempts in five minutes is no nearer guessing one than 20 was, and
  # #consume! is atomic single-use regardless. At the default of 1 this widens
  # nothing at all.
  JOIN_RATE_LIMIT_SCALE = ENV.fetch("PLAYER_JOIN_RATE_LIMIT_SCALE", "1").to_i.clamp(1, 10_000)
  rate_limit to: 20 * JOIN_RATE_LIMIT_SCALE, within: 5.minutes, only: :create, name: "signin_ip",
             with: -> { redirect_to you_path, alert: t("player_sign_in.too_many") }

  before_action :find_link

  def show
    # Nothing happens here. @link may be nil — the page says so rather than
    # 404ing, because "this link has already been used" is the single most
    # likely reason someone lands here and is worth saying plainly.
    #
    # A SIGNUP link continues on its own from here (see the view): nobody
    # needs to confirm a link their own browser was handed ten seconds ago.
    #
    # Set in the action rather than derived in the template, because #create's
    # failure path renders :show with @link still present. A template that
    # auto-continued whenever it saw a signup link would post, fail to consume,
    # re-render, and post again, forever. #create never sets this, so that
    # render always shows a button and a human.
    @auto_continue = @link.present? && !@link.proves_address?
  end

  def create
    return render :show, status: :unprocessable_entity if @link.nil?
    # Single use, atomically: two taps race here and exactly one wins.
    return render :show, status: :unprocessable_entity unless @link.consume!

    player = @link.player
    # Only a link that travelled through an inbox proves the address belongs to
    # whoever is spending it. A signup link was handed straight back in the join
    # response, so it establishes a session and nothing more — the address stays
    # unproven, and PlayerAudience.for_survey goes on refusing to mail it.
    player.verify_email! if @link.proves_address?
    # Written here rather than when the address was typed, so nothing is ever
    # recorded against an address until someone proves they can reach it.
    PlayerClaimPayload.apply(player: player, payload: @link.claim_payload,
                             reporting_context: "PlayerSignInsController#create")
    start_player_session_for(player)

    redirect_to you_path, notice: t("player_sign_in.welcome")
  end

  private

  def find_link
    @link = PlayerSignInLink.find_live(params[:token])
  end
end
