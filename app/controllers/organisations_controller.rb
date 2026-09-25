class OrganisationsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!, only: [ :edit, :update ]

  # The Workspaces switcher. Deliberately does NOT honour a return_to: you
  # switch workspaces from pages like /surveys/123/results, and every one of
  # those is scoped to Current.organisation.surveys — so returning there after
  # the org changes would 404. Home is the only destination that always exists.
  #
  # default_landing_url (Authentication) resolves the home of the org we just
  # switched TO, since it reads session[:current_organisation_id] — so a
  # funder-owner workspace lands on its Funders dashboard rather than a My
  # Vertos screen it doesn't use. An unauthorised id is a silent no-op: it
  # leaks nothing, and a revoked membership just lands you back home.
  #
  # The visit is recorded here, unthrottled, as well as by the landing page's
  # own (throttled) resolution: the switch is the choice, and it is what puts
  # this account at the top of the picker's recent clients.
  def switch
    membership = Current.user.memberships.find_by(organisation_id: params[:organisation_id].to_i)
    if membership
      session[:current_organisation_id] = membership.organisation_id
      membership.touch_visited!(force: true)
    end
    redirect_to default_landing_url
  end

  def edit
    @organisation = current_organisation
  end

  def update
    @organisation = current_organisation

    # `params.require` raises ActionController::ParameterMissing, which Rails
    # maps to a bare 400 with no body and no `public/400.html` to fill it. From
    # the client that is indistinguishable from the app falling over — and it is
    # exactly what an interrupted or unparseable multipart upload produces, i.e.
    # the case a logo upload actually hits. A missing key is a malformed
    # request, not a crash, so answer it the way every other rejection here is
    # answered: a status the client can read, with a reason attached.
    attrs  = params.fetch(:organisation, ActionController::Parameters.new)
                   .permit(:name, :logo, :remove_logo, :logo_on_light, :remove_logo_on_light)
    remove       = ActiveModel::Type::Boolean.new.cast(attrs.delete(:remove_logo))
    remove_light = ActiveModel::Type::Boolean.new.cast(attrs.delete(:remove_logo_on_light))

    if attrs.empty? && !remove && !remove_light
      return respond_to_update(false, remove,
                               "We didn't receive the file — the upload may have been interrupted. Please try again.")
    end

    # SVG is stored and later served inline (see config/initializers/
    # active_storage.rb), so it must be scrubbed before it ever reaches
    # storage — an unsanitised SVG served same-origin would be stored XSS.
    # BOTH logos, not just the first. An unsanitised SVG served same-origin is
    # stored XSS, and a second upload slot that skipped this would be a second
    # door into the same hole — the reason this loop exists rather than a
    # repeated block.
    attrs = attrs.to_h
    %i[logo logo_on_light].each do |field|
      next unless svg_upload?(attrs[field])

      cleaned = SvgSanitizer.clean_document(attrs[field].read)
      if cleaned.nil?
        return respond_to_update(false, remove,
                                 "We couldn't read that SVG safely — please re-export it, or upload a PNG instead.")
      end
      attrs[field] = { io: StringIO.new(cleaned), filename: attrs[field].original_filename,
                       content_type: "image/svg+xml" }
    end

    @organisation.logo.purge          if remove
    @organisation.logo_on_light.purge if remove_light
    ok = @organisation.update(attrs)
    respond_to_update(ok, remove || remove_light,
                      @organisation.errors.full_messages.to_sentence.presence || "Could not update organisation.")
  end

  private

  def svg_upload?(file)
    file.respond_to?(:content_type) && file.content_type == "image/svg+xml"
  end

  def respond_to_update(ok, remove, error)
    respond_to do |format|
      format.html do
        if ok
          redirect_to organisation_memberships_path(@organisation),
                      notice: remove ? "Logo removed." : "Brand updated."
        else
          redirect_to organisation_memberships_path(@organisation), alert: error
        end
      end
      format.json do
        if ok
          logo_url = @organisation.logo.attached? ? helpers.rails_blob_path(@organisation.logo, only_path: true) : nil
          render json: { ok: true, logo_url: logo_url }
        else
          render json: { ok: false, error: error }, status: :unprocessable_entity
        end
      end
    end
  end
end
