require "test_helper"

# The join endpoint and what it is allowed to hand out.
#
# Two properties carry this file. The first is that nothing is written against
# an address until someone proves they can read it — the join call parks a
# payload on a link and stops. The second is that every refusal looks like a
# success: unknown address, blank address, join switched off, a Verto that
# isn't yours. An endpoint that answers differently for an address it has seen
# before is an endpoint that confirms addresses.
class PlayerClaimsTest < ActionDispatch::IntegrationTest
  def org = Organisation.create!(name: "O", slug: "pc-#{SecureRandom.hex(3)}")

  def survey(owner: nil, join: true, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      join_prompt_enabled: join,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def completed(s, key: nil)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        player_key_digest: key ? s.player_key_digest(key) : nil)
  end

  # Long enough for Player::MIN_PASSWORD, and the same one everywhere so a test
  # that cares about the password says so explicitly.
  PASSWORD = "correct-horse-battery"

  def join(s, password: PASSWORD, **payload)
    post join_survey_path(s.publish_token), params: payload.merge(password: password).to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  def address = "pc-#{SecureRandom.hex(4)}@test.com"

  # The raw token out of the join RESPONSE. It used to come out of an email;
  # the endpoint hands it straight back now, because the player page is
  # cached by the service worker and a session cookie written under
  # null_session would be silently dropped (see PlayerController#join).
  def handed_token
    JSON.parse(response.body)["next"].to_s[%r{/you/sign-in/([\w\-]+)}, 1]
  end

  # The link the join just minted, and the claims parked on it.
  def payload_of(email)
    PlayerSignInLink.joins(:player).where(players: { email_address: email }).last&.claim_payload
  end

  # ── Nothing is written against an address that hasn't answered ────────────

  test "joining mints a link and claims nothing yet" do
    s = survey
    r = completed(s)
    email = address

    assert_difference -> { PlayerSignInLink.count }, 1 do
      assert_no_difference -> { PlayerClaim.count } do
        join(s, email: email, session_token: r.session_token)
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_match %r{\A/you/sign-in/[\w\-]+\z}, body["next"],
                 "the link is handed back for the client to follow, not emailed"
    assert_equal [ r.id ], payload_of(email).map { |c| c["response_id"] }
  end

  test "the run just finished is claimed once the link is followed" do
    s = survey
    r = completed(s)
    email = address
    join(s, email: email, session_token: r.session_token)

    post player_sign_in_path(handed_token)

    claim = Player.find_by(email_address: email).player_claims.sole
    assert_equal r.id, claim.response_id
    assert_equal s.id, claim.survey_id
    assert_equal "signup", claim.source
  end

  # ── Device keys reach back to earlier Vertos, and only your own ───────────

  test "a device key claims that Verto's completed runs" do
    o = org
    first  = survey(owner: o)
    second = survey(owner: o)
    key    = SecureRandom.uuid
    earlier = completed(first, key: key)
    now     = completed(second)
    email   = address

    join(second, email: email, session_token: now.session_token,
                 device_keys: [ { token: first.publish_token, player_key: key } ])

    ids = payload_of(email).map { |c| c["response_id"] }
    assert_equal [ now.id, earlier.id ].sort, ids.sort
    assert_equal "device_key", payload_of(email).find { |c| c["response_id"] == earlier.id }["source"]
  end

  test "a key lifted from one Verto resolves to nothing on another" do
    o = org
    mine     = survey(owner: o)
    stranger = survey(owner: o)
    key      = SecureRandom.uuid
    # The key belongs to `mine`; the stranger's rows carry the SAME raw key,
    # digested under the stranger's own per-survey HMAC.
    completed(mine, key: key)
    theirs = completed(stranger, key: key)
    email  = address

    # Ask for the stranger's Verto with a key digested for `mine`.
    join(mine, email: email,
               device_keys: [ { token: stranger.publish_token, player_key: "#{key}-not-mine" } ])

    refute_includes payload_of(email).map { |c| c["response_id"] }, theirs.id
  end

  test "an unresolvable token is skipped, not fatal" do
    s = survey
    r = completed(s)
    email = address

    join(s, email: email, session_token: r.session_token,
            device_keys: [ { token: "no-such-verto", player_key: SecureRandom.uuid } ])

    assert_response :success
    assert_equal [ r.id ], payload_of(email).map { |c| c["response_id"] }
  end

  test "a session token from another Verto claims nothing" do
    o = org
    mine  = survey(owner: o)
    other = survey(owner: o)
    theirs = completed(other)
    email  = address

    join(mine, email: email, session_token: theirs.session_token)

    assert_empty payload_of(email)
  end

  # ── Idempotency ───────────────────────────────────────────────────────────

  test "following the same claim twice is a no-op" do
    s = survey
    r = completed(s)
    pl = Player.for_email(address)

    2.times do
      _link, raw = PlayerSignInLink.mint!(
        player: pl, claim_payload: [ { "response_id" => r.id, "source" => "signup" } ])
      post player_sign_in_path(raw)
    end

    assert_equal 1, pl.player_claims.count, "the unique index makes a replay a no-op"
  end

  # ── Signing up with a password ────────────────────────────────────────────
  #
  # The endpoint used to answer identically for every refusal so that it could
  # never confirm whether an address was already known. A password cannot work
  # that way — "we made you an account" and "that is not your password" are
  # different outcomes and the person has to be told which — so that property
  # was given up on the owner's instruction (2026-09-10). What follows is the
  # contract that replaced it. The one mail this endpoint sends is the address
  # confirmation, and only when it has just created an account.
  #
  # assert_enqueued_emails, not a count of ActionMailer::Base.deliveries: the
  # test queue adapter never performs a deliver_later, so a deliveries count
  # would go on reading zero whatever this endpoint started sending.

  test "a new address gets an account, a password, a link to spend and one confirmation mail" do
    s = survey
    email = address

    assert_difference [ -> { Player.count }, -> { PlayerSignInLink.count } ], 1 do
      assert_enqueued_emails 1 do
        join(s, email: email)
      end
    end

    assert_response :success
    player = Player.find_by(email_address: email)
    assert player.authenticate(PASSWORD), "the password typed at the end card is the account's"
    assert_nil player.email_verified_at,
               "nothing has proved this address — only a link out of an inbox does that"
  end

  test "the handed-back link signs in without verifying the address" do
    s = survey
    email = address
    join(s, email: email)

    post player_sign_in_path(handed_token)

    player = Player.find_by(email_address: email)
    assert_nil player.reload.email_verified_at,
               "a signup link proves somebody typed the address, not that they can read it"
    assert_equal PlayerSignInLink::ORIGIN_SIGNUP,
                 PlayerSignInLink.joins(:player).where(players: { email_address: email }).last.origin
  end

  test "an emailed link still verifies the address" do
    # The distinction the origin column exists for: PlayerAudience.for_survey
    # will not mail an unverified address, so getting this backwards would
    # either mail people who never proved an address or mail nobody at all.
    pl = Player.for_email(address)
    _link, raw = PlayerSignInLink.mint!(player: pl, origin: PlayerSignInLink::ORIGIN_EMAIL)

    post player_sign_in_path(raw)

    assert_not_nil pl.reload.email_verified_at
  end

  test "a returning address with the right password signs in and claims again" do
    s = survey
    email = address
    join(s, email: email)                      # first visit, account created
    first = Player.find_by(email_address: email)

    later = completed(s)
    assert_no_difference -> { Player.count } do
      join(s, email: email, session_token: later.session_token)
    end

    assert_response :success
    assert_equal first.id, Player.find_by(email_address: email).id
    assert_equal [ later.id ], payload_of(email).map { |c| c["response_id"] }
  end

  test "a returning address with the wrong password is refused" do
    s = survey
    email = address
    join(s, email: email)

    assert_no_difference -> { PlayerSignInLink.count } do
      join(s, email: email, password: "not-the-right-one")
    end

    assert_response :unauthorized
    assert_equal "credentials", JSON.parse(response.body)["error"]
  end

  test "a passwordless shell from the emailed-link era may be adopted" do
    # Player.for_email left one of these behind on every join attempt while the
    # emailed link was the only way in — and the mail was failing, so that is
    # every attempt ever made. Nothing is on them, so there is nothing to take.
    s = survey
    email = address
    shell = Player.for_email(email)
    assert_nil shell.password_digest
    assert shell.adoptable?

    join(s, email: email)

    assert_response :success
    assert shell.reload.authenticate(PASSWORD)
  end

  test "a shell that has claims or a proven address is not adoptable" do
    s = survey
    r = completed(s)

    with_claims = Player.for_email(address)
    PlayerClaim.claim!(player: with_claims, response: r, source: "signup")
    assert_not with_claims.reload.adoptable?, "claims on the row make it a real account"

    verified = Player.for_email(address)
    verified.verify_email!
    assert_not verified.reload.adoptable?, "a proven address makes it a real account"

    join(s, email: verified.email_address)
    assert_response :unauthorized,
                    "adopting a proven address would be a takeover of it"
  end

  test "a password under the minimum is refused before anything is written" do
    s = survey
    email = address

    assert_no_difference [ -> { Player.count }, -> { PlayerSignInLink.count } ] do
      join(s, email: email, password: "a" * (Player::MIN_PASSWORD - 1))
    end

    assert_equal "password_short", JSON.parse(response.body)["error"]
  end

  test "a Verto with join switched off refuses and creates no player" do
    s = survey(join: false)
    email = address

    assert_no_difference [ -> { Player.count }, -> { PlayerSignInLink.count } ] do
      join(s, email: email)
    end
    assert_response :forbidden
  end

  test "a blank or malformed address creates nothing" do
    s = survey

    assert_no_difference [ -> { Player.count }, -> { PlayerSignInLink.count } ] do
      join(s, email: "")
      join(s, email: "nope")
      join(s, email: "two words@example.com")
    end
  end

  # ── The endpoint's shape ──────────────────────────────────────────────────

  test "join sets no cookie" do
    s = survey
    join(s, email: address)

    assert_nil cookies[:player_session_id].presence,
               "the join endpoint runs under null_session, where a cookie write is " \
               "silently dropped on a failed CSRF check — which is exactly why the " \
               "session is established by spending the handed-back link instead"
  end

  test "join writes no player_key_digest onto the finished run" do
    # A digest written only for joiners would populate the creator's "Device
    # group" CSV column for exactly the people who opted in, and would let a
    # later leaderboard enable build a board out of joiners alone.
    s = survey
    r = completed(s)

    join(s, email: address, session_token: r.session_token,
            device_keys: [ { token: s.publish_token, player_key: SecureRandom.uuid } ])

    assert_nil r.reload.player_key_digest
  end

  test "an unknown play token is a 404, and a closed Verto is gone" do
    post join_survey_path("nope"), params: { email: address }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found

    s = survey
    s.update_column(:unpublished_at, 1.hour.ago)
    join(s, email: address)
    assert_response :gone
  end

  test "the address is remembered as the account's locale on the first join only" do
    s = survey(locales: [ "en", "fr" ])
    email = address

    join(s, email: email, lang: "fr")
    assert_equal "fr", Player.find_by(email_address: email).preferred_locale

    join(s, email: email, lang: "en")
    assert_equal "fr", Player.find_by(email_address: email).preferred_locale,
                 "a later join must not move a preference the account already holds"
  end
end
