module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    # Resolving the session is also the moment we learn the account is still
    # being used, so it is where that gets recorded — see Session#touch_seen!
    # for why, and for why it is throttled rather than written every request.
    # The return value is unchanged: require_authentication and authenticated?
    # both read it as a truthy check.
    def resume_session
      Current.session ||= find_session_by_cookie
      Current.session&.touch_seen!
      Current.session
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || default_landing_url
    end

    # A funder-owner org's home base is its Dashboard (seats, licensed orgs,
    # results) rather than the survey-authoring "My Vertos" screen — licensed
    # orgs and plain orgs still land there as before. Reads the same
    # membership OrganisationScope#set_current_organisation would pick, but
    # side-effect-free — the real before_action still runs (and still handles
    # a staff user with no organisation) on whichever page this sends them to.
    def default_landing_url
      org_id = session[:current_organisation_id]
      membership = Current.user.memberships.find_by(organisation_id: org_id) || Current.user.memberships.first
      membership&.organisation&.funder_enabled? ? funders_url : root_url
    end

    def start_new_session_for(user)
      # Session fixation (P1-16): rotate the Rails session at the privilege
      # boundary, so a session id an attacker planted before sign-in isn't the
      # one that ends up authenticated. The DB-backed Session row and its
      # signed cookie were already fresh per login; this covers the cookie
      # session that rides alongside them.
      #
      # One key survives on purpose: the URL the visitor was trying to reach
      # when they were bounced to sign-in is written BEFORE authentication and
      # read after it, so a blanket reset would silently send everyone to the
      # dashboard instead of where they were going.
      return_to = session[:return_to_after_authenticating]
      reset_session
      session[:return_to_after_authenticating] = return_to if return_to.present?

      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
