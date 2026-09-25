# The client accounts a Playverto staff member works in, and what each one is
# up to — the data behind the Clients dashboard (/clients) and the staff shape
# of the Workspaces picker.
#
# A "client" is every account the person belongs to EXCEPT the Playverto
# workspace itself (PlayvertoStaff::SLUG). It is membership-based on purpose:
# the picker and the dashboard both lead somewhere by switching INTO the
# account (OrganisationsController#switch), and that door only opens for a
# membership. An account nobody on the team has been added to is not one the
# team works in, so it is not listed — being Playverto staff reaches into the
# accounts you are in, not into every account on the platform.
#
# Two orderings, two questions. `recent_for` answers "which clients was I in
# most recently" — the picker's two rows — and puts the account currently
# being acted in first, because it IS the most recently viewed one, whatever
# the throttled timestamp says (Membership#touch_visited! writes at most once
# an hour, so a sign-in that lands in a client opened earlier that morning
# would otherwise not move it). `for` is the full list for the dashboard: the
# same recency, then every account never opened since the column arrived, by
# name, rather than a NULL-sorting accident deciding between engines.
module ClientWorkspaces
  module_function

  # Every client account this person belongs to, as [membership, organisation]
  # pairs — the role beside each name comes from the membership, so the pair
  # is what every caller actually wants. Recent first, then by name.
  def for(user)
    memberships = client_memberships(user).includes(organisation: { logo_attachment: :blob }).to_a
    memberships.sort_by { |m| [ m.last_visited_at ? 0 : 1, -m.last_visited_at.to_i, m.organisation.name.downcase ] }
  end

  # The `limit` most recently opened clients, as memberships (organisation
  # preloaded), with the acting account first when it is a client.
  def recent_for(user, current_organisation: nil, limit: 2)
    recent = client_memberships(user).recently_visited.includes(:organisation).limit(limit).to_a
    current = recent.find { |m| m.organisation_id == current_organisation&.id } ||
              (current_organisation && client_memberships(user).includes(:organisation)
                                                              .find_by(organisation_id: current_organisation.id))
    ([ current ] + recent).compact.uniq(&:organisation_id).first(limit)
  end

  # Per-account tallies for a set of organisations, as a few grouped queries
  # rather than a count per card — the same move SurveysController#index makes
  # for its tiles, and for the same reason. Each value is a Hash keyed by
  # organisation id; a missing key means zero.
  #
  #   vertos      kept (unarchived) Vertos
  #   live        of those, the ones respondents can play right now (Survey#published?:
  #               a publish token and not unpublished since)
  #   responders  people who answered at least one question, across kept Vertos
  #   completed   of those, the ones who finished — completion is completed/responders,
  #               the basis the My Vertos strip uses, so the two agree
  #   members     seats in the account
  #
  # Responders join through surveys so an archived Verto's respondents are not
  # counted against an account that has put that Verto away.
  Stats = Struct.new(:vertos, :live, :responders, :completed, :members, keyword_init: true) do
    def completion_rate(organisation_id)
      answered = responders[organisation_id].to_i
      return nil unless answered.positive?

      ((completed[organisation_id].to_i.to_f / answered) * 100).round
    end
  end

  def stats_for(organisations)
    ids     = organisations.map(&:id)
    surveys = Survey.kept.where(organisation_id: ids)
    answers = Response.joins(:survey).where(surveys: { organisation_id: ids, deleted_at: nil }, answered: true)

    Stats.new(
      vertos:     surveys.group(:organisation_id).count,
      live:       surveys.where.not(publish_token: nil).where(unpublished_at: nil).group(:organisation_id).count,
      responders: answers.group("surveys.organisation_id").count,
      completed:  answers.where(status: "completed").group("surveys.organisation_id").count,
      members:    Membership.where(organisation_id: ids).group(:organisation_id).count
    )
  end

  def client_memberships(user)
    user.memberships.joins(:organisation).where.not(organisations: { slug: PlayvertoStaff::SLUG })
  end
end
