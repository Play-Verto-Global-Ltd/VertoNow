module OrganisationScope
  extend ActiveSupport::Concern

  included do
    before_action :set_current_organisation
    helper_method :current_organisation, :current_membership, :can_create_vertos?, :can_edit_vertos?

    # Records which actions the creation gate covers, so a test can assert no
    # creation endpoint slipped past it. Same idiom (and same reason) as
    # ThrottlesAiSpend's ai_throttled_actions.
    class_attribute :verto_creation_actions, default: [], instance_writer: false
    # The same register for the editing gate: every action that changes a
    # Verto — its deck, its settings, whether it is live — is listed here, so
    # the coverage test can hold every SurveysController action to account.
    class_attribute :verto_editing_actions, default: [], instance_writer: false
  end

  class_methods do
    # Installs the gate AND records what it covers. Accumulates rather than
    # overwrites so a controller may declare it more than once.
    def gate_verto_creation(only:)
      actions = Array(only).map(&:to_sym)
      self.verto_creation_actions = (verto_creation_actions + actions).uniq
      before_action :require_verto_creation!, only: actions
    end

    # Same shape for editing. A viewer is refused at the door of every one of
    # these; member and admin pass. Creation implies editing, so an action
    # registered with gate_verto_creation needs no second registration here.
    def gate_verto_editing(only:)
      actions = Array(only).map(&:to_sym)
      self.verto_editing_actions = (verto_editing_actions + actions).uniq
      before_action :require_verto_editing!, only: actions
    end
  end

  private

  def set_current_organisation
    org_id = session[:current_organisation_id]
    membership = Current.user.memberships.includes(:organisation).find_by(organisation_id: org_id) ||
                 Current.user.memberships.includes(:organisation).first
    unless membership
      redirect_to new_session_path, alert: t("flash.organisation_scope.no_organisation") and return
    end
    Current.organisation = membership.organisation
    session[:current_organisation_id] = Current.organisation.id
    # The membership just resolved IS the current membership; the role checks
    # below and the views' predicates ask for it several times per request,
    # so hand it over rather than looking it up again each time.
    @current_membership = membership
    # Resolving the acting account is also the moment we learn this person is
    # working in it — throttled, see Membership#touch_visited!. It is what
    # orders the Workspaces picker's recent clients and dates the Clients
    # dashboard, and it happens here rather than only in the switcher because
    # a sign-in lands in an account without ever switching to it.
    membership.touch_visited!
  end

  def current_organisation
    Current.organisation
  end

  # Memoised per request: the role predicates (admin?, can_edit_vertos?,
  # can_create_vertos?) and every view that hides an affordance on them each
  # ask, and the answer can't change within one request.
  def current_membership
    return @current_membership if defined?(@current_membership)

    @current_membership = Current.user&.memberships&.find_by(organisation: Current.organisation)
  end

  # Whether a Verto can be created in the account currently being acted in.
  #
  # Two ways to qualify: the account creates its own Vertos, or the actor is
  # Playverto staff. The second is what makes a MANAGED account work — the
  # client cannot create, but the Playverto person building their Verto is
  # inside the same account and must be able to.
  #
  # Neither way is open to a viewer: their role says they share and read, and
  # creating is the one thing more than editing. Checked first, so a viewer
  # who happens to be Playverto staff is still a viewer here.
  #
  # Also the view predicate: every Create affordance is hidden on the same
  # answer that refuses the request, so a restricted user never meets a button
  # that bounces them.
  def can_create_vertos?
    return false unless Current.organisation
    return false unless can_edit_vertos?

    Current.organisation.verto_creation_enabled? || PlayvertoStaff.member?(Current.user)
  end

  # Whether the actor may change a Verto in the account currently being acted
  # in — open the editor, save the deck, publish, change settings. Every role
  # but viewer can. Unlike can_create_vertos? this is purely a property of the
  # ROLE: a managed account's members still edit the Vertos built for them.
  #
  # The view predicate for Edit, Publish and every other affordance that leads
  # into the editor, so a viewer never meets a button that bounces them.
  def can_edit_vertos?
    return false unless Current.organisation

    current_membership&.can_edit_vertos? || false
  end

  # Deliberately enforced HERE, at the controller boundary, and not as a
  # validation on Survey. Vertos are also created by the deck importer
  # (VertoCsvImporter), the demo seeder and BuildVertoJob — all of which build
  # Vertos FOR an account, restricted or not, and a model-level rule would
  # break them. Every user-reachable door is gated below; the job is only ever
  # enqueued from one of them.
  #
  # A viewer is refused with the viewer message, not the managed-account one:
  # "your Playverto team creates them for you" would be a lie to someone whose
  # own colleagues create them in the next seat.
  def require_verto_creation!
    return if can_create_vertos?

    can_edit_vertos? ? deny_verto_creation : deny_verto_editing
  end

  # The editing gate. Refuses a viewer at every action that changes a Verto;
  # member and admin pass straight through.
  def require_verto_editing!
    return if can_edit_vertos?

    deny_verto_editing
  end

  # A redirect answers an HTML request fine, but a fetch() asking for JSON gets
  # a 302 to a page of HTML it can't parse — which reads to the caller as a
  # mystery failure rather than "you're not an admin". Answer each in its own
  # language.
  def require_admin!
    return if current_membership&.admin?

    if request.format.json?
      render json: { ok: false, error: t("flash.organisation_scope.not_authorised") }, status: :forbidden
    else
      redirect_to root_path, alert: t("flash.organisation_scope.not_authorised")
    end
  end

  # Same two-language shape as require_admin!, for the same reason —
  # verto_builds#show is polled as JSON by the wait screen.
  def deny_verto_creation
    if request.format.json?
      render json: { ok: false, error: t("flash.organisation_scope.verto_creation_disabled") },
             status: :forbidden
    else
      redirect_to root_path, alert: t("flash.organisation_scope.verto_creation_disabled")
    end
  end

  # And again for the editing gate: the editor's autosave, card endpoints and
  # pollers are all fetch() calls that need a 403 they can read.
  def deny_verto_editing
    if request.format.json?
      render json: { ok: false, error: t("flash.organisation_scope.viewer_read_only") },
             status: :forbidden
    else
      redirect_to root_path, alert: t("flash.organisation_scope.viewer_read_only")
    end
  end
end
