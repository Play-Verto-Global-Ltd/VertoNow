# Proving a respondent's address, so the organisations whose Vertos they kept
# are allowed to write to them.
#
# The gate this feeds already exists and has always been live:
# PlayerAudience.for_survey and #deliverable? refuse any address nobody has
# proved. What was missing is a way through it for the password door, which
# signs somebody in without ever showing they can read the inbox. Nothing else
# is gated on it — the account, the claims, the results and the wallet were
# never waiting on this, and must not start to. An unproven respondent can
# only fail to hear back, so that is the only thing proof unlocks.
class PlayerEmailConfirmationsController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  allow_signed_out_players only: :show
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # The resend only ever mails the account you are already inside — it takes
  # no address — so it is neither an enumeration oracle nor a way to write to
  # a stranger. The cap matches the creator's banner. Keyed on the player,
  # not the IP: a venue full of respondents shares one address, and each of
  # them is asking about their own inbox.
  rate_limit to: 5, within: 10.minutes, only: :create, name: "player_confirm_resend",
             by:   -> { "player:#{current_player&.id}" },
             with: -> { redirect_to you_path, alert: t("player_email_confirmation.too_many") }

  # How many confirmation mails one account may cause in a day, however they
  # are asked for. The per-player rate limit above is a burst cap; this is the
  # ceiling. It matters because whoever created an unproven account holds a
  # session in it — and if they typed someone else's address, the resend
  # button is a way to write to that person. Three is two more than anyone
  # who can actually read the inbox needs.
  MAX_SENDS_PER_PLAYER_PER_DAY = 3

  # GET /you/confirm/:token — the link in the mail.
  #
  # A GET that changes state, deliberately, and unlike the sign-in link's
  # GET/POST pair: that split exists because a scanner spending a single-use
  # credential costs its recipient the credential. This token is neither. It
  # is reusable until it expires and it grants nothing, so a scanner following
  # it confirms the address the mail was sent to — which is only true if the
  # scanner is reading that inbox. EmailConfirmationsController#show makes the
  # same call for creators, for the same reason: one tap.
  #
  # Straight on to the dashboard, with the confirmation said in its flash
  # (owner's call, 2026-09-23). Signed out — the mail opened on another device,
  # or in a mail app's own browser — it goes to the sign-in form instead, which
  # lands on the dashboard once they are in. It does NOT sign them in itself:
  # this token is reusable for a week and sits in an inbox, so letting it open
  # a session would make it a week-long bearer credential, which is the thing
  # PlayerSignInLink is deliberately 20 minutes and single-use to avoid.
  def show
    player = Player.find_by_token_for(:email_confirmation, params[:token].to_s)
    return render(:invalid, status: :not_found) if player.nil?

    # Read before verify_email!, which is idempotent, so a link re-opened a
    # week later says so rather than claiming to have done it again.
    state = player.email_verified? ? "already" : "confirmed"
    player.verify_email!

    # A heading and a sentence, carried as two flash values rather than glued
    # into one string: how a heading runs into the sentence after it is
    # punctuated differently across the 26 locales.
    flash[:notice]        = t("player_email_confirmation.#{state}_title")
    flash[:notice_detail] = t("player_email_confirmation.#{state}_body")

    # Signed in as somebody else on this device: their dashboard is not the
    # one the confirmation was about, so they sign in like anyone else would.
    redirect_to current_player == player ? you_path : new_player_session_path
  end

  # POST /you/confirm — "Send me the link", from /you and /you/account.
  def create
    if current_player.email_verified?
      return redirect_to you_path, notice: t("player_email_confirmation.already_confirmed")
    end

    unless self.class.sendable?(current_player)
      return redirect_to you_path, alert: t("player_email_confirmation.unavailable")
    end

    if self.class.deliver(current_player, survey: self.class.latest_survey_for(current_player))
      redirect_to you_path, notice: t("player_email_confirmation.resent", email: current_player.email_address)
    else
      redirect_to you_path, alert: t("player_email_confirmation.too_many")
    end
  end

  # Whether a confirmation mail could be sent to this player at all, before
  # anyone asks for one: false when the deployment has no working mail, and
  # when the address is on the suppression list. The /you banner draws from
  # this, so it never offers a button that cannot work.
  def self.sendable?(player)
    MailConfigCheck.deliverable? && !suppressed?(player)
  end

  def self.suppressed?(player)
    EmailSuppression.exists?(email: Comms.normalize_email(player.email_address))
  end

  # Queues the mail. Returns true when it was queued, false when it was not —
  # and never raises: by the time this runs the account has been created and
  # persisted, and a mail failure must not turn a completed signup into an
  # error (the EmailConfirmationsController.deliver discipline).
  #
  # Not sent to a suppressed address: that table holds hard bounces and
  # complaints, and a second try at one achieves nothing but spending the
  # sending domain's reputation.
  def self.deliver(player, survey: nil)
    return false if player.email_verified?
    return false unless sendable?(player)
    return false unless daily_budget_ok?(player)

    PlayerEmailConfirmationMailer.confirm(player, survey).deliver_later
    true
  rescue => e
    ErrorReporting.report("PlayerEmailConfirmationMailer", e, player_id: player&.id)
    false
  end

  def self.daily_budget_ok?(player)
    sent = Rails.cache.increment("player_confirm_sends:#{player.id}", 1, expires_in: 1.day)
    sent.nil? || sent <= MAX_SENDS_PER_PLAYER_PER_DAY
  end

  # What a resend is about: the Verto they most recently kept, so the subject
  # can name the organisation they actually have a relationship with.
  def self.latest_survey_for(player)
    player.player_claims.order(id: :desc).includes(survey: :organisation).first&.survey
  end
end
