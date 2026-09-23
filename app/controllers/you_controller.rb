# A respondent's own account: the Vertos they kept.
#
# Outside /play/ deliberately. That path is the service worker's entire scope
# and its HTML is cached for offline use; a signed-in page has no business in a
# shared device's cache. It is also never embedded, which is why its cookie can
# be SameSite=Lax.
class YouController < ApplicationController
  include PlayerAuthentication
  include AggregatesSurveyResults

  allow_unauthenticated_access
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # Signed out is a real state here, not a redirect: there is no sign-in form
  # to send anyone to. The page explains what /you is and how to get one.
  allow_signed_out_players only: :show

  before_action :no_store
  # Only the pages that draw the bar. sign_out and destroy render nothing,
  # and the three PATCHes redirect.
  before_action :set_purse, only: %i[show verto wallet account]
  # The fullscreen layout parks its language switcher in a fixed corner; these
  # pages draw their own bar with the switcher inside it (you/_bar).
  before_action :own_top_bar

  # A password field, on a page only a signed-in respondent can reach — so the
  # cap is against a stolen session guessing the current password, not against
  # the internet. Named, because Rails keys the counter on the name.
  rate_limit to: 10, within: 5.minutes, only: :update_password, name: "you_pw_ip",
             with: -> { redirect_to you_account_path, alert: t("player_session.too_many") }

  # How many Vertos the wallet pill's hover breakdown shows before handing over
  # to the wallet itself. Five is a peek, not a second wallet — the pill exists
  # to answer "what have I got" in one glance, and a list long enough to scroll
  # would only be the page it links to, rendered worse.
  PURSE_PREVIEW = 5

  # The strategy name the respondent Google sign-in is mounted under — see
  # config/initializers/omniauth.rb; PlayerOauthSessionsController stores
  # auth.provider verbatim.
  GOOGLE_PROVIDER = "google_player"

  # The dashboard. One card per VERTO, not per run: a retake is what they
  # think now, not a second Verto, so its claims are folded into the one row
  # and its piles summed — exactly as token_rows and #verto already do.
  def show
    @claims     = kept_claims
    @rows       = verto_rows(@claims)
    @answered   = answered_counts(@claims)
    @compare    = comparison_availability(@claims, @answered)
    @follow_ups = follow_ups_for(@claims)
    @questions  = @rows.to_h { |row| [ row[:survey].id, question_count(row[:survey]) ] }
    @tiles      = tiles_for(@rows)
    @next       = next_for(@rows)
    @impacts    = impacts_for(@rows)
    @confirm    = confirmation_state
  end

  # ── Settings ──────────────────────────────────────────────────────────────

  def account
    load_account
  end

  # The name only. The address is not editable here: it is the one thing the
  # account is keyed on, and changing it would need proof of the new inbox.
  # The address confirmation (PlayerEmailConfirmationsController) could now
  # carry that proof, so this is a choice not yet made rather than a thing
  # that cannot be built.
  def update_account
    name = params[:name].to_s.strip.first(Player::MAX_NAME + 1)
    if current_player.update(name: name.presence)
      redirect_to you_account_path, notice: t("you.saved")
    else
      load_account
      flash.now[:alert] = current_player.errors.full_messages.to_sentence
      render :account, status: :unprocessable_entity
    end
  end

  # Set when there is none, change when there is. The current password is
  # demanded only in the second case — an account that began with an emailed
  # link or with Google has nothing to demand — and it is checked LAST, after
  # the new one has been found acceptable, so a typo in the confirmation does
  # not spend a guess against the rate limit above.
  def update_password
    player   = current_player
    password = params[:password].to_s
    had_one  = player.password_digest.present?

    if password.length < Player::MIN_PASSWORD
      return redirect_to you_account_path, alert: t("you.password_short", min: Player::MIN_PASSWORD)
    end
    if password != params[:password_confirmation].to_s
      return redirect_to you_account_path, alert: t("you.password_mismatch")
    end
    if had_one && !player.authenticate(params[:current_password].to_s)
      return redirect_to you_account_path, alert: t("you.password_wrong")
    end

    player.update!(password: password)
    redirect_to you_account_path, notice: t(had_one ? "you.password_changed" : "you.password_set")
  end

  # The language is written to the cookie as well as the account, exactly as
  # LocalesController does, so the page they land back on is already in it —
  # switch_locale reads the cookie ahead of the account.
  #
  # The email toggles are honoured only for organisations this account holds
  # a Verto from. An id from anywhere else is not an error, it is nothing: a
  # preference row for an organisation that never mailed them would sit in
  # the table meaning nothing, and the unsubscribe link in a real mail is the
  # other writer of these rows.
  def update_preferences
    locale = I18n.locale
    if params[:preferred_locale].present?
      locale = SupportedLocales.coerce(params[:preferred_locale])
      current_player.update(preferred_locale: locale)
      cookies.permanent[:locale] = { value: locale, same_site: :lax }
    end

    emails = params[:emails].respond_to?(:to_unsafe_h) ? params[:emails].to_unsafe_h : {}
    held_organisations.each do |organisation|
      case emails[organisation.id.to_s]
      when "0" then PlayerEmailPreference.unsubscribe!(player: current_player, organisation: organisation)
      when "1" then PlayerEmailPreference.resubscribe!(player: current_player, organisation: organisation)
      end
    end

    # In the language they just chose, not the one they arrived in: this flash
    # is written in one request and read in the next, and that next request
    # renders in the new locale. An English "Preferences saved." on a page that
    # has just turned French reads as a page that half-worked.
    redirect_to you_account_path, notice: t("you.prefs_saved", locale: locale)
  end

  # One Verto in the account: the answers they gave, next to everyone else's.
  #
  # :id is a survey id, and it is not a capability — the lookup runs through
  # this player's own claims, so another account's Verto is indistinguishable
  # from one that does not exist.
  def verto
    @claims = kept_claims.select { |c| c.survey_id.to_s == params[:id].to_s }
    return redirect_to you_path, alert: t("you.not_found") if @claims.empty?

    @survey = @claims.first.survey
    # The run their answers come from. Newest, because a retake is what they
    # think now; the piles below still count every run they kept.
    @answered  = @claims.map(&:response).max_by { |r| r.completed_at || r.created_at }
    @piles     = piles_for(@survey, @claims)
    @standing  = standing_for(@survey, @claims)
    @comparison = comparison_for(@survey, @answered)
    @follow_ups = @survey.follow_up_surveys
  end

  # The wallet: one row per Verto, and one number that spans them.
  #
  # The rows are the purse's, so the pill's total and this page's total are one
  # computation and cannot disagree; the standing is added here and only here,
  # because it costs a query per row and the pill has no use for it.
  def wallet
    @rows = @purse_rows.map do |row|
      row.merge(standing: standing_for(row[:survey], row[:claims]))
    end
    @total = @purse_total
    @organisations = @rows.map { |row| row[:survey].organisation_id }.uniq.size
  end

  def sign_out
    terminate_player_session
    redirect_to you_path, notice: t("you.signed_out")
  end

  # Self-service erasure. The account, its sessions, its outstanding links and
  # its claims — never the pseudonymous Response rows, which are the creator's
  # research data and are not this person's to delete from here. See
  # docs/DATA_RETENTION.md.
  def destroy
    player = current_player
    terminate_player_session
    player.destroy
    redirect_to you_path, notice: t("you.deleted")
  end

  private

  def own_top_bar
    @own_top_bar = true
  end

  # What the settings page shows, loaded by #account and again by the one
  # action that re-renders it instead of redirecting.
  def load_account
    @player        = current_player
    @organisations = held_organisations
    @unsubscribed  = PlayerEmailPreference.where(player_id: current_player.id)
                                          .pluck(:organisation_id).to_set
    @has_password  = current_player.password_digest.present?
    @google        = current_player.player_identities.exists?(provider: GOOGLE_PROVIDER)
    @confirm       = confirmation_state
  end

  # Whether to ask this person to confirm their address, and how:
  #
  #   nil      — nothing to ask: confirmed already, or this deployment has no
  #              working mail, in which case a "send me the link" button would
  #              be a button that silently does nothing.
  #   :pending — unconfirmed and a link can be sent.
  #   :blocked — the address is on the suppression list (it bounced, or they
  #              turned mail off), so no link will be sent and the page says
  #              why instead of offering one.
  def confirmation_state
    return nil if !player_signed_in? || current_player.email_verified?
    return :blocked if PlayerEmailConfirmationsController.suppressed?(current_player)

    MailConfigCheck.deliverable? ? :pending : nil
  end

  # The organisations whose mail the account can switch off: the ones it holds
  # a Verto from, in the order the Vertos are listed, so the toggles read in
  # the order the dashboard does.
  def held_organisations
    kept_claims.map { |c| c.survey.organisation }.uniq
  end

  # One row per Verto, newest-played first. group_by preserves first-seen
  # order, and kept_claims is already sorted, so the row order is the claim
  # order and the newest claim is the first in each group.
  def verto_rows(claims)
    claims.group_by(&:survey_id).map do |_id, group|
      survey = group.first.survey
      { survey: survey, claims: group, played_at: played_at(group.first),
        piles: piles_for(survey, group) }
    end
  end

  # How many people have answered each listed Verto, in one grouped COUNT for
  # the whole list rather than one per row: this runs on the page that lists
  # every Verto an account holds. Feeds the comparison gate AND the card's
  # own "N answered" line, which is why it is computed once and handed to both.
  def answered_counts(claims)
    ids = claims.map(&:survey_id).uniq
    return {} if ids.empty?

    Response.where(survey_id: ids, answered: true).group(:survey_id).count
  end

  # The creator card's own count (surveys/_dashboard_card), so the number a
  # respondent sees is the number the creator sees.
  def question_count(survey)
    Array(survey.cards).count { |c| CardTypes.question?(c["type"]) }
  end

  def tiles_for(rows)
    { vertos:       rows.size,
      results_open: rows.count { |row| @compare[row[:survey].id] == :ready },
      impact:       rows.count { |row| row[:survey].impact_published? || row[:survey].next_step? },
      collected:    @purse_total }
  end

  # The follow-ups, as one list. The reason is still carried on each entry —
  # the Verto that pointed — and when two Vertos point at the same one the
  # first row's reason wins, because that is the one they played most recently.
  def next_for(rows)
    seen = Set.new
    rows.flat_map do |row|
      @follow_ups[row[:survey].id].filter_map do |next_verto|
        next unless seen.add?(next_verto.id)

        { survey: next_verto, because: row[:survey] }
      end
    end
  end

  # What came of their answers: the Vertos with an impact written, then the
  # ones with only a promise of one. Published first because it is the thing
  # the address was left for; a promise is worth listing, but after.
  def impacts_for(rows)
    published, rest = rows.partition { |row| row[:survey].impact_published? }
    promised = rest.select { |row| row[:survey].next_step? }
    published.map { |row| impact_entry(row, :impact) } +
      promised.map { |row| impact_entry(row, :next_step) }
  end

  def impact_entry(row, kind)
    { survey: row[:survey], kind: kind, answered: @answered[row[:survey].id].to_i }
  end

  # Why each listed Verto can't be compared yet — said on the LIST, so nobody
  # has to open a Verto to find out there is nothing to see in it. Two gates,
  # and a respondent has no way to tell them apart from the outside:
  #
  #   :closed  — show_results_comparison is the creator's switch and defaults
  #              to false, so this is the commonest answer by a distance.
  #   { have: } — under MIN_REGION_SAMPLE_SIZE. Deliberately says the floor and
  #              the count rather than "not enough yet": a respondent who can
  #              see it is 2 of 5 knows to come back, and one who is told
  #              "soon" learns nothing and asks support instead.
  #   :ready   — nothing is drawn. The row already links to the comparison.
  #
  # `answered` is answered_counts' hash, passed in rather than computed here
  # so the dashboard's one grouped COUNT serves this and the card's own line.
  def comparison_availability(claims, answered = answered_counts(claims))
    surveys = claims.map(&:survey).uniq

    surveys.each_with_object({}) do |survey, out|
      out[survey.id] =
        if !survey.compare_results?
          :closed
        elsif answered[survey.id].to_i < Response::MIN_REGION_SAMPLE_SIZE
          { have: answered[survey.id].to_i }
        else
          :ready
        end
    end
  end

  # What each listed Verto points at next, keyed by survey id and empty for most
  # of them. There is no feed and no ranking anywhere in this: the only fact the
  # app has about a respondent is which Verto they played, so that fact IS the
  # reason a follow-up is shown, and it is shown ON the Verto that carries it
  # rather than in a merged list where the reason would have to be re-stated.
  #
  # Survey#follow_up_surveys runs a query PER survey (it scopes through
  # organisation.surveys), which is one query per row on the page that lists
  # every Verto an account holds. Resolved here in one, preserving what that
  # method guarantees: the creator's own order, only playable Vertos, and only
  # ones belonging to the same organisation — a follow-up id pointing outside
  # the org is not a follow-up, it is a stale id.
  # A Verto already in the account is never suggested — carried over from the
  # page this replaces, and the one piece of its logic that had nothing to do
  # with being a merged list. "What's next" pointing at something sitting three
  # rows below it is the suggestion reading as an accident.
  def follow_ups_for(claims)
    surveys = claims.map(&:survey).uniq
    held    = surveys.map(&:id).to_set
    wanted  = surveys.to_h do |s|
      [ s.id, Array(s.follow_up_survey_ids).filter_map { |v| Integer(v, exception: false) } ]
    end
    ids = wanted.values.flatten.uniq - held.to_a
    return surveys.to_h { |s| [ s.id, [] ] } if ids.empty?

    found = Survey.kept.where(id: ids).includes(:organisation).index_by(&:id)
    surveys.to_h do |survey|
      rows = wanted[survey.id].filter_map do |id|
        other = found[id]
        next if other.nil? || other.organisation_id != survey.organisation_id || !other.playable?

        other
      end
      [ survey.id, rows ]
    end
  end

  # What the account has collected, on every page rather than only the wallet:
  # the pill in the corner carries the total everywhere, and its hover
  # breakdown carries the first PURSE_PREVIEW rows.
  #
  # Built from the same rows the wallet renders, deliberately. A pill showing a
  # number the page behind it doesn't agree with is worse than no pill.
  def set_purse
    @purse_rows  = token_rows
    @purse_total = @purse_rows.sum { |row| row[:piles].sum { |p| p[:amount] } }
  end

  # One row per Verto that awarded anything, newest-answered first.
  #
  # group_by preserves first-seen order, so the rows keep kept_claims' own
  # ordering. A Verto that awarded nothing is not a row: an empty pile is not a
  # holding, and listing it would pad the wallet with Vertos that have nothing
  # to show.
  def token_rows
    kept_claims.group_by(&:survey_id).filter_map do |_id, claims|
      survey = claims.first.survey
      piles  = piles_for(survey, claims)
      next if piles.empty?

      { survey: survey, claims: claims, piles: piles }
    end
  end

  # Every Verto this account holds, newest first, minus the ones whose Verto has
  # been deleted since. Shared by every page and by the pill in the corner, so
  # they can never disagree about what the account contains — the header saying
  # "3" and the list showing 2 is the one thing that would make a respondent
  # trust neither.
  #
  # Memoised because the purse now needs it on every action alongside whatever
  # the action itself wanted, and it is the page's one real query.
  def kept_claims
    @kept_claims ||=
      if player_signed_in?
        current_player.player_claims
                      .includes(:response, survey: :organisation)
                      .newest_first
                      .reject { |c| c.survey.nil? || c.survey.deleted_at.present? }
                      .sort_by { |c| -played_at(c).to_i }
      else
        []
      end
  end

  # Ordered by when they ANSWERED, not when the claim was written — both pages
  # show the played date, and a device key can attach a Verto from March to an
  # account today, which under claimed_at order puts an old Verto at the top of
  # a list displaying an old date. It also makes the order deterministic when
  # several Vertos are claimed by one sign-in, which is the ordinary case: they
  # all share a claimed_at to the microsecond.
  def played_at(claim)
    claim.response.completed_at || claim.response.created_at || claim.claimed_at
  end

  # What they collected on ONE Verto, built inside that Verto's own row and
  # never merged with another's.
  #
  # Token ids are not unique across Vertos: Survey#duplicate! copies
  # token_types verbatim and sanitize_token_types passes creator-supplied ids
  # straight through, so two Vertos routinely both use "gold" for two entirely
  # different things. The key is therefore (survey_id, token_id) — expressed
  # here by only ever summing within one survey's claims and reading the names
  # and icons off that survey's own token_types.
  #
  # The amounts come from responses.token_totals, which is a stored column
  # written when the run was saved. That makes a pile a SNAPSHOT of what they
  # collected, not a live recomputation: a creator who re-tunes their awards
  # next month changes what future respondents earn, not what this person did.
  # (The rank below is the opposite, and deliberately — see standing_for.)
  def piles_for(survey, claims)
    collected = Hash.new(0)
    claims.each do |claim|
      claim.response.token_totals.to_h.each { |id, n| collected[id.to_s] += n.to_i }
    end

    Array(survey.token_types).filter_map do |type|
      amount = collected[type["id"].to_s]
      next if amount.zero?

      { id: type["id"], icon: type["icon"], name: type["name"], amount: amount }
    end
  end

  # Where they stand on that Verto's own board, wearing that Verto's own
  # anonymous name — per-Verto and un-merged, including the fact that the name
  # differs from one Verto to the next. There is no cross-Verto ranking
  # anywhere in this account: award sizes are a creator's free choice, so a
  # league table across Vertos would only measure whose Verto you happened to
  # play.
  #
  # nil in three ordinary cases, all of which the page simply renders without:
  # the Verto has no board, the run carries no durable identity (the account
  # writes none — see PlayerController#join — so this is only ever a digest the
  # player itself minted while a board was on), or the board has not caught up
  # with them yet.
  #
  # Unlike the piles, a rank is LIVE, and has to be: it describes a population
  # that is still answering, and a frozen one would be wrong by morning.
  def standing_for(survey, claims)
    return nil unless survey.leaderboard_active?

    digest = claims.filter_map { |c| c.response.player_key_digest }.first
    return nil if digest.nil?

    entry = TokenLeaderboard.entry_for_digest(survey, digest)
    return nil if entry.nil?

    total = survey.leaderboard_standings.count
    total += 1 unless survey.leaderboard_standings.exists?(key_digest: digest)
    { name: PlayerAlias.ensure_for!(survey: survey, key_digest: digest).anon_name,
      rank: LeaderboardStanding.rank_of(survey, total: entry[:total],
                                        achieved_at: entry[:achieved_at], key_digest: digest),
      of:   total }
  end

  # Their answers next to everyone else's — the same rows the player draws at
  # the end of the Verto, off the same cached payload, so opening this page
  # right after finishing costs nothing and shows the same numbers.
  #
  # Three states, and the two that show less are not error cases:
  #
  #   :off        — show_results_comparison is the creator's switch and stays
  #                 theirs. The account keeps the Verto either way; it just has
  #                 less to show. Read off the SURVEY rather than through
  #                 play_settings: a SurveyLink's override is about the cohort
  #                 that link was sent to, and there is no link here.
  #   :suppressed — under MIN_REGION_SAMPLE_SIZE the whole payload is refused,
  #                 exactly as #results refuses it. On a Verto with one or two
  #                 responders the "comparison" IS the other respondent's
  #                 answers. An account must not become a way around that.
  #   :rows       — a row per question, with their own answer marked.
  def comparison_for(survey, response)
    return { state: :off } unless survey.compare_results?

    payload = cached_survey_aggregate(:results, survey) do
      responses = survey.responses.where(answered: true)
      total     = responses.count
      if total < Response::MIN_REGION_SAMPLE_SIZE
        { suppressed: true, total_responses: total, results: [] }
      else
        { total_responses: total, results: aggregate_rows(survey, responses) }
      end
    end

    return { state: :suppressed, total: payload[:total_responses] } if payload[:suppressed]

    { state: :rows, total: payload[:total_responses],
      rows: comparison_rows(payload[:results], response) }
  end

  # Pair each aggregated card with what THIS person said. Rows the account can
  # draw a fair bar for are the option-shaped ones; for the rest — a written
  # answer, a rating, a ranking — their own answer is shown without a
  # distribution rather than with a chart that means something else.
  def comparison_rows(results, response)
    answers = response.answers.to_h
    Array(results).filter_map do |row|
      mine = answers[row[:index].to_s]
      mine = mine["value"] if mine.is_a?(Hash)
      next if mine.nil? || mine == "" || mine == false

      options = Array(row[:options])
      counts  = row[:counts].to_h
      total   = row[:total].to_i
      bars = if options.any? && total.positive?
        options.map do |option|
          n = counts[option].to_i
          { label: option, pct: (n * 100.0 / total).round,
            mine: Array(mine).map(&:to_s).include?(option.to_s) }
        end
      else
        []
      end

      { prompt: row[:prompt], mine: Array(mine).join(", "), bars: bars }
    end
  end

  # aggregate_rows lives on PlayerController and carries the tap-card scale the
  # client needs; here the rows are rendered server-side and only the option
  # tallies are used, so this is the same shape without that extra.
  def aggregate_rows(survey, responses)
    aggregate_results(Array(survey.cards), responses).map.with_index do |row, idx|
      { index: idx, type: row[:type],
        prompt: row[:card]["text"] || row[:card]["prompt"] || row[:card]["title"],
        options: row[:card]["options"], total: row[:total], counts: row[:counts] }
    end
  end

  # A page listing what one person has answered must not be written to a
  # shared browser's disk cache. Same header Comms::TrackingController sets.
  def no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
