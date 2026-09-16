require "test_helper"

# The emailed link, which is the only way into a respondent account.
#
# The properties that matter are the ones a password flow gets for free and
# this one has to earn: a link works ONCE, a link EXPIRES, and — the reason
# GET and POST are split — merely loading the page consumes nothing.
class PlayerSignInTest < ActionDispatch::IntegrationTest
  def player = Player.for_email("p-#{SecureRandom.hex(3)}@test.com")

  def survey_with_response
    org = Organisation.create!(name: "O", slug: "psi-#{SecureRandom.hex(3)}")
    s = org.surveys.create!(title: "T", theme: "Car-free High Street", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      join_prompt_enabled: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    r = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    [ s, r ]
  end

  def link_for(pl, payload = [])
    PlayerSignInLink.mint!(player: pl, claim_payload: payload)
  end

  # ── GET consumes nothing ──────────────────────────────────────────────────
  # Corporate link scanners and inbox prefetchers follow GETs. If the GET
  # signed anyone in, a scanner would spend the link before its recipient ever
  # saw the email.

  test "loading the page does not consume the link" do
    pl = player
    link, raw = link_for(pl)

    get player_sign_in_path(raw)

    assert_response :success
    assert_nil link.reload.consumed_at, "a scanner following this GET must not burn the link"
    assert_nil cookies[:player_session_id].presence, "and it must not sign anyone in"
  end

  test "the POST signs in, verifies the address and lands on the account" do
    pl = player
    _link, raw = link_for(pl)

    post player_sign_in_path(raw)

    assert_redirected_to you_path
    assert pl.reload.email_verified?, "following a link from your own inbox is the only proof we get"
    assert_equal 1, pl.player_sessions.count
  end

  # ── Once, and only once ───────────────────────────────────────────────────

  test "a link cannot be used twice" do
    pl = player
    _link, raw = link_for(pl)

    post player_sign_in_path(raw)
    assert_redirected_to you_path

    reset!
    post player_sign_in_path(raw)

    assert_response :unprocessable_entity
    assert_equal 1, pl.reload.player_sessions.count,
      "a replayed link must not mint a second session"
  end

  test "requesting a second link does not kill the first" do
    pl = player
    _a, raw_a = link_for(pl)
    _b, raw_b = link_for(pl)

    post player_sign_in_path(raw_a)
    assert_redirected_to you_path, "asking for a second link and then clicking the first is an " \
      "ordinary thing to do — rotating a shared salt would have broken it"

    reset!
    post player_sign_in_path(raw_b)
    assert_redirected_to you_path
  end

  test "an expired link is refused" do
    pl = player
    _link, raw = link_for(pl)

    travel PlayerSignInLink::LIFETIME + 1.minute do
      post player_sign_in_path(raw)
      assert_response :unprocessable_entity
      assert_equal 0, pl.reload.player_sessions.count
    end
  end

  test "a garbage token shows the friendly page rather than crashing" do
    get player_sign_in_path("not-a-real-token")
    assert_response :success
    assert_match I18n.t("player_sign_in.spent_title"), response.body

    post player_sign_in_path("not-a-real-token")
    assert_response :unprocessable_entity
  end

  # ── The claims ride the link ──────────────────────────────────────────────
  # Nothing is written against an address until someone proves they can read
  # it, so the payload is carried by the link and spent here.

  test "signing in attaches the Vertos the link was minted for" do
    s, r = survey_with_response
    pl = player
    _link, raw = link_for(pl, [ { "survey_id" => s.id, "response_id" => r.id, "source" => "signup" } ])

    assert_equal 0, pl.player_claims.count, "typing an address must attach nothing"

    post player_sign_in_path(raw)

    assert_equal 1, pl.reload.player_claims.count
    claim = pl.player_claims.first
    assert_equal s.id, claim.survey_id
    assert_equal "signup", claim.source
  end

  test "a claim whose response has since been erased does not break the sign-in" do
    s, r = survey_with_response
    pl = player
    _link, raw = link_for(pl, [ { "survey_id" => s.id, "response_id" => r.id, "source" => "signup" } ])
    r.destroy

    post player_sign_in_path(raw)

    assert_redirected_to you_path, "they are signing in; a Verto that went away must not stop them"
    assert_equal 0, pl.reload.player_claims.count
  end

  test "claiming is idempotent across two links for the same run" do
    s, r = survey_with_response
    pl = player
    payload = [ { "survey_id" => s.id, "response_id" => r.id, "source" => "signup" } ]
    _a, raw_a = link_for(pl, payload)
    _b, raw_b = link_for(pl, payload)

    post player_sign_in_path(raw_a)
    reset!
    post player_sign_in_path(raw_b)

    assert_equal 1, pl.reload.player_claims.count,
      "the unique index is what makes a replay a no-op rather than a duplicate"
  end

  # ── The token is never stored ─────────────────────────────────────────────

  # ── A signup link continues on its own ────────────────────────────────────
  # It was handed straight back to this browser on the end screen, so there is
  # nobody to confirm it to. The tap had a measured cost on 15 September: of
  # the people who typed an address and a password, 15 of 39 in a room never
  # pressed it, against 1 of 14 away from one.

  def signup_link_for(pl)
    PlayerSignInLink.mint!(player: pl, origin: PlayerSignInLink::ORIGIN_SIGNUP)
  end

  test "a signup link's page continues on its own" do
    _link, raw = signup_link_for(player)

    get player_sign_in_path(raw)

    assert_response :success
    assert_select "form#player-sign-in-continue", 1,
                  "the POST is still what signs anyone in — it is not being bypassed"
    assert_match(/requestSubmit/, response.body,
                 "a signup link should not wait for a tap nobody needs to make")
  end

  test "an emailed link still waits for a human" do
    link, raw = link_for(player)

    get player_sign_in_path(raw)

    assert_response :success
    refute_match(/requestSubmit/, response.body,
                 "an emailed link is confirmed by whoever went and fetched it — auto-continuing " \
                 "would hand the account to the first link scanner that follows the GET")
    assert_nil link.reload.consumed_at
  end

  test "losing the consume race does not re-arm the auto-continue" do
    # #create renders :show with @link STILL PRESENT when find_live returned a
    # live link and consume! then lost to a concurrent request. If the template
    # decided to auto-continue from the link alone, that render would post,
    # fail, re-render and post again — forever. The flag is set in #show, which
    # this path never runs.
    link, raw = signup_link_for(player)
    loser = PlayerSignInLink.find(link.id)
    def loser.consume! = false

    stub_method(PlayerSignInLink, :find_live, ->(*_a) { loser }) do
      post player_sign_in_path(raw)
    end

    assert_response :unprocessable_entity
    refute_match(/requestSubmit/, response.body, "this would be an endless submit loop")
  end

  test "only the digest is kept, so a leaked row is not a working link" do
    pl = player
    link, raw = link_for(pl)

    assert_not_equal raw, link.token_digest
    assert_not PlayerSignInLink.column_names.include?("token"),
      "storing the token would make the database a set of live credentials"
    assert_equal link.id, PlayerSignInLink.find_live(raw).id
  end
end
