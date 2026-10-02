class PartnershipMembership < ApplicationRecord
  belongs_to :partnership
  belongs_to :organisation

  enum :status, { active: "active", pending: "pending", revoked: "revoked" }

  validate :different_from_creator

  # Makes `organisation` an active partner in `partnership` and syncs its
  # SurveyShare rows for the partnership's existing Vertos. Shared by the
  # invite-accept flow (InvitesController) and the owner-creates-account flow
  # (PartnershipAccountsController) so both end up in the identical state.
  def self.join!(partnership:, organisation:)
    find_or_create_by!(partnership: partnership, organisation: organisation) { |m| m.status = "active" }
    PartnershipShareSync.ensure_shares_for(partnership: partnership)
  end

  # True when this partner org's admin hasn't finished PartnerAccountSetupsController
  # yet — e.g. an owner-created account whose invite email hasn't been actioned.
  # Powers the "Setup pending" badge on the creator's partnership page.
  #
  # The EARLIEST admin, i.e. the partner the account was made for: a partner
  # account can carry a second admin (Street Soccer has the Playverto owner),
  # and the association is unordered, so "the first admin found" could be
  # either on Postgres. Picked in Ruby so the creator page's preload still serves it.
  def setup_pending?
    admin = organisation.memberships.to_a.select(&:admin?).min_by { |m| [ m.created_at, m.id ] }
    admin&.user&.password_pending? || false
  end

  private

  def different_from_creator
    return unless partnership && organisation_id == partnership.organisation_id
    errors.add(:organisation, "cannot be the partnership creator")
  end
end
