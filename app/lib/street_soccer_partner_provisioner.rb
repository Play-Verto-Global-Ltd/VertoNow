# Opens a PARTNER account for Street Soccer and hands it the link its people
# were already sending respondents to.
#
# Street Soccer (Dan Wood) spread an Unleash Football Verto through a named
# link of Unleash Football's, /play/street-football. That makes them a partner
# in all but name, and a named link can't show anyone outside the owning
# account its results. So this does what PartnershipAccountsController#create
# does for an owner who clicks "Create account", then gives Street Soccer the
# link itself:
#
#   * a "Street Soccer" organisation — an ordinary account, so creating Vertos
#     is on (the column default) — with Nick and Jamie as its admins, as they
#     are of the managed accounts (ManagedAccountProvisioner). Street Soccer's
#     own people are invited from its Members page like anyone else's: Dan was
#     created here at first and removed again (RemoveDanWoodFromStreetSoccer)
#     so that he could be added through the platform instead;
#   * a partnership owned by whichever account owns the Verto at that address
#     (Unleash Football), with Street Soccer as an active member;
#   * the Verto added to that partnership, which mints Street Soccer's
#     SurveyShare;
#   * the named link's ADDRESS moved onto that share, and every response that
#     came in through the link re-attributed to it, so the partner page
#     counts the respondents they had already gathered and the printed link keeps
#     working. The link row itself is then deleted — it has nothing left to
#     answer for, and keeping it would mean two rows in the /play namespace
#     claiming one address.
#
# What a respondent may notice: a share has no per-link overrides, so the
# results comparison, Share button and regions map follow the Verto's own
# settings from now on. #call reports any the link had pinned, so the
# migration's output says so instead of it changing silently — and likewise if
# the link was paused, since a share has no pause and the address answers again.
#
# Create-only, like ManagedAccountProvisioner: an existing user keeps their
# password and name, an existing membership keeps its role, an existing
# partnership membership keeps its status. Running it twice changes nothing
# the second time. On a database without the address (every dev and test
# database) it does nothing at all.
#
# If the address turns out to be the Verto's OWN custom link rather than a
# named one, the account, partnership and share are still made but nothing is
# moved: that slug is the whole Verto's address, and which of its responses
# were Street Soccer's is not something the database can say.
class StreetSoccerPartnerProvisioner
  LINK_SLUG        = "street-football"
  PARTNERSHIP_NAME = "Unleash Football partners"
  ORG_SLUG         = "street-soccer"
  ORG_NAME         = "Street Soccer"
  # Playverto's own people, as admins — { email => name }.
  ADMINS = {
    ManagedAccountProvisioner::NICK_EMAIL  => ManagedAccountProvisioner::NICK_NAME,
    ManagedAccountProvisioner::JAMIE_EMAIL => ManagedAccountProvisioner::JAMIE_NAME
  }.freeze

  Result = Struct.new(:survey, :partnership, :organisation, :share, :link_adopted,
                      :responses_moved, :link_overrides, :link_was_paused, keyword_init: true)

  # nil when nothing in the /play namespace answers to LINK_SLUG.
  def call
    survey, link = resolve
    return unless survey

    ActiveRecord::Base.transaction { provision!(survey, link) }
  end

  private

  # A share already holding the slug is a previous run that finished, and is
  # checked first because it is what the player resolves first.
  def resolve
    if (share = SurveyShare.find_by(share_token: LINK_SLUG))
      [ share.survey, nil ]
    elsif (link = SurveyLink.find_by(slug: LINK_SLUG))
      [ link.survey, link ]
    else
      [ Survey.where.not(publish_token: nil).find_by(slug: LINK_SLUG), nil ]
    end
  end

  def provision!(survey, link)
    partnership = find_or_create_partnership!(survey.organisation)
    org         = Organisation.find_or_create_by!(slug: ORG_SLUG) { |o| o.name = ORG_NAME }
    ADMINS.each do |email, name|
      Membership.find_or_create_by!(user: find_or_create_user!(email, name), organisation: org) { |m| m.role = "admin" }
    end

    PartnershipMembership.join!(partnership: partnership, organisation: org)
    partnership_verto = partnership.partnership_vertos.find_or_create_by!(survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: partnership)
    share = partnership_verto.survey_shares.find_by!(partner_organisation: org)

    overrides = link ? pinned_overrides(link) : {}
    paused    = link ? !link.active? : false
    moved     = link ? adopt_link!(link, share) : 0

    Result.new(survey: survey, partnership: partnership, organisation: org, share: share,
               link_adopted: share.share_token == LINK_SLUG,
               responses_moved: moved, link_overrides: overrides, link_was_paused: paused)
  end

  # Case-insensitively, as Partnership's own uniqueness rule compares names.
  def find_or_create_partnership!(owner)
    owner.partnerships.find_by("LOWER(name) = ?", PARTNERSHIP_NAME.downcase) ||
      owner.partnerships.create!(name: PARTNERSHIP_NAME)
  end

  # Credential-free, as ManagedAccountProvisioner creates its people: a
  # throwaway password, claimed through the ordinary password reset. Nick and
  # Jamie already have accounts wherever this matters, so this is only the
  # safety net — and as it only runs on create, an existing password is never
  # touched.
  def find_or_create_user!(email, name)
    User.find_or_create_by!(email_address: email) do |u|
      u.name             = name
      u.password         = SecureRandom.hex(32)
      u.password_pending = true
    end
  end

  # The share takes the responses first, while the link still identifies them;
  # destroying the link then clears survey_link_id (SurveyLink's
  # dependent: :nullify), so they count once, as the partner's.
  def adopt_link!(link, share)
    moved = Response.where(survey_link_id: link.id, survey_share_id: nil)
                    .update_all(survey_share_id: share.id)
    link.destroy!
    share.update!(share_token: LINK_SLUG)
    moved
  end

  def pinned_overrides(link)
    {
      "results comparison" => link.show_results_comparison,
      "Share button"       => link.share_enabled,
      "regions map"        => link.regions_enabled
    }.compact
  end
end
