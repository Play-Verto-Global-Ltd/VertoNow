# Google, coming back with a RESPONDENT.
#
# Its own controller on its own path, reached only from the `google_player`
# strategy (see config/initializers/omniauth.rb). OauthSessionsController mints
# a User and a workspace; this one mints a Player. Those are different tables
# behind different cookies, and PlayerAuthentication's header explains what
# happens when one is reachable through the other's plumbing. Which of the two
# a callback may create is therefore decided by the redirect_uri Google
# validated, and never by anything the browser carried.
#
# What this does NOT need, because of that: a flag in the session saying which
# flow is in progress, and every other page in the app remembering to clear it.
class PlayerOauthSessionsController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  allow_signed_out_players
  skip_before_action :set_current_organisation

  def create
    auth = request.env["omniauth.auth"]
    return redirect_failed unless auth

    email = verified_email(auth)
    return redirect_unverified if email.nil?

    # Looked at BEFORE the account, because it decides whether one may be
    # made. A handoff is minted only once PlayerController#join_google has let
    # the run through its minimum-age check (AccountAge), so one parked by this
    # browser — live, expired or already spent — means that check was passed.
    # Without one this is the bare "Continue with Google" on /you, which may
    # sign an existing account in but must not open a new one: it never asked
    # an age, and the Privacy Notice says accounts are not available under 16.
    # New accounts start at the end of a Verto, where the age is known or
    # declared.
    handoff_id = session.delete(:player_oauth_handoff_id)
    age_passed = handoff_id.present? && PlayerOauthHandoff.exists?(id: handoff_id)
    handoff    = spend_handoff(handoff_id)
    player     = locate_or_create_player!(auth, email, may_create: age_passed)
    return redirect_no_account if player.nil?

    # Google has asserted the address, which is strictly better proof than the
    # emailed link this card was built around: that one proves somebody can
    # read the inbox, this one is the mailbox provider itself saying whose it
    # is. So the account is verified, and PlayerAudience will mail it — which
    # is the point. A respondent signing up this way never depends on an email
    # arriving in order to have an account at all.
    player.verify_email!
    remember_locale(player, handoff&.locale)
    PlayerClaimPayload.apply(player: player, payload: handoff&.claim_payload,
                             reporting_context: "PlayerOauthSessionsController#create")
    start_player_session_for(player)

    redirect_to you_path, notice: t("player_sign_in.welcome")
  rescue => e
    ErrorReporting.report("PlayerOauthSessions", e)
    redirect_failed
  end

  private

  # Only an address the provider says it has verified. An unverified one is not
  # evidence of anything — it is a string somebody typed into a Google profile
  # — and treating it as a key would let a new identity walk into an existing
  # account by claiming its address. Same rule, same reason, as
  # OauthSessionsController#locate_or_create_user!.
  def verified_email(auth)
    return nil if auth.extra&.raw_info&.email_verified == false

    auth.info&.email.to_s.strip.downcase.presence
  end

  # (provider, uid) is canonical: it is the only part of this that a person
  # cannot change. The address is the fallback, and only because it has just
  # been verified — that is what makes "sign in with Google" find the account
  # somebody previously made with that address and a password, rather than
  # silently starting a second one beside it.
  #
  # nil when there is no account to find and may_create is false.
  def locate_or_create_player!(auth, email, may_create:)
    identity = PlayerIdentity.find_or_initialize_by(provider: auth.provider.to_s, uid: auth.uid.to_s)
    name     = auth.info&.name.to_s.strip.presence

    player = identity.player || Player.find_by(email_address: email)
    return nil if player.nil? && !may_create

    player ||= create_player!(email, name)
    # The name is the provider's to refresh, but it must not overwrite one the
    # respondent set themselves on /you.
    player.update_column(:name, name) if name && player.name.blank?
    identity.update!(player: player, email: email, name: name)
    player
  end

  # Passwordless, which Player allows on purpose (has_secure_password
  # validations: false). Signing in with Google IS the credential; asking this
  # account to also carry a password nobody chose would mean inventing one, and
  # an unknown password on a real account is worse than none.
  def create_player!(email, name)
    Player.create!(email_address: email, name: name)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Two tabs finishing at once. The loser takes the winner's row rather than
    # failing a sign-in that was, by then, perfectly valid.
    Player.find_by(email_address: email) || raise
  end

  # The run parked at /you/join/:token, if this browser is still the one that
  # parked it. Spent atomically, so a second tab returning from Google cannot
  # apply the same claims twice; a handoff that has expired or been spent leaves
  # the sign-in itself untouched, because being signed in is worth more than the
  # one run that brought them here — and that run is reclaimable by playing it
  # again.
  def spend_handoff(id)
    return nil if id.blank?

    handoff = PlayerOauthHandoff.live.find_by(id: id)
    handoff&.consume! ? handoff : nil
  end

  # The language they were playing in, for an account that has not expressed a
  # preference. Mirrors PlayerController#remember_play_locale.
  def remember_locale(player, locale)
    return if player.preferred_locale.present?

    coerced = SupportedLocales.coerce(locale.presence || I18n.locale)
    player.update_column(:preferred_locale, coerced)
  end

  # Back to the respondent's own door, never the creator's — a person who
  # started at the end of a Verto has no idea what /session/new is.
  def redirect_failed
    redirect_to new_player_session_path,
                alert: t("auth.social_failed", provider: SocialAuth.label_for(:google_player))
  end

  def redirect_no_account
    redirect_to new_player_session_path,
                alert: t("auth.social_no_player_account", provider: SocialAuth.label_for(:google_player))
  end

  def redirect_unverified
    redirect_to new_player_session_path,
                alert: t("auth.social_no_email", provider: SocialAuth.label_for(:google_player))
  end
end
