class PlayerController < ApplicationController
  # ActiveStorage::Current.url_options for PlayerAssetUrls: a blob's own URL on
  # the Disk service (dev/test, or a fallback) is built from the request's host.
  include ActiveStorage::SetCurrent

  include AggregatesSurveyResults
  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  protect_from_forgery with: :null_session, only: [ :submit, :progress, :recall, :eligibility, :leaderboard, :join, :join_google ]

  # Public, unauthenticated write endpoints — cap per-IP request rate so one
  # source can't flood responses (results poisoning / storage abuse). Limits are
  # deliberately high: a real respondent sends one submit and a handful of
  # progress pings, but many respondents can legitimately share one public IP
  # (event/venue Wi‑Fi behind NAT), so these only stop pathological floods.
  # Raise them if you run large single-IP events. No-op in test (null cache).
  #
  # PLAYER_RATE_LIMIT_SCALE multiplies the respondent-path caps (submit,
  # progress, consent, aggregate reads) in lockstep, read once at boot. Two
  # legitimate uses: the k6 load test, whose whole burst arrives from a
  # handful of runner IPs, and a real single-IP event (a venue NATing
  # hundreds of respondents behind one address). Recall and eligibility are
  # deliberately NOT scaled — they are code-guessing oracles bounded for
  # privacy, not part of a bigger crowd's legitimate traffic.
  #
  # location_search USED to be in that list, on the grounds that it "spends
  # LocationIQ quota". It has its own lever now, and the reason that sentence
  # was wrong is worth keeping: NominatimClient reads its day-long cache
  # BEFORE it checks the outbound budget, so a repeated search term makes no
  # API call at all. Requests-per-IP and API-calls-per-app are two different
  # numbers, and only the second is what the provider's policy is about —
  # GEOCODE_MAX_RPS still bounds it, untouched. See LOCATION_RATE_LIMIT_SCALE.
  #
  # Every declaration carries a distinct `name:` because Rails keys the
  # counter on ["rate-limit", controller_path, name, ip] — with no name,
  # every rate_limit in one controller shares a SINGLE counter, so ordinary
  # page traffic from a shared IP burned the consent budget (30/min) for
  # everyone behind it. The k6 baseline caught this: successes per endpoint
  # decayed in journey order (consent 32, submit 18, leaderboard 0) as one
  # counter climbed past each declaration's limit in turn.
  RATE_LIMIT_SCALE = ENV.fetch("PLAYER_RATE_LIMIT_SCALE", "1").to_i.clamp(1, 100_000)
  rate_limit to: 60 * RATE_LIMIT_SCALE, within: 1.minute, only: :submit, name: "submit",
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  rate_limit to: 300 * RATE_LIMIT_SCALE, within: 1.minute, only: [ :progress, :grade ], name: "progress",
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # Public read endpoints that aggregate over the whole response set — cap them
  # too, so they can't be hammered as a memory-amplification vector. Generous:
  # a respondent hits each once after finishing.
  rate_limit to: 120 * RATE_LIMIT_SCALE, within: 1.minute, only: [ :results, :scores, :regions, :leaderboard ], name: "reads",
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # Consent is written at most twice per legitimate session (a decline, or a
  # decline followed by an explicit re-agree), and declining PURGES the
  # response — so an uncapped endpoint was an unauthenticated, repeatable
  # destruction primitive keyed only by a session token.
  rate_limit to: 30 * RATE_LIMIT_SCALE, within: 1.minute, only: :consent, name: "consent",
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # Recall is the one endpoint here that can return ANOTHER person's answers,
  # and the key to it is a code chosen to be memorable — which is to say
  # guessable. A real respondent calls this once, maybe twice after a typo, so
  # the per-IP cap is deliberately far below anything legitimate. Two further
  # budgets in #recall_budget_ok? bound the thing this cap cannot see: how many
  # DISTINCT codes one caller tries, and how often one code is tried from
  # anywhere. Eligibility (No retests) answers one bit about a code and is
  # capped the same way for the same reason.
  rate_limit to: 10, within: 1.minute, only: [ :recall, :eligibility ], name: "recall",
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # A respondent's autocomplete keystrokes are debounced client-side, so a
  # generous per-minute cap here only guards against a runaway client/bot.
  #
  # PLAYER_LOCATION_RATE_LIMIT_SCALE multiplies it, and is its own lever rather
  # than part of PLAYER_RATE_LIMIT_SCALE for the reason above: this cap counts
  # REQUESTS, and the thing worth protecting is outbound API CALLS. A rate_limit
  # is a before_action, so it fires before #location_search reaches
  # NominatimClient — which means a term already in the day-long cache, costing
  # the provider nothing, is refused anyway once the minute's budget is spent.
  #
  # Measured against the case that found it: 250 people in one room, on one
  # venue NAT address, each typing a city into the last card of twelve. Three
  # debounced searches apiece is ~250 requests a minute against a cap of 30 —
  # and they are overwhelmingly the SAME few city names, so nearly all of them
  # would have been cache hits. The cap was turning free lookups away.
  #
  # What a refusal looks like is why this matters more than the numbers: the
  # 429 body has no `results` key, and location_search_controller.js does
  # `Array.isArray(data.results) ? data.results : []` and then clears the list.
  # So a throttled respondent sees an ordinary search box that simply never
  # suggests anything — no error, no explanation — and since _pick is the only
  # thing that writes an answer, they record no location at all.
  LOCATION_RATE_LIMIT_SCALE = ENV.fetch("PLAYER_LOCATION_RATE_LIMIT_SCALE", "1").to_i.clamp(1, 10_000)
  rate_limit to: 30 * LOCATION_RATE_LIMIT_SCALE, within: 1.minute, only: :location_search, name: "location_search",
             with: -> { render json: { ok: false, error: "Too many requests — please slow down." }, status: :too_many_requests }
  # Join is capped twice, in the SessionsController shape: the per-IP limit
  # stops one machine walking a list of addresses, and the per-address limit
  # stops a rotating pool of IPs grinding at ONE account, which the per-IP
  # limit alone never sees. #join_budget_ok? adds the two hourly budgets a
  # per-minute cap cannot express.
  #
  # What these caps bound is ACCOUNT CREATION. #join mints a PlayerSignInLink
  # with ORIGIN_SIGNUP and returns its path for an in-browser redirect; the
  # link itself is never mailed. That is why the per-IP half of these caps can
  # be scaled for a room full of people.
  #
  # #join DOES send one mail — the address confirmation, on the branches that
  # create an account (see #send_join_confirmation) — and that mail is NOT
  # bounded by these caps. It has its own flat counter,
  # MAX_JOIN_CONFIRMATIONS_PER_IP, precisely so that raising the lever below
  # for an event never raises how many strangers one machine may write to.
  # This comment has been wrong about mail here twice already; if #join ever
  # sends anything else, the unscaled counter is the thing to extend, not
  # these.
  #
  # PLAYER_JOIN_RATE_LIMIT_SCALE multiplies the PER-IP gates only: this one,
  # join_google_ip, and MAX_JOIN_ADDRESSES_PER_IP. The address-keyed limit
  # below and MAX_JOIN_PER_ADDRESS are deliberately left alone — they are what
  # still bounds one account, and a bigger crowd is not a reason to let one
  # address be hammered harder.
  #
  # It is a SEPARATE lever from PLAYER_RATE_LIMIT_SCALE rather than a reuse of
  # it, because the two say different things: that one is a statement about how
  # many people are answering from behind one NAT address, this one about how
  # many accounts may be created from it. A load test wants the first and not
  # the second; a venue event wants both. Folding them together would have
  # meant every load run quietly raising the account cap too.
  #
  # Sized against the event that found this: 250 respondents on one venue NAT,
  # of whom 30 could create an account in the first hour — and the first ten in
  # any five minutes did so before the rest started failing SILENTLY, because
  # the refusal below is a success's body. At the default of 1 every number
  # here is exactly what it has always been.
  JOIN_RATE_LIMIT_SCALE = ENV.fetch("PLAYER_JOIN_RATE_LIMIT_SCALE", "1").to_i.clamp(1, 10_000)
  #
  # Refusal is `ok: true`, the same body a success returns: a 429 here would
  # tell a caller which addresses they had already spent (see #join).
  rate_limit to: 10 * JOIN_RATE_LIMIT_SCALE, within: 5.minutes, only: :join, name: "join_ip",
             with: -> { render json: { ok: true } }
  rate_limit to: 5, within: 20.minutes, only: :join, name: "join_email",
             by:   -> { "join_email:#{params[:email].to_s.strip.downcase}" },
             with: -> { render json: { ok: true } }
  # Continue with Google has no address in it, so there is nothing to hide and
  # it refuses plainly rather than in a success's clothing. It mints a row per
  # call, which is the thing being capped; the second budget #join needs — one
  # account, many IPs — has no meaning here, because the address comes from
  # Google rather than from the form. Scaled for the same reason as join_ip:
  # it is per-IP, and a venue full of people tapping "Continue with Google" is
  # the same crowd arriving through a different door.
  rate_limit to: 15 * JOIN_RATE_LIMIT_SCALE, within: 5.minutes, only: :join_google, name: "join_google_ip",
             with: -> { render json: { ok: false, error: "too_many" }, status: :too_many_requests }

  # How many respondent-facing Claude calls may be in flight in this process.
  # Rate limiting above bounds requests per IP; this bounds concurrency, which
  # is the thing that actually exhausts a 3-thread pool — and it has to, because
  # respondents behind one venue's NAT are legitimate traffic the caps let past.
  #
  # A separate pool from LimitsConcurrentStreams::POOL by design: that one is
  # sized for creator report streams, and sharing it would let a creator
  # watching a report write itself turn away a respondent mid-quiz, or the
  # reverse. Same formula (leave two threads for ordinary requests), tunable on
  # its own so respondent and creator AI can be balanced independently.
  AI_GRADE_POOL = SlotPool.new(
    # An explicit AI_GRADE_SLOTS=0 means OFF — it's the event-day degrade
    # switch, so it must actually degrade (the old [n, 1].max floor quietly
    # kept one slot per process alive). Only the derived default is floored.
    ENV["AI_GRADE_SLOTS"].presence&.to_i&.clamp(0, 64) ||
      [ Integer(ENV.fetch("RAILS_MAX_THREADS", 3)) - 2, 1 ].max
  )

  # Respondents don't pick their browser the way a creator does — they open a
  # link on whatever phone they already own, often an older Android or an iPhone
  # that stopped getting iOS updates. ApplicationController's
  # `allow_browser versions: :modern` (Safari 17.2+, Chrome 120+, Firefox 121+)
  # is a fair bar for the creator studio, but applying it here served a stock
  # "browser not supported" 406 instead of the Verto — which reads to the
  # respondent, and to the creator chasing a low response rate, as a dead link.
  #
  # The floor below is what the player ACTUALLY needs: import-map support. Below
  # that no player JS loads at all and the page is inert, so blocking is honest.
  # Above it, everything else only degrades — a Chrome 89-110 respondent misses
  # some color-mix()/@property styling and still answers every question, which
  # beats being turned away. Gate on what breaks the page, not on what makes it
  # prettiest.
  #
  # Rails registers allow_browser as an anonymous before_action lambda, so there
  # is no callback name to skip_before_action; overriding the private method that
  # lambda calls is how you re-point it at a different version set.
  PLAYER_BROWSER_VERSIONS = {
    safari: 16.4, chrome: 89, firefox: 108, opera: 76, ie: false
  }.freeze

  # A Verto is meant to be embedded — in a partner's page, in a one-pager sent
  # as an HTML file (public/vertonow.html). The app-wide policy's
  # `frame-ancestors 'self'` blocks both, and 'self' is the only reason the
  # one-pager's laptop mockup couldn't hold the real thing.
  #
  # `file:` is what makes a downloaded copy work: a local page's origin is
  # opaque, and Chrome matches it against neither 'self' nor even `*` — only a
  # `file:` scheme source. Deliberately NOT `*`: this grants the app's own
  # origin and locally-opened files, so no website gains the ability to frame a
  # Verto. X-Frame-Options has to go with it, since Rails' default SAMEORIGIN
  # would block a file:// parent on its own whatever the CSP says.
  #
  # Set as a plain response header rather than through the
  # `content_security_policy` macro — see config/initializers/blazer.rb: that
  # macro shallow-clones and mutates the shared global policy, leaking the
  # relaxation into every other response in the process.
  after_action :allow_embedding, only: %i[ show test_show live_test_show ]

  # live_test_show is deliberately NOT excepted: it is reached by an ordinary
  # play address, so it must resolve through exactly the same four-way lookup
  # (share token / link slug / publish token / vanity slug) that #show uses.
  before_action :load_survey_and_share, except: :test_show
  # A tester opening a shared link is read-only traffic; aligned with the
  # other public read endpoints above.
  rate_limit to: 120, within: 1.minute, only: %i[ test_show live_test_show ], name: "test_show"

  # GET /test/:token — Test Mode. The exact respondent experience (drafts
  # included) with every recording endpoint blanked, shareable without
  # sign-in. Reuses the owner-preview machinery in player/show.html.erb:
  # @preview blanks progress/submit/consent, and @test_mode additionally
  # blanks the play token itself so no results/regions/quiz URL leaks a live
  # endpoint to an unauthenticated tester.
  def test_show
    @survey = Survey.without_report_text.find_by(test_token: params[:token])
    return render :unavailable, status: :not_found unless @survey
    if @survey.deleted?
      @oops_gone = true
      return render :unavailable, status: :gone
    end
    @preview   = true
    @test_mode = true
    @display_locale = resolve_play_locale
    render_with_chrome_language
  end

  # GET /test/live/:token — Test Mode entered from a live play link, by whoever
  # is holding it: a facilitator demoing the Verto at an event, a creator
  # checking it on a real phone, a partner walking a funder through it. Reached
  # only through the player's hidden press-and-hold hatch (or by pasting this
  # URL), never by an ordinary respondent stumbling into it.
  #
  # Records nothing, by exactly the same mechanism as #test_show rather than by
  # a second one: @preview blanks progress/submit/consent, and @test_mode blanks
  # the play token itself, which kills the whole results/regions/quiz/leaderboard
  # /share URL family at its source (see player/show.html.erb). There is no
  # "test response" to filter out anywhere downstream because no write endpoint
  # reaches this page at all.
  #
  # @live_test is the one thing this does that #test_show doesn't: it means "we
  # got here from a real play link", which is what lets the banner offer a way
  # back to it. params[:token] IS that link, so the exit is exact.
  def live_test_show
    return render :unavailable, status: :not_found unless @survey
    if @survey.deleted?
      @oops_gone = true
      return render :unavailable, status: :gone
    end
    # Only a live Verto has a real run to opt out of. A draft or an unpublished
    # one is the creator's own /test/:token case, not this one.
    return render :unavailable, status: :gone unless @survey.published?
    @preview   = true
    @test_mode = true
    @live_test = true
    @display_locale = resolve_play_locale
    # No @pwa_manifest_url on purpose — same reasoning as #show's note below:
    # this route is outside the service worker's scope, so there is nothing here
    # to install.
    render_with_chrome_language
  end

  def show
    # A token that resolves nothing is almost always a link shared before the
    # Verto was published (or a typo) — a respondent dead-end either way, so
    # serve a branded explainer instead of a bare error string.
    return render :unavailable, status: :not_found unless @survey
    if @survey.deleted?
      @oops_gone = true
      return render :unavailable, status: :gone
    end
    # Unpublished by the creator. The link itself is real and may well come back
    # (unpublishing keeps publish_token so re-publishing restores it), so this is
    # a 410 rather than a 404 — but the "not published yet" copy is the accurate
    # explanation for a respondent, not the archived-forever one.
    return render :unavailable, status: :gone unless @survey.published?
    @display_locale = resolve_play_locale
    # Not set for test_show or the owner's dashboard preview (SurveysController's
    # own action) — the studio's own /manifest keeps serving those, matching the
    # design note that /test is outside the service worker's /play/ scope in the
    # first place. Reuses whatever token got here (share/link slug/publish
    # token/vanity slug all resolved through load_survey_and_share already),
    # so the manifest's start_url is the exact link this respondent is on.
    @pwa_manifest_url = play_manifest_path(params[:token])
    # The player HTML is the same bytes for every respondent on this link +
    # resolved locale (a JS shell that fetches all respondent data from the JSON
    # endpoints), and rendering its ~150 KB is the single most expensive request
    # in a burst — ~45% of a journey's CPU. Serve it from cache. See
    # cached_play_page for the key and the freshness/stampede discipline.
    render html: cached_play_page.html_safe
  end

  # GET /play/:token/manifest — a per-Verto install manifest, so "Add to Home
  # Screen" offers the Verto's own name and icon rather than "Verto Studio".
  # The service worker is already scoped to /play/ (sw_register.js) and every
  # installability prerequisite it needs — a controlling SW, a 512px icon,
  # standalone display — is already met; this fills in the one missing piece,
  # a manifest that isn't the studio's. No worker BEHAVIOUR changes here, so
  # no CACHE_VERSION bump: this GET flows through the SW's existing
  # network-first handler exactly like any other same-origin request.
  def manifest
    return head :not_found unless @survey&.published? && !@survey.deleted?

    name = @survey.theme.presence || @survey.title.presence || "Playverto"
    render json: {
      name:             name,
      short_name:       name.truncate(20, omission: "…"),
      description:      "#{name} · Playverto",
      icons: [
        { src: "/icon.png", type: "image/png", sizes: "512x512" },
        { src: "/icon.png", type: "image/png", sizes: "512x512", purpose: "maskable" }
      ],
      start_url:        play_survey_path(params[:token]),
      display:          "standalone",
      scope:             "/play/",
      theme_color:      BrandPalette.resolve(@survey.brand_palette)["bg"],
      background_color: "#1C2034"
    }
  end

  # Partial save while the player is mid-survey, so we can count people who
  # answered at least one question even if they never reach Submit. Idempotent
  # per session_token (a refresh reuses the token) and never downgrades a
  # response that has already been completed.
  def progress
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    return if refuse_if_declined(resp)
    # Quiz answers are immutable once committed — fold the incoming payload over
    # what's already stored so an already-answered graded card can't be changed.
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    apply_respondent_code(resp, data["respondent_code"])
    apply_player_key(resp, data["player_key"])
    return if refuse_if_retest(resp)
    apply_contact(data)
    sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    mark_started_unless_completed(resp)
    apply_quiz_score(resp)
    apply_token_totals(resp)
    save_with_hold!(resp)
    render json: { ok: true, session_token: token }
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    # 500, not 422: a transient fault (DB burp, mid-deploy restart) must look
    # RETRYABLE to the service worker, which queues 5xx and drops 4xx. As a 422
    # this told the respondent the Verto had closed and threw their answers
    # away, when a retry seconds later would have landed them.
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :internal_server_error
  end

  def submit
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    return if refuse_if_declined(resp)
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    apply_respondent_code(resp, data["respondent_code"])
    apply_player_key(resp, data["player_key"])
    return if refuse_if_retest(resp)
    apply_contact(data)
    sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    resp.status  = "completed"
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    # A respondent who never triggered /progress (a one-card Verto, or a submit
    # replayed from the offline queue after the page was closed) still needs a
    # start stamp, otherwise their duration is unmeasurable.
    stamp_started_metadata(resp)
    resp.completed_at ||= Time.current
    apply_quiz_score(resp)
    apply_token_totals(resp)
    save_with_hold!(resp)
    # Best-effort: have the finisher's anonymous name minted before the thank-you
    # screen fetches the board. A naming hiccup must never fail the write that
    # just stored the answers — #leaderboard's backfill names anyone missed.
    if @survey.leaderboard_active? && resp.player_key_digest.present?
      begin
        PlayerAlias.ensure_for!(survey: @survey, key_digest: resp.player_key_digest)
      rescue => e
        ErrorReporting.report("PlayerController#submit alias", e)
      end
    end
    payload = { ok: true }
    payload.merge!(score: resp.score, max: resp.quiz_max) if @survey.quiz?
    payload.merge!(token_totals: resp.token_totals) if @survey.tokenisation_enabled?
    render json: payload
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    # 500, not 422: a transient fault (DB burp, mid-deploy restart) must look
    # RETRYABLE to the service worker, which queues 5xx and drops 4xx. As a 422
    # this told the respondent the Verto had closed and threw their answers
    # away, when a retry seconds later would have landed them.
    render json: { ok: false, error: "Something went wrong saving your response." }, status: :internal_server_error
  end

  # Records the consent gate's agree/decline event, so there's an audit trail
  # of who consented and to what wording — previously agreeConsent()/
  # declineConsent() were pure client-side UI with nothing persisted. The
  # first event for a session wins (a retry/replay never overwrites an
  # already-recorded timestamp), and the snapshot ties the record to the exact
  # consent_text shown at that moment, immune to the creator editing it later.
  # POST /play/:token/recall
  #
  # Ask-once answers this respondent already gave under the code they just
  # typed — see RespondentRecall for what is and is not returned, and why.
  #
  # Every refusal returns the SAME body a successful-but-empty lookup does:
  # unknown code, blank code, recall switched off, budget spent. An endpoint
  # that distinguishes "no such code" from "that code has nothing" is an
  # endpoint that confirms codes.
  def recall
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?

    data   = JSON.parse(request.body.read)
    code   = data["respondent_code"]
    digest = @survey.respondent_code_active? ? @survey.respondent_code_digest(code) : nil

    answers = if digest && recall_budget_ok?(digest)
      RespondentRecall.new(@survey).answers_for(digest)
    else
      {}
    end

    render json: { ok: true, answers: answers }
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue => e
    # Deliberately generic: an exception message here could carry the code.
    ErrorReporting.report("PlayerController#recall", e)
    render json: { ok: true, answers: {} }
  end

  # POST /play/:token/eligibility
  #
  # Whether the code just typed may still take this Verto in the current wave
  # (Survey#retest_blocked?). Kept apart from /recall on purpose: recall must
  # never confirm a code, while the one bit this returns — "that code has a
  # COMPLETED run in the CURRENT wave" — is the whole point of No retests, and
  # the creator switches it on knowingly (the panel says so). Everything else
  # reads identically: unknown code, blank code, a code that finished only in
  # an earlier wave, a started-but-unfinished run, the flag off, the device
  # basis, a spent budget and any exception all answer `blocked: false`. Never
  # writes a row — the response built here is a probe for the wave stamp.
  def eligibility
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?

    data    = JSON.parse(request.body.read)
    blocked = false
    if @survey.retest_basis == "code"
      resp = find_or_init_response(data["session_token"].presence || SecureRandom.uuid)
      apply_respondent_code(resp, data["respondent_code"])
      digest  = resp.respondent_code_digest
      blocked = digest.present? &&
                code_budget_ok?("retest", digest, per_ip: MAX_RETEST_CODES_PER_IP, per_code: MAX_RETEST_PER_CODE) &&
                @survey.retest_blocked?(resp)
    end

    render json: { ok: true, blocked: blocked }
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    # Deliberately generic: an exception message here could carry the code.
    ErrorReporting.report("PlayerController#eligibility", e)
    render json: { ok: true, blocked: false }
  end

  def consent
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?

    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = find_or_init_response(token)
    mark_started_unless_completed(resp)
    if data["agreed"]
      resp.consent_agreed_at ||= Time.current
      resp.consent_text_snapshot ||= @survey.consent_snapshot_text
      # An explicit agree after a decline is a re-consent, and the record must
      # say ONE thing — both timestamps standing at once is an audit row nobody
      # can interpret. The purge already ran; nothing is resurrected by this.
      resp.consent_declined_at = nil
    else
      resp.consent_declined_at ||= Time.current
      resp.consent_text_snapshot ||= @survey.consent_snapshot_text
      # Declining means "do not collect my data" — so anything already collected
      # goes. Before this it was a timestamp and nothing more: answers given
      # before a mid-deck gate stayed stored, counted as a responder, and fed
      # the creator's and the public aggregates.
      resp.purge_for_declined_consent!
    end
    resp.save!
    render json: { ok: true }
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    # 500, not 422, for the same reason #submit does it: a transient fault must
    # look RETRYABLE to the service worker. Its queue drops non-retryable 4xx,
    # so a queued consent DECLINE that hit a hiccup here was silently discarded
    # — and the purge the respondent asked for never ran.
    render json: { ok: false, error: "Something went wrong recording your response." }, status: :internal_server_error
  end

  # Quiz: record + grade one card as the player advances, returning that card's
  # verdict so the player can reveal it. Doubles as the progress save for quizzes
  # (it records the whole payload, immutably for already-answered graded cards).
  # The correct answer is only ever revealed for a card the session has actually
  # committed an answer to — so it can't be peeked before answering.
  def grade
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    return render json: { ok: false, error: "Not a quiz" }, status: :forbidden unless @survey.quiz?

    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    idx   = data["card_index"].to_i
    resp  = find_or_init_response(token)
    return if refuse_if_declined(resp)
    first_time = !answered?(stored_answers(resp)[idx.to_s])
    resp.answers = locked_merge(stored_answers(resp), data["answers"] || {})
    # The code rides the grade payload like every other save; it used to be
    # dropped here, so a quiz that collected codes recorded none for a
    # respondent who never hit /progress.
    apply_respondent_code(resp, data["respondent_code"])
    apply_player_key(resp, data["player_key"])
    return if refuse_if_retest(resp)
    ai_normalize_open_ended_answer!(resp, idx) if first_time
    sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    resp.locale  = SupportedLocales.coerce(data["locale"]) if data["locale"].present?
    mark_started_unless_completed(resp)
    apply_quiz_score(resp)
    apply_token_totals(resp)
    save_with_hold!(resp)

    base = { ok: true, session_token: token, score: resp.score, max: resp.quiz_max }
    base[:token_totals] = resp.token_totals if @survey.tokenisation_enabled?
    card = Array(@survey.cards)[idx]
    stored = resp.answers[idx.to_s]
    if card && QuizGrading.graded?(card) && answered?(stored)
      render json: base.merge(
        graded: true,
        correct: QuizGrading.correct?(card, stored["value"]),
        # correct_answer stays CANONICAL (source-language) on purpose: the player
        # matches it against the stored option values to tint the right/wrong
        # picks, so a translated label here would break the reveal highlighting.
        # The explanation is free prose nobody compares against, so it can — and
        # should — come back in the respondent's language.
        correct_answer: QuizGrading.correct_display(card),
        explanation: localized_explanation(card, resp.locale)
      )
    else
      # Measurement card, unknown index, or no committed answer yet — record
      # only, reveal nothing.
      render json: base.merge(graded: false)
    end
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Something went wrong scoring your answer." }, status: :unprocessable_entity
  end

  # Quiz: the session's already-committed graded cards, so a reload re-locks and
  # re-reveals them (refresh-proof no-redo). Resolved by the client's session
  # token; these answers are already committed, so revealing them is safe.
  def quiz_state
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    return render json: { ok: true, quiz: false } unless @survey.quiz?

    token = params[:session_token].to_s
    resp  = token.present? ? @survey.responses.find_by(session_token: token) : nil
    answered = {}
    if resp
      Array(@survey.cards).each_with_index do |card, idx|
        next unless QuizGrading.graded?(card)
        ans = (resp.answers || {})[idx.to_s]
        next unless answered?(ans)
        answered[idx.to_s] = {
          value:          ans["value"],
          correct:        QuizGrading.correct?(card, ans["value"]),
          correct_answer: QuizGrading.correct_display(card),
          explanation:    card["explanation"].to_s
        }
      end
    end
    render json: { ok: true, quiz: true, score: resp&.score,
                   max: resp&.quiz_max || QuizGrading.graded_indices(@survey.cards).size,
                   answered: answered }
  end

  # Quiz: anonymous score distribution across completed responses, so a player
  # can see how they did versus everyone else (no identities — a histogram and
  # per-question correct-rate).
  def scores
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    return render json: { ok: false, error: "Not a quiz" }, status: :forbidden unless @survey.quiz?

    # Cached like #results: every finisher's score screen re-graded every
    # response per graded card per request; now the O(responses × graded)
    # pass runs at most once per cache window.
    payload = cached_aggregate(:scores) do
      max    = QuizGrading.graded_indices(@survey.cards).size
      graded = Array(@survey.cards).each_with_index.select { |card, _idx| QuizGrading.graded?(card) }

      # Small-cell suppression (P1-14), as on #results. A per-question
      # correct-rate over one other person is that person's answer sheet: "100%
      # got Q3 right" with a total of 1 says exactly what they scored.
      scored = @survey.responses.where(status: "completed").where.not(score: nil)
      if scored.count < Response::MIN_REGION_SAMPLE_SIZE
        { suppressed: true, total: scored.count, max: max,
          average: 0.0, distribution: [], per_question: [] }
      else
        # One batched pass: score histogram, total/average, and per-question
        # correct counts together — instead of loading every scored response
        # into memory and re-scanning the set once per graded card.
        dist        = Hash.new(0)
        correct_by  = Hash.new(0)
        total       = 0
        score_sum   = 0
        scored.select(:id, :score, :answers).find_each(batch_size: 500) do |r|
          total     += 1
          score_sum += r.score
          dist[r.score] += 1
          answers = r.answers || {}
          graded.each do |card, idx|
            correct_by[idx] += 1 if QuizGrading.correct?(card, answers[idx.to_s]&.dig("value"))
          end
        end
        avg = total.positive? ? (score_sum.to_f / total).round(1) : 0.0

        per_question = graded.map do |card, idx|
          { index: idx, prompt: card["text"], correct: correct_by[idx],
            pct: total.positive? ? (correct_by[idx] * 100.0 / total).round : 0 }
        end

        { total: total, max: max, average: avg,
          distribution: (0..max).map { |s| { score: s, count: dist[s] } },
          per_question: per_question }
      end
    end

    render json: { ok: true }.merge(payload)
  end

  # How many standings rows the board shows. "You" rides along even from
  # further down, with your true rank.
  LEADERBOARD_TOP = 10

  # The token leaderboard: identities ranked under the creator's retake policy,
  # wearing their system-made anonymous names. Enablement is enforced here, not
  # just by hiding the CTA (the #results posture), and the whole payload is
  # anonymous by construction — names and totals, no answers, no identities.
  def leaderboard
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    unless @survey.leaderboard_active?
      return render json: { ok: false, error: "Leaderboard not enabled" }, status: :forbidden
    end

    # The board is read from the precomputed LeaderboardStanding snapshot —
    # this endpoint auto-fires for every finisher, and recomputing standings
    # per request was O(total responses) per respondent. The snapshot trails
    # reality by RefreshLeaderboardStandingsJob's debounce (a few seconds).
    LeaderboardStanding.bootstrap!(@survey)
    top = @survey.leaderboard_standings.ranked.limit(LEADERBOARD_TOP).to_a
    total_players = @survey.leaderboard_standings.count
    # Rank is positional in `ranked` order — never stored, so a refresh only
    # ever touches the identities that changed.
    top_rank = top.each_with_index.to_h { |s, i| [ s.key_digest, i + 1 ] }

    # Resolve "you": the saved row's digest once this session has written, else
    # the raw key the client sent — a recognised returner opening a fresh
    # session (No retests' straight-to-board landing) has a key but no row yet.
    # POST now, GET while the deprecated route lives (see config/routes.rb).
    # Rails populates params from a JSON body anyway, so reading params covers
    # both — but read the body explicitly first so the intent survives the
    # day the GET goes and nobody has to work out where these came from.
    asked = leaderboard_request_params
    token = asked[:session_token].to_s
    resp  = token.present? ? @survey.responses.find_by(session_token: token) : nil
    you_digest = resp&.player_key_digest.presence || @survey.player_key_digest(asked[:player_key])
    you_row    = you_digest ? @survey.leaderboard_standings.find_by(key_digest: you_digest) : nil
    own        = you_digest ? TokenLeaderboard.entry_for_digest(@survey, you_digest) : nil

    # "You" is always computed live from YOUR rows (an indexed per-digest
    # query) — a finisher or retaker must never be shown a pre-refresh total
    # of their own. Only the board around you trails by the debounce window:
    # your rank comes from the snapshot when it already agrees, and is
    # estimated against it when you've beaten your own refresh here.
    # `total` is the basis the board ranks by (Survey#leaderboard_rank_by);
    # `totals` is every type's figure for the row's breakdown.
    you = if own
      total_players += 1 unless you_row
      rank = LeaderboardStanding.rank_of(@survey, total: own[:total],
                                         achieved_at: own[:achieved_at], key_digest: you_digest)
      { rank: rank, total: own[:total], totals: own[:totals], of: total_players }
    elsif you_row
      # Rows mid-purge but still on the snapshot — serve what the board shows.
      rank = LeaderboardStanding.rank_of(@survey, total: you_row.total,
                                         achieved_at: you_row.achieved_at, key_digest: you_digest)
      { rank: rank, total: you_row.total, totals: you_row.totals, of: total_players }
    end

    # Read-time backfill: name everyone about to be rendered (≤11 idempotent
    # finds). Submit already minted most of them; this covers identities from
    # before a mid-flight enable, and seeded rows.
    shown = top.map(&:key_digest)
    shown |= [ you_digest ] if you
    # One batched lookup first; mint only the names that are genuinely
    # missing. Submit already named nearly everyone, so in steady state this
    # is a single query — the load test counted 11 per-digest finds here on
    # every board read, a third of the endpoint's database round-trips.
    names   = @survey.player_aliases.where(key_digest: shown).pluck(:key_digest, :anon_name).to_h
    missing = shown - names.keys
    if missing.any?
      missing.each { |digest| PlayerAlias.ensure_for!(survey: @survey, key_digest: digest) }
      names = @survey.player_aliases.where(key_digest: shown).pluck(:key_digest, :anon_name).to_h
    end

    entries = top.map do |s|
      yours = s.key_digest == you_digest
      # Keep your own visible row coherent with the live "you" total when the
      # snapshot hasn't caught up with your latest run yet.
      { rank: top_rank[s.key_digest], name: names[s.key_digest],
        total: yours && you ? you[:total] : s.total,
        totals: yours && you ? you[:totals] : s.totals, you: yours }
    end
    you[:name] = names[you_digest] if you
    render json: { ok: true, policy: @survey.leaderboard_retake_policy,
                   rank_by: @survey.leaderboard_rank_by,
                   total_players:, entries:, you: }
  end

  # POST /play/:token/join
  #
  # The respondent asks for an account at the end of a Verto. This action
  # resolves what the person is entitled to claim, parks that on a
  # PlayerSignInLink and hands the link straight back; the claims themselves
  # are written by PlayerSignInsController#create when the browser follows it.
  #
  # When it creates an account it also queues one mail: the address
  # confirmation (PlayerEmailConfirmationsController). Nothing waits on it —
  # the person is signed in either way — but until it is followed the address
  # is unproven, and PlayerAudience will not write to it.
  #
  # It is cookie-free by construction and has to stay that way. `:join` is in
  # the null_session list above (player_controller.js sends no CSRF token on
  # any fetch, so without it every join is a 422), which means Rails swaps in a
  # NullCookieJar whose `write` is a no-op and whose read set is empty. There
  # is no configuration in which this action can set or read
  # player_session_id — which is fine, because the link is what starts the
  # session. The embed case says the same thing independently: a Verto is
  # routinely framed by a third party (see allow_embedding), where a
  # SameSite=Lax cookie is never sent on a subresource POST anyway.
  #
  # And no digest is ever written here. ResultsExport#alias_names mints a
  # PlayerAlias for every non-nil player_key_digest with no feature gate, so a
  # digest written only for joiners would label opt-in status in the creator's
  # CSV; LeaderboardStanding.completed_identities would then build a board out
  # of joiners alone. The run just finished is claimed by session_token, which
  # every response already has.
  #
  # THE ORACLE PROPERTY IS GONE, deliberately and on the owner's instruction
  # (2026-09-10). This endpoint used to answer identically for every refusal so
  # that it could never confirm whether an address was already known. A
  # password cannot work that way: "we made you an account" and "that is not
  # your password" are different outcomes and the person has to be told which.
  # Creator signup has always leaked the same fact, so the app is at least
  # consistent — but the property was real and this is what replaced it.
  #
  # That makes join_budget_ok? load-bearing in a way it was not before: it is
  # now the brute-force bound on a password field, not just a mail-volume cap.
  #
  # No session is started HERE. This action runs under protect_from_forgery
  # with: :null_session (the player page is cached by the service worker, so
  # its CSRF token can be arbitrarily stale) and under null_session a failed
  # check swaps in a cookie jar whose writes are silently dropped — the account
  # would be created and the session never set, which is precisely the trap
  # PlayerSignInsController's header describes. So the response hands back a
  # single-use PlayerSignInLink instead and the client follows it: same row,
  # same consumption, same claim application as the emailed path, on a page
  # that is not cached and does carry a live token.
  def join
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    return render json: { ok: false, error: "unavailable" }, status: :forbidden unless @survey.join_prompt?

    email    = params[:email].to_s.strip.downcase.first(Player::MAX_EMAIL)
    password = params[:password].to_s

    return render json: { ok: false, error: "email" } unless email.match?(URI::MailTo::EMAIL_REGEXP)
    return render json: { ok: false, error: "password_short" } if password.length < Player::MIN_PASSWORD
    return render json: { ok: false, error: "too_many" }, status: :too_many_requests unless join_budget_ok?(email)

    player = Player.find_by(email_address: email)
    created = false

    if player.nil?
      player = Player.create!(email_address: email, password: password)
      created = true
    elsif player.adoptable?
      # A shell left behind by the emailed-link era, with nothing on it. Giving
      # it the password now is the same act as creating it would have been.
      player.update!(password: password)
      created = true
    elsif player.password_digest.blank? && player.player_identities.exists?
      # Signed up with Google, now typing a password at the same address.
      # `authenticate` on a digest-less row is simply false, so without this
      # they are told their password is wrong — about an account that has never
      # had one, with no way to set one (there is no respondent password
      # reset). Name the door they already have instead.
      return render json: { ok: false, error: "use_google" }, status: :unauthorized
    elsif !player.authenticate(password)
      return render json: { ok: false, error: "credentials" }, status: :unauthorized
    end

    remember_play_locale(player)
    _link, raw = PlayerSignInLink.mint!(player: player, claim_payload: join_claim_payload,
                                        origin: PlayerSignInLink::ORIGIN_SIGNUP)
    send_join_confirmation(player) if created

    render json: { ok: true, next: player_sign_in_path(raw) }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    # A losing create race, or a password the model refused for a reason the
    # length check above did not catch. Neither is a server fault.
    ErrorReporting.report("PlayerController#join", e, survey_id: @survey&.id)
    render json: { ok: false, error: "retry" }, status: :unprocessable_entity
  rescue => e
    ErrorReporting.report("PlayerController#join", e, survey_id: @survey&.id)
    render json: { ok: false, error: "retry" }, status: :internal_server_error
  end

  # POST /play/:token/join_google
  #
  # The other half of the card: the same account, asked for with a Google
  # sign-in instead of an address and a password.
  #
  # This does NOT start a Google round trip. It cannot: OmniAuth's request
  # phase is a CSRF-protected POST (omniauth-rails_csrf_protection), and the
  # page this call comes from is service-worker cached, which is exactly why
  # #join above runs under null_session — its token can be arbitrarily stale.
  # So this action does the one thing the cached page genuinely can't do
  # afterwards: it works out what this run is worth, parks it, and hands back a
  # URL. The page it names is outside /play/, is therefore never cached, and
  # carries a live token that can start the round trip properly.
  #
  # Cookie-free for all of #join's reasons, and one more of its own: the claims
  # have to survive a trip through google.com and back, and a SameSite=Lax
  # cookie is not sent on a cross-site POST return. The handoff row is what
  # carries them.
  #
  # No address is named here and none is recorded. Everything this endpoint
  # knows is what the run already proved, so unlike #join it has no oracle to
  # give away and can refuse plainly.
  def join_google
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    return render json: { ok: false, error: "unavailable" }, status: :forbidden unless @survey.join_prompt?
    return render json: { ok: false, error: "unavailable" }, status: :forbidden unless SocialAuth.player_enabled?

    # The language they were playing in, twice over: on the row, so the account
    # this ends in is created in it (remember_play_locale's job on the other
    # path), and in the URL, where resolve_locale's ?locale= already means the
    # pages in between are drawn in it too.
    locale = SupportedLocales.coerce(params[:lang].presence || I18n.locale)
    _handoff, raw = PlayerOauthHandoff.mint!(claim_payload: join_claim_payload,
                                             survey: @survey, locale: locale)

    render json: { ok: true, next: player_join_path(raw, locale: locale) }
  rescue => e
    ErrorReporting.report("PlayerController#join_google", e, survey_id: @survey&.id)
    render json: { ok: false, error: "retry" }, status: :internal_server_error
  end

  def results
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    # The link decides, not just the Verto — otherwise a cohort sent a
    # comparison-off link could still read the aggregate straight off this
    # endpoint, which is the exact thing turning it off was meant to prevent.
    unless play_settings.compare_results?
      return render json: { ok: false, error: "Comparison not enabled" }, status: :forbidden
    end

    # The aggregation is cached for a few seconds (see cached_aggregate): this
    # endpoint deserialises every answered response's answers JSON per compute,
    # and at burst scale computing per request made it O(total responses) per
    # viewer. The access guards above stay OUTSIDE the cache — the link still
    # decides who may read; only the link-independent payload is shared.
    payload = cached_aggregate(:results) do
      # Every responder (answered ≥1 question), not only those who reached
      # Submit — so a respondent compares against all the answers collected per
      # question, matching the creator Results screen. Each row is tallied off
      # its own answers, so partial responses count toward what they reached.
      responses = @survey.responses.where(answered: true)
      total     = responses.count

      # Small-cell suppression (P1-14). #regions has enforced this from the
      # start; #results did not, so on a Verto with one or two responders the
      # comparison a respondent is shown IS the other respondent's answers,
      # attributable to them by anyone who knows who else was asked. Same
      # threshold and same reasoning as the map — Response::MIN_REGION_SAMPLE_SIZE.
      if total < Response::MIN_REGION_SAMPLE_SIZE
        { suppressed: true, total_responses: total, results: [] }
      else
        { total_responses: total,
          results: aggregate_rows(responses) + token_comparison_rows(responses) }
      end
    end

    render json: { ok: true }.merge(payload)
  end

  # Per-country aggregates for the post-finish map view: one entry per country
  # that has at least one region-tagged responder. Every Verto captures this
  # via the "Where do you live?" demographic question, so there's no separate
  # opt-in gate — an empty result set just renders the "no regional answers
  # yet" copy.
  def regions
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone unless @survey.playable?
    # Mirrors the #results guard above: hiding the CTA isn't enough, the endpoint
    # is public and answers anyone who asks.
    unless @survey.regions_enabled?
      return render json: { ok: false, error: "Regional comparison not enabled" }, status: :forbidden
    end

    # Cached like #results, and computed in bounded memory: the old shape
    # loaded EVERY region-tagged response (answers JSON included) into one
    # in-memory group_by — a straight OOM vector on a big Verto. Now a grouped
    # SQL COUNT picks the qualifying countries, and each one aggregates
    # through the concern's batched pass (indexed on [survey_id,
    # region_country]), so at most one batch of rows is resident at a time.
    payload = cached_aggregate(:regions) do
      # Every responder (answered ≥1 question), not only completers —
      # consistent with the results comparison above.
      tagged = @survey.responses.where(answered: true).where.not(region_country: nil)
      counts = tagged.group(:region_country).count

      # Small-cell suppression: a country with fewer than
      # MIN_REGION_SAMPLE_SIZE respondents never appears on the map/list — see
      # Response for why. Two respondents self-declaring different sub-regions
      # of the same country (e.g. "Yorkshire" and "London") count together in
      # one GB group here — display/aggregation is country-level only;
      # region_label stays on the Response row but isn't grouped on.
      rows = counts.filter_map do |country, responders|
        next if responders < Response::MIN_REGION_SAMPLE_SIZE
        {
          id:           country,
          country:      country,
          country_name: WorldRegions.name_for(country),
          responders:   responders,
          results:      aggregate_rows(tagged.where(region_country: country))
        }
      end.sort_by { |r| -r[:responders] }

      { total_tagged: counts.values.sum, regions: rows }
    end

    render json: { ok: true }.merge(payload)
  end

  # Satnav-style location search backing the welcome-card intake: forwards a
  # partial place name to Nominatim and resolves each hit down to the same
  # coarse country + area shape apply_region already accepts — never a precise
  # address or coordinate (see NominatimClient's privacy note).
  def location_search
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey

    # The creator's narrowing (LocationScope) is read off the SAVED card the
    # search is for, never taken from the request: the client only says which
    # card it is. An index that isn't a location card searches unscoped, as
    # every card did before scopes existed.
    card  = Integer(params[:card].to_s, exception: false)&.then { |i| i >= 0 ? Array(@survey.cards)[i] : nil }
    scope = LocationScope.for_card(card)
    results = NominatimClient.search(query: params[:q].to_s, locale: I18n.locale.to_s, **scope).map do |place|
      label = LocationScope.label_for(place, scope[:places])
      {
        display_name: place[:display_name],
        country_code: place[:country_code],
        label: label
      }
    end
    render json: { ok: true, results: results }
  rescue JSON::ParserError
    render json: { ok: false, error: "Malformed request body." }, status: :bad_request
  rescue CrossSurveyToken
    render json: { ok: false, error: "Invalid session." }, status: :forbidden
  rescue => e
    ErrorReporting.report("PlayerController##{action_name}", e)
    render json: { ok: false, error: "Search failed" }, status: :bad_gateway
  end

  private

  # See the after_action above. Overrides frame-ancestors for THIS request only,
  # leaving every other directive of the app-wide policy (script-src, img-src,
  # the Pexels hosts…) exactly as configured.
  #
  # Done by handing the middleware a per-request policy rather than writing the
  # header here: the CSP middleware builds the header on the way out, AFTER this
  # runs, and skips a header that's already set — so writing one directly would
  # have replaced the player's whole policy with this single directive. A dup,
  # not the global object, so the relaxation can't leak into other responses
  # (the hazard config/initializers/blazer.rb documents).
  def allow_embedding
    policy = request.content_security_policy
    return if policy.nil?

    embeddable = policy.dup
    embeddable.frame_ancestors(:self, "file:", *extra_frame_ancestors)
    request.content_security_policy = embeddable

    # Rails' default SAMEORIGIN blocks a file:// parent on its own, whatever the
    # CSP says — modern browsers prefer frame-ancestors, but only when
    # X-Frame-Options isn't there to contradict it.
    response.headers.delete("X-Frame-Options")
  end

  # Sites allowed to frame a Verto beyond the app itself: the marketing site,
  # which is on another domain, and the staging domain it's built on. Space- or
  # comma-separated in PLAYER_FRAME_ANCESTORS, so adding one is a deploy setting
  # rather than a code change — the list belongs to whoever owns the domains.
  #
  # Scheme-qualified origins only. A bare host is silently useless in a CSP
  # source list, and `*` would hand every site on the internet the ability to
  # frame someone's Verto, which is the thing this directive exists to prevent.
  def extra_frame_ancestors
    ENV.fetch("PLAYER_FRAME_ANCESTORS", "").split(/[\s,]+/).grep(%r{\Ahttps?://[^\s/]+\z})
  end

  # Swap the inherited :modern version set for the player's own (see
  # PLAYER_BROWSER_VERSIONS). Keeps the caller's `block` so a browser that really
  # is too old still gets the standard 406 page rather than a broken screen.
  def allow_browser(versions:, block:)
    super(versions: PLAYER_BROWSER_VERSIONS, block: block)
  end

  # Finds (or starts) this session's response row and attaches it to the
  # current survey/share — the shared first step of every write action.
  # A token that belongs to a different survey is refused, not adopted.
  class CrossSurveyToken < StandardError; end

  def find_or_init_response(token)
    resp = @survey.responses.find_or_initialize_by(session_token: token)
    if resp.new_record? && Response.where(session_token: token).where.not(survey_id: @survey.id).exists?
      # The old global lookup made any playable survey's consent URL a lever on
      # ANOTHER survey's response — including the purge. The client's tokens
      # are keyed per Verto (sessionStorage key includes the submit URL), so a
      # legitimate respondent never hits this; only a crafted request can.
      raise CrossSurveyToken
    end
    resp.survey_share ||= @survey_share
    # Which named share link this respondent came in on, so the Share panel can
    # say what each audience actually returned. Set once, like the share.
    resp.survey_link ||= @survey_link
    # Wave 1 is implicit (current_wave is nil until start_next_wave! is first
    # called), so this is a no-op until then — exactly the "nil means wave 1"
    # contract Survey#waved? relies on.
    resp.survey_wave_id ||= @survey.current_wave&.id
    resp
  end

  # Declining consent is terminal until the respondent explicitly re-agrees.
  # Without this the purge only held for an instant: any later /progress,
  # /submit or /grade with the same token — an in-flight request, a queued
  # replay, a crafted POST — re-stored everything and re-entered the respondent
  # in every count, while the row still said they had declined.
  def refuse_if_declined(resp)
    return false unless resp.persisted? && resp.consent_declined_at.present?
    render json: { ok: false, error: "Consent was declined for this session." }, status: :forbidden
    true
  end

  # No retests: one completed run per identity per wave (Survey#retest_blocked?).
  # Runs after the digests are applied and before save!, so a refused run never
  # creates or completes a row. On the code basis the distinct-code budget is
  # spent only by the write that first attaches the code to this row — a
  # reload or replay of a row that already carries its digest is a retry, not
  # a guess — and a spent budget fails OPEN: the oracle closes (always 200)
  # and the run is stored exactly as it was before this feature existed.
  # Constant body whichever identity matched: no digest, code, wave or count
  # ever appears. 403 on purpose — the service worker retries only 429/5xx,
  # so a refusal is never replayed.
  def refuse_if_retest(resp)
    return false unless @survey.no_retests?

    if @survey.retest_basis == "code"
      digest = resp.respondent_code_digest
      return false if digest.blank?
      if identity_attaching?(resp) &&
         !code_budget_ok?("retest", digest, per_ip: MAX_RETEST_CODES_PER_IP, per_code: MAX_RETEST_PER_CODE)
        return false
      end
    end
    return false unless @survey.retest_blocked?(resp)

    render json: { ok: false, code: "already_played", error: "You've already taken this Verto." }, status: :forbidden
    true
  end

  # Whether this write is the one attaching an identity to the row.
  def identity_attaching?(resp)
    resp.new_record? || resp.respondent_code_digest_changed? || resp.player_key_digest_changed?
  end

  # Record the respondent's self-invented code as a digest. The plaintext is used
  # to compute the HMAC and then dropped on the floor — it is never assigned to
  # the record, never logged (see filter_parameter_logging) and never returned.
  #
  # Set once per response: a later request can't overwrite it, so a respondent who
  # reloads mid-Verto keeps the identity they started with.
  def apply_respondent_code(resp, code)
    # `active?`, not `enabled?`: the code can now be collected by a card in the
    # deck as well as by the survey-level pre-screen, and asking the column
    # alone meant a deck using only the card recorded no digest at all — so
    # wave matching, the returning-respondent count and recall would every one
    # of them have found nothing.
    return unless @survey.respondent_code_active?
    return if resp.respondent_code_digest.present?

    digest = @survey.respondent_code_digest(code)
    resp.respondent_code_digest = digest if digest
  end

  # Two budgets the per-IP request cap cannot express, both cheap counters in
  # Rails.cache (no-op under the null store in test, same as `rate_limit`).
  #
  #   per IP   — how many DISTINCT codes one caller has tried this hour.
  #              Counting distinct codes rather than requests is what keeps
  #              this safe behind venue NAT: fifty respondents on one Wi-Fi try
  #              fifty codes, but each tries their OWN, once. A guesser needs
  #              hundreds.
  #   per code — how often one digest has been asked for from anywhere, so a
  #              distributed guess at an obvious code ("test", "abc", "1234")
  #              still runs out.
  MAX_RECALL_CODES_PER_IP = 12
  MAX_RECALL_PER_CODE     = 20
  # No retests spends its own budget (same shape, own prefix) on every
  # code-based decision — eligibility plus the first write that attaches the
  # code, about two per run — and a whole classroom legitimately sits behind
  # one NAT address trying one code each, hence the wider allowance.
  MAX_RETEST_CODES_PER_IP = 60
  MAX_RETEST_PER_CODE     = 20

  def recall_budget_ok?(digest)
    code_budget_ok?("recall", digest, per_ip: MAX_RECALL_CODES_PER_IP, per_code: MAX_RECALL_PER_CODE)
  end

  def code_budget_ok?(prefix, digest, per_ip:, per_code:)
    ip_key = "#{prefix}:#{@survey.id}:ip:#{request.remote_ip}:#{digest}"
    # A repeat of the SAME code from the same IP is a retry, not a new guess —
    # it must not spend the distinct-code budget. The marker is what makes the
    # count distinct.
    # The marker is written only for an admitted code: marking a refused one
    # would let its retry skip this block and pass, which turned the distinct
    # budget into "two tries per code" instead of a ceiling.
    unless Rails.cache.exist?(ip_key)
      tried = Rails.cache.increment("#{prefix}:#{@survey.id}:ip:#{request.remote_ip}", 1, expires_in: 1.hour)
      return false if tried && tried > per_ip
      Rails.cache.write(ip_key, true, expires_in: 1.hour)
    end

    asked = Rails.cache.increment("#{prefix}:#{@survey.id}:code:#{digest}", 1, expires_in: 1.hour)
    return false if asked && asked > per_code

    true
  end

  # How many DISTINCT addresses one IP may create an account for in an hour,
  # and how often one address may be asked for from anywhere. The same two
  # budgets recall and No retests spend, and here for a third reason: an
  # uncapped unauthenticated endpoint that mints accounts lets one machine walk
  # a list of addresses into rows nobody asked for.
  #
  # The per-IP half was 30 flat, and the comment claimed it was "generous
  # enough that a venue full of respondents behind one NAT address each join
  # once". Measured rather than assumed, it was not: 30 is thirty people, and
  # a venue full is 250. It carries JOIN_RATE_LIMIT_SCALE now so that claim can
  # be made true by setting it, instead of being asserted and wrong.
  #
  # MAX_JOIN_PER_ADDRESS stays flat on purpose. It is per-address, so a crowd
  # never pushes against it — only something grinding at one account does, and
  # that is exactly what it is for.
  MAX_JOIN_ADDRESSES_PER_IP = 30 * JOIN_RATE_LIMIT_SCALE
  MAX_JOIN_PER_ADDRESS      = 5

  # A blank or malformed address spends nothing and sends nothing — and reads
  # from outside as a success, like every other refusal here.
  def join_budget_ok?(email)
    return false unless email.match?(URI::MailTo::EMAIL_REGEXP)

    code_budget_ok?("join", join_budget_digest(email),
                    per_ip: MAX_JOIN_ADDRESSES_PER_IP, per_code: MAX_JOIN_PER_ADDRESS)
  end

  # How many confirmation mails one IP may cause from #join in an hour. Flat,
  # and deliberately NOT multiplied by JOIN_RATE_LIMIT_SCALE: that lever exists
  # so a room full of people can create accounts, and it was only ever safe to
  # scale because #join sent no mail. Creating an account and writing to a
  # stranger's inbox are different acts and want different bounds — with the
  # lever at an event setting, the account caps would otherwise become the
  # multiplier on how many strangers one machine may mail.
  #
  # What bounds it on the other side: the mail goes out on exactly two
  # branches, a genuinely new Player and an adoptable shell being given a
  # password. An existing account authenticating, a use_google answer and a
  # wrong password send nothing. So an address can be mailed this way once,
  # for an account that did not exist, and never again by the same route —
  # first contact only, which is what makes a per-IP counter enough rather
  # than a per-mailbox one.
  #
  # A respondent past the cap is not refused anything: the account is made
  # and signed in as usual, and /you offers them the link to send themselves.
  MAX_JOIN_CONFIRMATIONS_PER_IP = 30

  def send_join_confirmation(player)
    sent = Rails.cache.increment("join_confirm:ip:#{request.remote_ip}", 1, expires_in: 1.hour)
    return if sent && sent > MAX_JOIN_CONFIRMATIONS_PER_IP

    PlayerEmailConfirmationsController.deliver(player, survey: @survey)
  end

  # The budget counters are keyed on this, and cache keys are readable wherever
  # the cache is — so the address goes in as a keyed digest rather than as
  # itself. Not Survey#respondent_code_digest: that one truncates to
  # MAX_RESPONDENT_CODE, which would collapse long addresses sharing a prefix
  # into one budget.
  def join_budget_digest(email)
    OpenSSL::HMAC.hexdigest("SHA256", self.class.join_budget_key, email)
  end

  def self.join_budget_key
    @join_budget_key ||= Rails.application.key_generator.generate_key("player_join_budget", 32)
  end

  # How much of a client-sent payload this will resolve. Both bounds exist to
  # keep one request's database work fixed: a browser holds keys for the
  # handful of Vertos it has played, not for hundreds.
  MAX_JOIN_DEVICE_KEYS       = 20
  MAX_JOIN_CLAIMS_PER_SURVEY = 10

  # What this person may claim, resolved here rather than trusted from the
  # client. Two sources, neither a bare assertion:
  #
  #   session_token — the run just finished. The column is uniquely indexed and
  #                   scoped to this Verto, so holding the token IS the proof.
  #   device_keys   — Vertos played earlier on this browser. A key is only ever
  #                   matched against the digest of the survey it belongs to
  #                   (per-survey HMAC — see Survey#player_key_digest), so a key
  #                   lifted from one Verto resolves to nothing on another.
  #
  # Stored on the link, not applied. Anything unresolvable is skipped: a paused
  # SurveyLink, a freed vanity slug or an erased response is an ordinary state,
  # and one dead entry must not cost the person the rest of their payload.
  def join_claim_payload
    claims = []

    token = params[:session_token].to_s
    if token.present? && (resp = @survey.responses.find_by(session_token: token))
      claims << { "response_id" => resp.id, "source" => "signup" }
    end

    Array(params[:device_keys]).first(MAX_JOIN_DEVICE_KEYS).each do |entry|
      entry = entry.to_unsafe_h if entry.respond_to?(:to_unsafe_h)
      next unless entry.is_a?(Hash)

      other = survey_for_play_token(entry["token"])
      next if other.nil?

      digest = other.player_key_digest(entry["player_key"])
      next if digest.nil?

      other.responses.where(status: "completed", player_key_digest: digest)
           .order(id: :desc).limit(MAX_JOIN_CLAIMS_PER_SURVEY).pluck(:id).each do |id|
        claims << { "response_id" => id, "source" => "device_key" }
      end
    end

    claims.uniq { |c| c["response_id"] }
  end

  # load_survey_and_share's four-way resolution without the instance variables:
  # #join resolves OTHER Vertos' tokens and must not overwrite the one being
  # played. nil for anything that doesn't resolve.
  def survey_for_play_token(token)
    token = token.to_s
    return nil if token.blank?

    if (share = SurveyShare.find_by(share_token: token))
      Survey.without_report_text.find_by(id: share.survey_id)
    elsif (link = SurveyLink.active.find_by(slug: token))
      Survey.without_report_text.find_by(id: link.survey_id)
    else
      Survey.without_report_text.find_by(publish_token: token) ||
        Survey.without_report_text.where.not(publish_token: nil).find_by(slug: token)
    end
  end

  # The locale the mail should arrive in. Set once, from the Verto they were
  # playing when they joined — never overwritten, because after that the
  # account holds a preference of its own and this request has no business
  # moving it.
  def remember_play_locale(player)
    return if player.preferred_locale.present?

    player.update_column(:preferred_locale,
                         SupportedLocales.coerce(params[:lang].presence || I18n.locale))
  end


  # The board's two inputs, from a JSON body on the POST and from the query
  # string on the deprecated GET. A malformed body is not an error here: the
  # board is a read, and "no identity" degrades to the anonymous board rather
  # than to a 400.
  def leaderboard_request_params
    if request.post? && request.content_type.to_s.include?("json")
      body = request.body.read
      parsed = body.present? ? JSON.parse(body) : {}
      return { session_token: parsed["session_token"], player_key: parsed["player_key"] }
    end
    { session_token: params[:session_token], player_key: params[:player_key] }
  rescue JSON::ParserError
    { session_token: nil, player_key: nil }
  end

  # The leaderboard identity, same discipline as the respondent code above:
  # recorded only while the feature is on, only as a digest, and set once per
  # response — a reload keeps the identity it started with.
  def apply_player_key(resp, key)
    return unless @survey.player_identity_active?
    return if resp.player_key_digest.present?

    digest = @survey.player_key_digest(key)
    resp.player_key_digest = digest if digest
  end

  # Contact details ride the ordinary save payload the way the respondent code
  # and player key do — no endpoint of their own, so the service worker's
  # offline submit queue carries them for free. They are NOT part of answers:
  # they land in their own table (ContactDetail), keyed by the same per-survey
  # digest that assigns the leaderboard alias, which is the whole separation
  # the feature promises. Idempotent, so the payload can carry them on every
  # save until the client stops sending.
  #
  # The end-of-Verto account ask (#join) collects an address too, and keeps the
  # separation the same way from the other side: it writes nothing onto the
  # response and nothing keyed by any digest — the address lives on `players`,
  # and `player_claims` names the response by id. Survey#join_prompt_enabled?
  # is inside the neurodiversity wall with contact_form_enabled? for exactly
  # this reason.
  def apply_contact(data)
    return unless @survey.contact_form_enabled?
    fields = data["contact"]
    return unless fields.is_a?(Hash)

    digest = @survey.player_key_digest(data["player_key"])
    return unless digest

    ContactDetail.upsert_for!(survey: @survey, key_digest: digest, fields: fields)
  rescue ActiveRecord::RecordInvalid
    # Every field blank — nothing worth a row.
  end

  # NB: the status column defaults to "completed", so a freshly initialized
  # record already reads "completed" — only preserve it for rows already saved
  # as completed (e.g. a late progress ping after submit), otherwise mark
  # "started".
  def mark_started_unless_completed(resp)
    resp.status = "started" unless resp.persisted? && resp.status == "completed"
    stamp_started_metadata(resp)
  end

  # The quiz answer feedback in the language the respondent is actually reading,
  # falling back to the source text when this Verto has no translation for it.
  def localized_explanation(card, locale)
    helpers.localized_card(card, locale, @survey.default_locale)["explanation"].to_s
  end

  # First-touch metadata for the response. Both are `||=` on purpose: /progress
  # can fire on every card, a refresh reuses the same session_token, and an offline
  # submit can replay hours later — none of which should move the clock back to
  # the start or relabel the device.
  def stamp_started_metadata(resp)
    resp.started_at  ||= Time.current
    resp.device_kind ||= DeviceKind.from(request.user_agent)
  end

  # The answers already persisted for a response (empty for a brand-new row).
  def stored_answers(resp)
    resp.persisted? && resp.answers.is_a?(Hash) ? resp.answers : {}
  end

  # The one save for anything that writes answers. Moderation::Hold scrubs the
  # free text and lifts what is left into HeldText rows, leaving markers in
  # the answer — see app/lib/moderation.rb. One transaction for the save and
  # the rows: a committed marker without its row would lose the respondent's
  # text, so if the rows can't be written neither is the response, the action
  # 500s, and the service worker retries the whole write.
  #
  # Runs last, after every sync/score/total has read the merged answers, and
  # after ai_normalize_open_ended_answer! has had the (scrubbed) text to grade.
  def save_with_hold!(resp)
    held = Moderation::Hold.extract!(resp, @survey, scrub_hits: @scrub_hits || {})
    Response.transaction do
      resp.save!
      Moderation::Hold.persist!(resp, held)
    end
  end

  # Anti-cheat for quizzes and tokenised Vertos: a graded or token-awarding
  # card that already holds a committed answer is locked — its stored value
  # always wins over anything in the new payload, so a respondent can't go
  # back and change an answer to earn more tokens (or fix a wrong quiz
  # answer). Non-graded, non-awarding (measurement) cards and not-yet-answered
  # cards take the incoming value as normal. A plain Verto (neither quiz nor
  # tokenised) merges nothing (incoming wins outright) — unless it has No
  # going back on, which pins EVERY answered card on any Verto: the player
  # hides Back and saves each advance, and this is what makes that promise
  # hold against a reload, a replay or a crafted request.
  def locked_merge(stored, incoming)
    # Every write path goes through here, so it's the one place free text has to
    # be bounded — the client's maxlength is a courtesy, and this endpoint is
    # public and takes JSON.
    incoming = @survey.clamp_free_text(incoming.is_a?(Hash) ? incoming : {})
    incoming = @survey.clamp_selection_count(incoming)
    incoming = @survey.drop_retired_answers(incoming)
    # A moderation marker is something the server writes (save_with_hold!),
    # never something the player may send: a planted one would count as an
    # answer with no text behind it.
    incoming = Moderation::Hold.strip_markers(incoming)
    # Contact details come out here, before anything reads the answer — the
    # hold would scrub them anyway, but #grade sends a free-text quiz answer
    # to Claude for near-miss grading first, and an email address in it has
    # no business in that prompt either. The hits ride to save_with_hold! so
    # the held row still records what was removed.
    incoming, @scrub_hits = Moderation::Scrub.answers(@survey.cards, incoming)
    return incoming unless @survey.quiz? || @survey.tokenisation_enabled? || @survey.no_going_back?
    stored = stored.is_a?(Hash) ? stored : {}
    merged = incoming.dup
    Array(@survey.cards).each_with_index do |card, idx|
      next unless @survey.no_going_back? || QuizGrading.graded?(card) || TokenGrading.awarding?(card)
      key = idx.to_s
      merged[key] = stored[key] if answered?(stored[key])
    end
    merged
  end

  # Whether an answer hash holds a real response (a value, or free-text Other).
  # One definition, in Response — this was a third implementation of it, and it
  # disagreed with both of the others. See Response.answered_entry? for what the
  # rule is and why each clause is there. locked_merge uses it to decide what a
  # later submit may not overwrite.
  def answered?(ans)
    Response.answered_entry?(ans)
  end

  # Free-text quiz answers rarely match an accepted answer verbatim ("make the
  # laws" vs. the accepted "make laws") — the very first time an open_ended
  # graded card is answered, ask Claude whether a near-miss is a genuine
  # semantic match and, if so, rewrite the stored value to the accepted
  # wording. Every later recomputation of this answer (apply_quiz_score, the
  # scores endpoint, a resave from a chatty client) is then a plain, free
  # exact-match check via QuizGrading — nothing re-asks the AI for the same
  # answer twice. Called from #grade only when the caller has confirmed this
  # card had no committed answer before this request.
  def ai_normalize_open_ended_answer!(resp, idx)
    card = Array(@survey.cards)[idx]
    return unless card && card["type"].to_s == "open_ended" && QuizGrading.graded?(card)

    key   = idx.to_s
    entry = resp.answers[key]
    return unless entry.is_a?(Hash)
    value = entry["value"]
    return if value.to_s.strip.empty?
    return if QuizGrading.correct?(card, value) # already an exact match — nothing to do

    accepted = Array(card["correct"]).map(&:to_s).reject(&:empty?)
    return if accepted.empty?
    return unless ai_confirms_match?(question: card["text"].to_s, accepted_answers: accepted, answer: value.to_s)

    # Reassign the whole hash (rather than mutate the nested entry in place)
    # so ActiveRecord's dirty-tracking on the JSON column reliably sees it.
    resp.answers = resp.answers.merge(key => entry.merge("value" => accepted.first))
  rescue => e
    ErrorReporting.report("PlayerController#grade", e)
    # Best-effort: the respondent keeps the exact-match verdict.
  end

  # Ask Claude whether a near-miss answer is a genuine match — but only if this
  # process has a slot free for respondent-facing AI.
  #
  # #grade is public and unauthenticated, so this is the one Claude call a
  # creator cannot throttle: a popular quiz with open-ended graded cards can
  # point real respondent traffic straight at it, and three Puma threads is all
  # there is. When every slot is busy we skip the call and the respondent keeps
  # the exact-match verdict — the exact outcome the rescue above has always
  # produced on a network error, so this adds no new behaviour, only a bound.
  #
  # The bound sits here rather than around the action on purpose: #grade saves
  # the respondent's answer *after* this step, so short-circuiting the action
  # would drop the answer itself, not just the refinement.
  def ai_confirms_match?(question:, accepted_answers:, answer:)
    AI_GRADE_POOL.with_slot(false) do
      QuizAnswerGrader.new.call(question: question, accepted_answers: accepted_answers, answer: answer)
    end
  end

  # Cache the server-computed score on quiz responses so "how you compare" is a
  # cheap read; a no-op for non-quiz Vertos.
  def apply_quiz_score(resp)
    return unless @survey.quiz?
    result = QuizGrading.score(@survey.cards, resp.answers)
    resp.score    = result[:score]
    resp.quiz_max = result[:max]
  end

  # Cache the server-computed token totals on tokenised responses, recomputed
  # from the (already locked_merge-protected) stored answers — never trusting
  # anything the client claims its own running total is. A no-op for
  # non-tokenised Vertos.
  def apply_token_totals(resp)
    return unless @survey.tokenisation_enabled?
    resp.token_totals = TokenGrading.totals(@survey.cards, resp.answers, @survey.token_type_ids)
  end

  # The flat row shape the player JS renders comparisons from.
  # A short shared cache over the public aggregate endpoints (#results,
  # #regions, #scores). These recompute over every answered/completed response
  # and are hit by respondents, so at burst scale the compute must be per
  # WINDOW, not per viewer: a few seconds of staleness is invisible on a
  # results screen and is the same freshness contract the live counter and the
  # leaderboard snapshot already set. race_condition_ttl serves the just-
  # expired value while ONE caller recomputes, so a burst arriving at expiry
  # can't stampede the aggregation. Keyed on updated_at so a deck edit or
  # republish never serves the previous deck's aggregates. Access guards stay
  # in the actions, outside the cache — only link-independent payloads live
  # here. (In test the null cache store makes fetch a pass-through.)
  # Kept as a name and a constant here because both are referred to from all
  # over this file; the key, the TTL and the stampede guard now live in
  # AggregatesSurveyResults, so /you reads the same entry rather than
  # recomputing the same numbers behind its own key.
  PLAYER_AGGREGATE_TTL = AggregatesSurveyResults::SURVEY_AGGREGATE_TTL

  def cached_aggregate(kind, &block)
    cached_survey_aggregate(kind, @survey, &block)
  end

  # How long a rendered player page stays cached. Long, because the key already
  # carries every input that changes the bytes (deck version, wave, link
  # settings, locale) so an edit busts it immediately — the TTL is only a
  # backstop for the rare change that doesn't bump one of those. race_condition_ttl
  # serves the just-expired copy while ONE caller re-renders, so an expiry can't
  # stampede; a genuinely cold key (first play, or right after a deploy flushes
  # the store) is not covered, which is why an event pre-warms this before doors.
  PLAYER_PAGE_TTL = 1.hour

  # The rendered #show HTML, cached as shared bytes per link + deck version +
  # resolved locale. Safe to share: the page boots player_controller.js and
  # fetches all respondent-specific data from the JSON endpoints, so nothing
  # per-respondent is rendered into it; the one per-session byte (csrf_meta_tags)
  # is never verified because every player write endpoint uses null_session.
  #
  # Two tiers. A process-local MemoryStore sits in front of Rails.cache: each
  # Puma worker keeps the pages it has served for the same TTL, so a burst costs
  # one render per worker per key instead of a ~150 KB round-trip to the shared
  # store on every request — and the page no longer depends on that store being
  # healthy. Rails.cache fails OPEN (config/environments/production.rb), which
  # under load turns a struggling Key Value instance into a full re-render of
  # every page and hands the web tier its biggest cost straight back (runs 22–23,
  # docs/SCALE_AND_COST_PLAN.md §2b). Correctness is unchanged: the key already
  # carries every input that changes the bytes and nothing deletes these keys
  # (expiry only), so a local copy can never outlive a republish. Sized for a
  # handful of live links × locales; MemoryStore evicts least-recently-used past
  # the cap. The test environment defaults it to a null store, as Rails.cache
  # already is there, so a test sees every render unless it opts in
  # (test/integration/player_page_cache_test.rb).
  def self.default_player_page_local_cache
    return ActiveSupport::Cache::NullStore.new if Rails.env.test?

    ActiveSupport::Cache::MemoryStore.new(size: 32.megabytes)
  end
  class_attribute :player_page_local_cache, instance_accessor: false, default: default_player_page_local_cache

  def cached_play_page
    key = play_page_cache_key
    self.class.player_page_local_cache.fetch(key, expires_in: PLAYER_PAGE_TTL) do
      Rails.cache.fetch(key, expires_in: PLAYER_PAGE_TTL, race_condition_ttl: 30.seconds) do
        render_play_page
      end
    end
  end

  def render_play_page
    if @survey.chrome_follows_verto_language?
      I18n.with_locale(@display_locale) { render_to_string(:show, layout: "fullscreen") }
    else
      render_to_string(:show, layout: "fullscreen")
    end
  end

  # Everything that changes the rendered bytes. The token (not the survey id) is
  # the identity: publish token, share token, vanity slug and named-link slug
  # each embed themselves in every data-*-url the shell reads. current_wave and a
  # named link's settings can alter the page without bumping survey.updated_at,
  # so both ride the key; Current.locale only matters when the chrome does NOT
  # follow the Verto's language (otherwise @display_locale already captures it).
  def play_page_cache_key
    [ "player-page", params[:token], @survey.updated_at.to_f, @display_locale,
      @survey.current_wave&.position,
      (@survey.chrome_follows_verto_language? ? nil : Current.locale),
      @survey_link&.updated_at&.to_f ]
  end

  def aggregate_rows(responses)
    aggregate_results(Array(@survey.cards), responses).map.with_index do |row, idx|
      {
        index:  idx,
        type:   row[:type],
        prompt: row[:card]["text"] || row[:card]["prompt"] || row[:card]["title"],
        options: row[:card]["options"],
        total:  row[:total],
        counts: row[:counts],
        avg:    row[:avg],
        # A tap card's counts are keyed by response key; the bars need the words
        # and the order that go with them, and the client has no other way to
        # learn a scale the creator wrote. Key + label only — the colours are
        # already on the card the respondent just answered.
        responses: (TapScales.for_card(row[:card]).map { |r| r.slice("key", "label") } if row[:type] == "tap_card")
      }.compact
    end
  end

  # Tokenisation: one synthetic row per token type, appended after the
  # per-question rows — this is how "compare your tokens" folds into the
  # existing results-comparison panel instead of a separate endpoint/panel.
  # A histogram of each response's cached token_totals[id], the same shape
  # `scores`' score histogram uses.
  def token_comparison_rows(responses)
    return [] unless @survey.tokenisation_enabled?
    token_types = Array(@survey.token_types)
    return [] if token_types.empty?

    dist  = Hash.new { |h, k| h[k] = Hash.new(0) }
    total = 0
    responses.reorder(nil).select(:id, :token_totals).find_each(batch_size: 500) do |r|
      total += 1
      totals = r.token_totals || {}
      token_types.each { |t| dist[t["id"]][totals[t["id"]].to_i] += 1 }
    end

    token_types.map do |t|
      {
        index:    "token:#{t['id']}",
        type:     "token_total",
        token_id: t["id"],
        prompt:   [ t["icon"], t["name"] ].compact_blank.join(" "),
        total:    total,
        counts:   dist[t["id"]]
      }
    end
  end

  # Region data comes from one universal source: the "Where do you live?"
  # demographic question (DemographicQuestions), a location-search card whose
  # answer value is a plain "CC|Label" string — never inferred, never a
  # precise address (see NominatimClient). Must run AFTER resp.answers is set,
  # since it reads the freshly merged answer. An unanswered/invalid pick just
  # leaves the response untagged, same as skipping any other optional card.
  def sync_region_from_answers!(resp)
    sync_demographics_from_answers!(resp)
    idx = Array(@survey.cards).find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "location" }
    value = idx && resp.answers.is_a?(Hash) ? resp.answers[idx.to_s]&.dig("value") : nil
    sep = value.to_s.index("|")
    country = sep ? value[0...sep].to_s.upcase.presence : nil
    # Everything after the first "|" is the label. A third "|POSTCODE" segment
    # is still PARSED OFF and discarded rather than treated as part of the
    # label: postcodes are no longer collected, but a respondent can have a
    # deck open in a tab from before the field was removed, and a stale client
    # packing three segments must not write "London|SW1A 1AA" into region_label
    # — which is what dropping the split would do.
    rest    = sep ? value[(sep + 1)..].to_s : nil
    sep2    = rest&.index("|")
    label   = rest ? (sep2 ? rest[0...sep2] : rest).strip.first(60).presence : nil

    # And the answer itself is rewritten to the two-segment form, so a stale
    # client cannot leave a postcode sitting in `answers` where the columns
    # below no longer keep one. Nulling region_postcode alone would have made
    # the platform look postcode-free while every raw export still carried it.
    if sep2 && idx
      resp.answers = resp.answers.merge(
        idx.to_s => resp.answers[idx.to_s].merge("value" => "#{country}|#{rest[0...sep2]}")
      )
    end

    if country && WorldRegions.valid?(country)
      resp.region_country  = country
      resp.region_label    = label
      resp.region_postcode = nil
    else
      resp.region_country  = nil
      resp.region_label    = nil
      resp.region_postcode = nil
    end
  end

  # Denormalise the two set demographic answers that make useful filter
  # dimensions, for the same reason region is denormalised: the alternative is a
  # JSON query keyed by a card index that differs per Verto.
  #
  # Re-derived on every save rather than written once, so a respondent who goes
  # back and changes their answer is reflected — same as the region above.
  def sync_demographics_from_answers!(resp)
    cards = Array(@survey.cards)
    answers = resp.answers.is_a?(Hash) ? resp.answers : {}

    # The tail's Gender card predates demographic_key, so it is the demographic
    # multiple_choice with NO key (or, future-proofing, key "gender") — the
    # guard is what lets the opt-in Heritage card (also a demographic
    # multiple_choice, key "heritage") coexist without stealing this slot.
    gender_idx = cards.find_index do |c|
      next false unless c.is_a?(Hash) && c["demographic"] && c["type"] == "multiple_choice"
      key = c["demographic_key"].to_s
      key.empty? || key == "gender"
    end
    gender     = gender_idx ? answers[gender_idx.to_s]&.dig("value").to_s.strip.presence : nil
    # Only the options this Verto actually offers, so a tampered payload can't
    # invent a segment label that then renders in the creator's dashboard.
    allowed    = gender_idx ? Array(cards[gender_idx]["options"]).map(&:to_s) : []
    resp.demographic_gender = allowed.include?(gender) ? gender : nil

    # Age, across two card generations. A Verto published before the slider
    # still carries the month card and still denormalises a year; a new one
    # carries the band slider and denormalises a key. A deck has one or the
    # other, never both, so each branch clears the column it does not own —
    # otherwise a creator swapping the card on a still-editable deck would
    # leave the old value behind, and the results page would read a stale
    # birth year beside a fresh band.
    band_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["type"].to_s == "range" }
    birth_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "month" }

    if band_idx
      # A range answer is an index into the card's options, so the band comes
      # from its POSITION, never from the label — the labels are translated
      # per Verto, and matching on one would band a French respondent as nil.
      raw = answers[band_idx.to_s]&.dig("value")
      resp.demographic_age_band   = DemographicQuestions.age_band_key_at(raw)
      resp.demographic_birth_year = nil
    else
      raw_year = birth_idx ? answers[birth_idx.to_s]&.dig("value").to_s[/\A(\d{4})/, 1] : nil
      year     = raw_year&.to_i
      # A year outside living memory is a typo or a probe, not a birth year.
      resp.demographic_birth_year = year && year.between?(1900, Date.current.year) ? year : nil
      resp.demographic_age_band   = nil
    end

    # Opt-in demographics (DemographicQuestions::OPTIONAL_CARDS), same
    # tamper-guard posture: values must be options the card actually offers.
    #
    # Neither card has an "Another…" button any more — someone the list misses
    # types it into the Other box instead. That answer arrives as
    # { value: nil, other: "..." }, so without the second branch below it would
    # denormalise to nothing and exactly the people the list failed would vanish
    # from the segments, which is the opposite of what removing the dead end
    # was for.
    #
    # What gets STORED is the registry's own off-list label, never the typed
    # text: a respondent-authored string in this column renders straight into
    # the creator's dashboard as a segment pill, which is what the allowlist
    # above exists to prevent. The words themselves stay on the answer and reach
    # the creator through the card's own free-text panel and the exports.
    #
    # Guarded on the card's own allow_other, so a decks inserted before the box
    # existed — 9 options, no box — treat a typed payload as the tampering it is.
    heritage_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["demographic_key"] == "heritage" }
    heritage     = heritage_idx ? answers[heritage_idx.to_s]&.dig("value").to_s.strip.presence : nil
    h_other      = heritage_idx ? answers[heritage_idx.to_s]&.dig("other").to_s.strip.presence : nil
    h_allowed    = heritage_idx ? Array(cards[heritage_idx]["options"]).map(&:to_s) : []
    resp.demographic_heritage =
      if h_allowed.include?(heritage)
        heritage
      elsif h_other && cards[heritage_idx]["allow_other"]
        DemographicQuestions.off_list_label("heritage", locale: @survey.default_locale)
      end

    # Neurodiversity is a multi-select; packed pipe-wrapped and sorted (see
    # the column migration). A label containing "|" would corrupt the packing
    # (only a creator-edited option could — registry labels never do), so it
    # is dropped. Exclusivity: real conditions beat "None of these"/"Prefer
    # not to say" if both were ticked; among exclusives alone, first wins.
    neuro_idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["demographic_key"] == "neurodiversity" }
    picked    = neuro_idx ? Array(answers[neuro_idx.to_s]&.dig("value")).map { |v| v.to_s.strip } : []
    n_other   = neuro_idx ? answers[neuro_idx.to_s]&.dig("other").to_s.strip.presence : nil
    n_allowed = neuro_idx ? Array(cards[neuro_idx]["options"]).map(&:to_s) : []
    valid      = (picked & n_allowed).reject { |v| v.include?("|") }
    conditions = valid.reject { |v| DemographicQuestions.neuro_exclusive_labels.include?(v) }
    # Same off-list handling as heritage. The Other box is a standalone answer
    # platform-wide — typing replaces the ticks — so `picked` is empty whenever
    # `other` is set, and this can't collide with a real selection. A typed
    # answer is a real condition, so it beats the exclusives for the same
    # reason a ticked one does.
    chosen =
      if conditions.any?
        conditions
      elsif n_other && cards[neuro_idx]["allow_other"]
        [ DemographicQuestions.off_list_label("neurodiversity", locale: @survey.default_locale) ]
      else
        valid.first(1)
      end
    resp.demographic_neurodiversity = chosen.compact.any? ? "|#{chosen.compact.sort.join('|')}|" : nil
  end

  # The Verto content language to render: an explicit ?lang= always wins (it's
  # the respondent's own choice, made in the player's language switcher); after
  # that, the respondent's browser/system locale — but only while the creator
  # has auto-detection on. With it off, a multilingual Verto opens in its
  # primary language for everyone, and the switcher is how a respondent opts
  # into another ("today when a Verto is opened it will revert to the system
  # language — this needs to be controlled by the creator").
  def resolve_play_locale
    preferred = [ params[:lang] ]
    preferred << Current.locale if @survey.auto_detect_language?
    @survey.display_locale_for(*preferred)
  end

  # ApplicationController#switch_locale wraps this whole request in
  # Current.locale (the visitor's platform locale). The player's chrome
  # (Back/Next/Submit, consent gate, the required hint, the thank-you screen)
  # USED to follow that, while card content followed the VERTO
  # (resolve_play_locale) — and on a Verto that does not offer the visitor's
  # language the two disagreed in public: a German browser got a German
  # consent box, German buttons and <html lang="de"> over English questions.
  # The consent gate is the case that made it untenable, being a statement
  # about what THIS Verto collects rather than a button label: "the Consent
  # Box for Age and Residence still in German".
  #
  # So chrome_follows_verto_language defaults to TRUE now (and was backfilled
  # onto existing rows — see the migration). It nests a second, narrower
  # override around just this render: t() calls made while rendering (which
  # includes the layout, so <html lang/dir> and window.I18N move too) read
  # @display_locale instead, for this response only. @display_locale rather
  # than the Verto's primary on purpose — a respondent who picks another
  # content language should get the chrome that goes with what they are
  # reading, and it IS the primary until someone does. Falls back to English
  # chrome for a Verto locale with no chrome translations, via the ordinary
  # i18n fallback chain (config.i18n.fallbacks) — never a raw key.
  #
  # Turning it off is still offered, for a Verto that would rather meet each
  # respondent in their own language.
  def render_with_chrome_language
    if @survey.chrome_follows_verto_language?
      I18n.with_locale(@display_locale) { render :show }
    else
      render :show
    end
  end

  def load_survey_and_share
    token = params[:token]
    # without_report_text: the player never reads the large AI summary/report
    # columns, so skip loading them into the row on every public play request.
    if (share = SurveyShare.find_by(share_token: token))
      @survey_share = share
      @survey = Survey.without_report_text.find_by(id: share.survey_id)
    elsif (link = SurveyLink.active.find_by(slug: token))
      # A named share link. Only active ones resolve, so pausing a link takes it
      # off /play for its reads AND its writes in one step — a page loaded
      # before the pause can't keep posting answers through it.
      @survey_link = link
      @survey = Survey.without_report_text.find_by(id: link.survey_id)
    else
      # publish_token is the default opaque link; slug is the creator's
      # optional custom/vanity alternative — either resolves the same survey.
      # The slug lookup requires publish_token to be set too, so a slug never
      # makes an unpublished/draft survey reachable — it aliases the same
      # "is this Verto actually published" boundary the token itself enforces.
      @survey = Survey.without_report_text.find_by(publish_token: token) ||
                Survey.without_report_text.where.not(publish_token: nil).find_by(slug: token)
    end
  end
end
