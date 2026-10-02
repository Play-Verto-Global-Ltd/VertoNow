require "test_helper"

# Signing up for a respondent account with Google, from the end of a Verto.
#
# Three hops, and the shape of them is the point. The player page cannot start
# an OAuth round trip itself — it is service-worker cached, so its CSRF token
# can be any age, and OmniAuth's request phase is a CSRF-protected POST. So:
#
#   1. POST /play/:token/join_google  — cookie-free, parks the run's claims
#   2. GET  /you/join/:raw            — outside the worker's scope, live token
#   3. GET  /auth/google_player/callback — the account, the claims, the session
#
# What these tests hold is that no hop can be skipped or replayed into
# something it shouldn't be: a handoff is spent once, a creator account is
# never minted here, and an address Google has not verified buys nothing.
class PlayerGoogleJoinTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "W" },
    { "type" => "yes_no", "cid" => "c1", "text" => "Q?" }
  ].freeze

  def setup
    @org = Organisation.create!(name: "G", slug: "g-#{SecureRandom.hex(4)}")
    @survey = @org.surveys.create!(
      title: "Google Verto", theme: "T", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS, join_prompt_enabled: true
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # The strategy is mounted from env vars read at boot, so tests cannot turn the
  # middleware on. They can turn on what the APP checks — SocialAuth reads ENV
  # every call — which is what gates the button and the endpoint.
  def with_google
    ENV["GOOGLE_CLIENT_ID"]     = "test-id"
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"
    yield
  ensure
    ENV.delete("GOOGLE_CLIENT_ID")
    ENV.delete("GOOGLE_CLIENT_SECRET")
  end

  # Same injection SocialSignInTest uses: the controller reads request.env, and
  # without the middleware nothing else will put an auth hash there.
  def with_auth_hash(uid:, email:, name: "Ren", verified: true, provider: "google_player")
    Rails.application.env_config["omniauth.auth"] = OmniAuth::AuthHash.new(
      provider: provider, uid: uid,
      info:  { email: email, name: name },
      extra: { raw_info: { email_verified: verified } }
    )
    yield
  ensure
    Rails.application.env_config.delete("omniauth.auth")
  end

  def start_handoff(**body)
    post join_google_survey_path(@survey.publish_token),
         params: { age_confirmed: true }.merge(body).to_json, headers: { "CONTENT_TYPE" => "application/json" }
    JSON.parse(response.body)
  end

  def callback(**auth)
    with_auth_hash(**auth) { get player_oauth_callback_path }
  end

  # ── Hop 1: parking the run ────────────────────────────────────────────────

  test "the endpoint parks the claims and names the page that finishes the job" do
    resp = @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed", answered: true)

    body = with_google do
      assert_difference "PlayerOauthHandoff.count", 1 do
        start_handoff(session_token: resp.session_token, lang: "fr")
      end
    end

    assert body["ok"]
    handoff = PlayerOauthHandoff.order(:id).last
    assert_equal [ { "response_id" => resp.id, "source" => "signup" } ], handoff.claim_payload
    assert_equal @survey.id, handoff.survey_id
    assert_equal "fr", handoff.locale
    # The URL is the /you/ page, and it carries the language forward —
    # resolve_locale's ?locale= is how the pages in between stay in it.
    assert_match %r{\A/you/join/}, body["next"]
    assert_match "locale=fr", body["next"]
  end

  test "no account, no claim and no row is created by asking" do
    with_google do
      assert_no_difference [ "Player.count", "PlayerClaim.count", "PlayerIdentity.count" ] do
        start_handoff(session_token: "nope")
      end
    end
  end

  test "the endpoint refuses when Google is not configured" do
    assert_no_difference "PlayerOauthHandoff.count" do
      body = start_handoff
      assert_response :forbidden
      assert_equal "unavailable", body["error"]
    end
  end

  test "the endpoint refuses when the creator has the ask switched off" do
    @survey.update_columns(join_prompt_enabled: false)

    with_google do
      assert_no_difference "PlayerOauthHandoff.count" do
        start_handoff
        assert_response :forbidden
      end
    end
  end

  # ── Hop 2: the page that can actually start the round trip ────────────────

  test "the bounce page offers the button and remembers which run it is for" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: [], survey: @survey)

    with_google { get player_join_path(raw) }

    assert_response :success
    assert_match "/auth/google_player", response.body
    assert_match @survey.title, response.body
    assert_equal handoff.id, session[:player_oauth_handoff_id]
  end

  test "the bounce page spends nothing — a change of mind costs the tab only" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: [])

    with_google { get player_join_path(raw) }

    assert_nil handoff.reload.consumed_at
  end

  test "an expired handoff is explained rather than 404ed" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: [])
    handoff.update_column(:expires_at, 1.second.ago)

    with_google { get player_join_path(raw) }

    assert_response :success
    refute_match "/auth/google_player", response.body
    assert_match I18n.t("player_join.expired_title"), response.body
    assert_nil session[:player_oauth_handoff_id]
  end

  # ── Hop 3: the callback ───────────────────────────────────────────────────

  test "a first sign-in creates the account, links the identity and claims the run" do
    resp = @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed", answered: true)
    handoff, raw = PlayerOauthHandoff.mint!(
      claim_payload: [ { "response_id" => resp.id, "source" => "signup" } ], survey: @survey, locale: "de"
    )
    with_google { get player_join_path(raw) }

    assert_difference [ "Player.count", "PlayerIdentity.count", "PlayerClaim.count", "PlayerSession.count" ], 1 do
      callback(uid: "gp-1", email: "Ren@Example.com", name: "Ren Oso")
    end

    assert_redirected_to you_path
    player = Player.order(:id).last
    assert_equal "ren@example.com", player.email_address
    assert_equal "Ren Oso", player.name
    assert_equal "de", player.preferred_locale
    # Google has asserted the address, which is better proof than the emailed
    # link this card was built around — so the account is verified and
    # PlayerAudience will mail it.
    assert player.email_verified?, "a Google-verified address is a verified account"
    assert_equal player.id, PlayerIdentity.find_by(provider: "google_player", uid: "gp-1").player_id
    assert handoff.reload.consumed_at.present?
  end

  test "no creator account is minted on the respondent's path" do
    _handoff, raw = PlayerOauthHandoff.mint!(claim_payload: [])
    with_google { get player_join_path(raw) }

    assert_no_difference [ "User.count", "Organisation.count", "Identity.count" ] do
      callback(uid: "gp-nouser", email: "nouser@example.com")
    end
  end

  # The reason the two strategies have separate names: the path Google returns
  # to is what decides which kind of account may be created, and nothing the
  # browser carries. Asserted as ROUTING, because that is where it is decided —
  # the wildcard /auth/:provider/callback would happily swallow google_player
  # and hand a respondent to the controller that mints creator accounts, and
  # the only thing stopping it is that the specific route is declared first.
  # (OauthSessionsController refuses a player strategy too. That guard is
  # deliberately unreachable while these routes are in this order; it is there
  # so that reordering them fails visibly instead of creating a stranger's
  # workspace.)
  test "each strategy's callback reaches its own population's controller" do
    assert_routing "/auth/google_player/callback",
                   controller: "player_oauth_sessions", action: "create"
    assert_routing "/auth/google_oauth2/callback",
                   controller: "oauth_sessions", action: "create", provider: "google_oauth2"
  end

  test "a returning identity signs in without creating a second account" do
    player = Player.create!(email_address: "back-#{SecureRandom.hex(3)}@test.com")
    player.player_identities.create!(provider: "google_player", uid: "gp-back")

    assert_no_difference [ "Player.count", "PlayerIdentity.count" ] do
      callback(uid: "gp-back", email: player.email_address)
    end

    assert_redirected_to you_path
    assert_equal player.id, PlayerSession.order(:id).last.player_id
  end

  # The reason "sign in with Google" is a sign-IN and not a second account
  # beside the one they already made with a password.
  test "a verified address links Google to the account that already has it" do
    player = Player.create!(email_address: "link-#{SecureRandom.hex(3)}@test.com",
                            password: "correct-horse-battery")

    assert_no_difference "Player.count" do
      assert_difference "PlayerIdentity.count", 1 do
        callback(uid: "gp-link", email: player.email_address.upcase)
      end
    end
    assert_equal player.id, PlayerIdentity.find_by(uid: "gp-link").player_id
  end

  # An unverified address is a string somebody typed into a Google profile.
  # Treating it as a key would let a new identity walk into an existing account
  # by claiming its address.
  test "an unverified address buys nothing" do
    Player.create!(email_address: "target-unverified@test.com", password: "correct-horse-battery")

    assert_no_difference [ "Player.count", "PlayerIdentity.count", "PlayerSession.count" ] do
      callback(uid: "gp-spoof", email: "target-unverified@test.com", verified: false)
    end
    assert_redirected_to new_player_session_path
  end

  test "a handoff is spent once, so a replayed return claims nothing twice" do
    resp = @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed", answered: true)
    _handoff, raw = PlayerOauthHandoff.mint!(
      claim_payload: [ { "response_id" => resp.id, "source" => "signup" } ], survey: @survey
    )
    with_google { get player_join_path(raw) }
    callback(uid: "gp-replay", email: "replay@example.com")

    # Back through the callback with the same handoff id still in the session
    # would be the double-claim; the session no longer holds one, and the row
    # is spent either way.
    assert_no_difference "PlayerClaim.count" do
      callback(uid: "gp-replay", email: "replay@example.com")
    end
  end

  # Being signed in is worth more than the one run that brought them here, and
  # that run is reclaimable by playing it again.
  test "an expired handoff still signs them in" do
    handoff, raw = PlayerOauthHandoff.mint!(claim_payload: [])
    with_google { get player_join_path(raw) }
    handoff.update_column(:expires_at, 1.second.ago)

    assert_difference "Player.count", 1 do
      callback(uid: "gp-late", email: "late@example.com")
    end
    assert_redirected_to you_path
  end

  test "a declined consent screen sends them to their own door, not the creator's" do
    get "/auth/failure", params: { strategy: "google_player" }

    assert_redirected_to new_player_session_path
    assert_match "Google", flash[:alert]
  end

  # ── The two doors on the card ─────────────────────────────────────────────

  test "the card shows the Google button and the sign-in link only when configured" do
    # The endpoint PATH, not the string "join_google" — that also appears as an
    # i18n key name in the page's JS payload, which is there either way.
    endpoint = "/join_google"

    get play_survey_path(@survey.publish_token)
    assert_response :success
    # No message argument: assert_select's second positional is an equality
    # test against the matched element's text, not a failure message.
    assert_select "[data-player-join-google-url-value='']"
    assert_match new_player_session_path, response.body,
                 "the sign-in door does not depend on Google and must always be there"

    with_google { get play_survey_path(@survey.publish_token) }
    assert_response :success
    assert_match endpoint, response.body
    assert_select "[data-player-join-google-url-value=?]",
                  join_google_survey_url(@survey.publish_token)
  end

  # Derived from join_url rather than rebuilt beside it, so every condition
  # that blanks the one blanks the other. (Owner preview and Test Mode are
  # swept wholesale by TestModeTest, which asserts every data-player-*-url-value
  # on those pages is empty — this attribute is covered there by construction.)
  test "the ask being off takes the Google endpoint with it" do
    @survey.update_columns(join_prompt_enabled: false)

    with_google { get play_survey_path(@survey.publish_token) }

    assert_select "[data-player-join-google-url-value='']"
  end

  test "the respondent sign-in page offers Google as well as the password" do
    get new_player_session_path
    assert_response :success
    refute_match "/auth/google_player", response.body

    with_google { get new_player_session_path }
    assert_response :success
    assert_match "/auth/google_player", response.body
    assert_select "input[type=password]", 1, "the password form stays — Google is an addition, not a replacement"
  end

  # There is no respondent password reset, so a Google account meeting the
  # password form is a dead end unless it is told which door it has.
  test "a Google account typing a password is told to use Google" do
    player = Player.create!(email_address: "gonly-#{SecureRandom.hex(3)}@test.com")
    player.player_identities.create!(provider: "google_player", uid: "gp-only")
    player.verify_email!

    post join_survey_path(@survey.publish_token),
         params: { email: player.email_address, password: "correct-horse-battery", age_confirmed: true }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :unauthorized
    assert_equal "use_google", JSON.parse(response.body)["error"]
  end
end
