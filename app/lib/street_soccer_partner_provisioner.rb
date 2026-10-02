# Opens a PARTNER account for Street Soccer (Dan Wood) and hands it the link
# they were already sending respondents to.
#
# Dan spread an Unleash Football Verto through a named link of Unleash
# Football's, /play/street-football. That makes him a partner in all but
# name, and a named link can't show anyone outside the owning account its
# results. So this does what PartnershipAccountsController#create does for an
# owner who clicks "Create account", then gives Dan the link itself:
#
#   * a "Street Soccer" organisation of his own, with Dan as its admin — an
#     ordinary account, so creating Vertos is on (the column default);
#   * a partnership owned by whichever account owns the Verto at that address
#     (Unleash Football), with Street Soccer as an active member;
#   * the Verto added to that partnership, which mints Street Soccer's
#     SurveyShare;
#   * the named link's ADDRESS moved onto that share, and every response that
#     came in through the link re-attributed to it, so Dan's partner page
#     counts the respondents he has already gathered and the printed link keeps
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
# database) it does nothing at all — no account, no email.
#
# If the address turns out to be the Verto's OWN custom link rather than a
# named one, the account, partnership and share are still made but nothing is
# moved: that slug is the whole Verto's address, and which of its responses
# were Dan's is not something the database can say.
class StreetSoccerPartnerProvisioner
  LINK_SLUG        = "street-football"
  PARTNERSHIP_NAME = "Unleash Football partners"
  ORG_SLUG         = "street-soccer"
  ORG_NAME         = "Street Soccer"
  ADMIN_NAME       = "Dan Wood"
  ADMIN_EMAIL      = "danieljwood9@gmail.com"

  Result = Struct.new(:survey, :partnership, :organisation, :user, :share,
                      :user_created, :welcome_sent, :link_adopted, :responses_moved,
                      :link_overrides, :link_was_paused, keyword_init: true)

  # nil when nothing in the /play namespace answers to LINK_SLUG.
  def call
    survey, link = resolve
    return unless survey

    result = ActiveRecord::Base.transaction { provision!(survey, link) }
    result.welcome_sent = result.user_created && deliver_welcome(result)
    result
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
    user        = find_or_create_user!
    Membership.find_or_create_by!(user: user, organisation: org) { |m| m.role = "admin" }

    PartnershipMembership.join!(partnership: partnership, organisation: org)
    partnership_verto = partnership.partnership_vertos.find_or_create_by!(survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: partnership)
    share = partnership_verto.survey_shares.find_by!(partner_organisation: org)

    overrides = link ? pinned_overrides(link) : {}
    paused    = link ? !link.active? : false
    moved     = link ? adopt_link!(link, share) : 0

    Result.new(survey: survey, partnership: partnership, organisation: org, user: user,
               share: share, user_created: user.previously_new_record?,
               link_adopted: share.share_token == LINK_SLUG,
               responses_moved: moved, link_overrides: overrides, link_was_paused: paused)
  end

  # Case-insensitively, as Partnership's own uniqueness rule compares names.
  def find_or_create_partnership!(owner)
    owner.partnerships.find_by("LOWER(name) = ?", PARTNERSHIP_NAME.downcase) ||
      owner.partnerships.create!(name: PARTNERSHIP_NAME)
  end

  # Credential-free, as PartnershipAccountsController creates partner users: a
  # throwaway password Dan replaces through the emailed setup link (or, after
  # that link's week is up, the ordinary password reset).
  def find_or_create_user!
    User.find_or_create_by!(email_address: ADMIN_EMAIL) do |u|
      u.name             = ADMIN_NAME
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

  # Only for an account this run made: an existing user already has a
  # password, and "an admin set up an account for you" would be untrue.
  # A failed send must not undo the account — the password reset reaches the
  # same place — so it is reported, not raised.
  def deliver_welcome(result)
    PartnershipAccountMailer.welcome(result.user, result.partnership).deliver_now
    true
  rescue => e
    ErrorReporting.report("StreetSoccerPartnerProvisioner", e, user_id: result.user.id)
    false
  end
end
