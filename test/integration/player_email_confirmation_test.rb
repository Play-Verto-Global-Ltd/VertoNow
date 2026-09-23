require "test_helper"

# The address confirmation a password signup is sent, and the way through
# PlayerAudience's verified-only gate it opens.
#
# Three properties carry this file. The mail goes out only when #join has just
# created an account — never for someone signing back in, never for a wrong
# password — so an address can be written to this way once. Following the link
# stamps email_verified_at and nothing else: no session is started and nothing
# was ever waiting on it. And the resend only ever mails the account you are
# already inside.
class PlayerEmailConfirmationTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct-horse-battery"

  def org(name = "Haverley Town Council") = Organisation.create!(name: name, slug: "pec-#{SecureRandom.hex(3)}")

  def survey
    org.surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      join_prompt_enabled: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def address = "pec-#{SecureRandom.hex(4)}@test.com"

  def join(s, email:, password: PASSWORD)
    post join_survey_path(s.publish_token), params: { email: email, password: password }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  # Joins, then follows the handed-back link the way the card does: the
  # password door, signed in, address unproven.
  def join_and_sign_in(s = survey, email: address)
    join(s, email: email)
    post JSON.parse(response.body)["next"]
    Player.find_by(email_address: email)
  end

  def confirmation_jobs
    enqueued_jobs.select do |job|
      job["job_class"] == "ActionMailer::MailDeliveryJob" &&
        job["arguments"].first == "PlayerEmailConfirmationMailer"
    end
  end

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  # ── Sent from #join ────────────────────────────────────────────────────────

  test "a new account is sent one confirmation, about the Verto it was made on" do
    s = survey
    join(s, email: address)

    assert_response :success
    assert_equal 1, confirmation_jobs.size
    args = confirmation_jobs.first["arguments"]
    assert_equal "confirm", args[1]
  end

  test "signing back in with the right password sends nothing" do
    s = survey
    email = address
    join(s, email: email)
    clear_enqueued_jobs

    join(s, email: email)

    assert_response :success
    assert_empty confirmation_jobs, "an existing account authenticating is not first contact"
  end

  test "a wrong password sends nothing" do
    s = survey
    email = address
    join(s, email: email)
    clear_enqueued_jobs

    join(s, email: email, password: "a-different-password")

    assert_response :unauthorized
    assert_empty confirmation_jobs
  end

  test "an adoptable shell given a password is sent one, as a new account would be" do
    email = address
    Player.for_email(email)

    join(survey, email: email)

    assert_equal 1, confirmation_jobs.size
  end

  test "no working mail: the account is made and nothing is promised" do
    stub_method(MailConfigCheck, :deliverable?, ->(*) { false }) do
      email = address
      join(survey, email: email)

      assert_response :success
      assert Player.exists?(email_address: email)
      assert_empty confirmation_jobs
    end
  end

  test "a suppressed address is not sent one" do
    email = address
    EmailSuppression.record!(email, reason: "hard_bounce")

    join(survey, email: email)

    assert_response :success
    assert_empty confirmation_jobs, "a bounced address only spends the sending domain's reputation"
  end

  test "past the unscaled per-IP mail cap the account is still made, silently unmailed" do
    with_memory_cache do
      Rails.cache.write("join_confirm:ip:127.0.0.1",
                        PlayerController::MAX_JOIN_CONFIRMATIONS_PER_IP, raw: true)
      email = address
      join(survey, email: email)

      assert_response :success
      assert Player.exists?(email_address: email), "the cap bounds mail, not accounts"
      assert_empty confirmation_jobs
    end
  end

  test "the mail cap does not move with the venue lever" do
    assert_equal 30, PlayerController::MAX_JOIN_CONFIRMATIONS_PER_IP
    refute_includes File.read(Rails.root.join("app/controllers/player_controller.rb"))[/MAX_JOIN_CONFIRMATIONS_PER_IP = .*/],
                    "JOIN_RATE_LIMIT_SCALE"
  end

  # ── The link ───────────────────────────────────────────────────────────────

  test "signed in, the link confirms and goes straight to the dashboard" do
    pl = join_and_sign_in

    get player_email_confirmation_path(pl.generate_token_for(:email_confirmation))

    assert_redirected_to you_path
    assert_not_nil pl.reload.email_verified_at
    follow_redirect!
    assert_select ".you-flash.is-notice .you-flash-title", text: I18n.t("player_email_confirmation.confirmed_title")
    assert_select ".you-flash-detail", text: I18n.t("player_email_confirmation.confirmed_body")
    assert_select ".you-confirm", 0, "the banner asking for it is gone once it is done"
  end

  test "signed out, it confirms without signing anyone in and sends them to sign in" do
    pl = Player.create!(email_address: address, password: PASSWORD)

    get player_email_confirmation_path(pl.generate_token_for(:email_confirmation))

    assert_redirected_to new_player_session_path
    assert_not_nil pl.reload.email_verified_at
    assert_nil cookies[:player_session_id].presence, "a week-long reusable token must not be a way in"
    follow_redirect!
    assert_select ".you-flash-title", text: I18n.t("player_email_confirmation.confirmed_title")

    post new_player_session_path, params: { email_address: pl.email_address, password: PASSWORD }
    assert_redirected_to you_path, "and signing in lands on the dashboard"
  end

  test "signed in as someone else, it confirms the mail's account, not theirs" do
    other = join_and_sign_in
    pl = Player.create!(email_address: address, password: PASSWORD)

    get player_email_confirmation_path(pl.generate_token_for(:email_confirmation))

    assert_redirected_to new_player_session_path
    assert pl.reload.email_verified?
    assert_not other.reload.email_verified?
  end

  test "opened twice, it says so and does not move the date" do
    pl = Player.create!(email_address: address, password: PASSWORD)
    token = pl.generate_token_for(:email_confirmation)
    get player_email_confirmation_path(token)
    first = pl.reload.email_verified_at

    travel 1.hour do
      get player_email_confirmation_path(token)
    end

    assert_equal I18n.t("player_email_confirmation.already_title"), flash[:notice]
    assert_equal first, pl.reload.email_verified_at
  end

  test "a made-up or expired token confirms nothing and echoes no address" do
    pl = Player.create!(email_address: address, password: PASSWORD)
    token = pl.generate_token_for(:email_confirmation)

    get player_email_confirmation_path("not-a-token")
    assert_response :not_found
    assert_select "h1", text: I18n.t("player_email_confirmation.invalid_title")

    travel Player::CONFIRMATION_LIFETIME + 1.minute do
      get player_email_confirmation_path(token)
    end
    assert_response :not_found
    assert_nil pl.reload.email_verified_at
    assert_no_match pl.email_address, response.body
  end

  test "changing the address voids a link still sitting in the old inbox" do
    pl = Player.create!(email_address: address, password: PASSWORD)
    token = pl.generate_token_for(:email_confirmation)
    pl.update!(email_address: address)

    get player_email_confirmation_path(token)

    assert_response :not_found
    assert_nil pl.reload.email_verified_at
  end

  # The point of the whole feature: a password signup that has kept a Verto is
  # outside the creator's audience until it confirms, and inside it after.
  test "confirming is what puts a password signup into the creator's audience" do
    s = survey
    s.responses.create!(session_token: (token = SecureRandom.uuid), status: "completed", answered: true)
    email = address
    post join_survey_path(s.publish_token),
         params: { email: email, password: PASSWORD, session_token: token }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    post JSON.parse(response.body)["next"]
    pl = Player.find_by(email_address: email)
    assert pl.player_claims.exists?(survey_id: s.id), "precondition: the run was kept"
    assert_not_includes PlayerAudience.for_survey(s), pl

    get player_email_confirmation_path(pl.generate_token_for(:email_confirmation))

    assert_includes PlayerAudience.for_survey(s), pl.reload
    assert PlayerAudience.deliverable?(pl, s)
  end

  # ── The resend, and /you ───────────────────────────────────────────────────

  test "/you asks an unconfirmed password account to confirm, with a button" do
    join_and_sign_in

    get you_path

    assert_select ".you-confirm", 1
    assert_select ".you-confirm-title", text: I18n.t("you.confirm_title")
    assert_select ".you-confirm form[action=?]", player_email_confirmations_path
  end

  test "signed out, /you draws its explainer and no banner" do
    get you_path

    assert_response :success
    assert_select ".you-confirm", 0
  end

  test "/you says nothing to a confirmed account" do
    pl = join_and_sign_in
    pl.verify_email!

    get you_path

    assert_select ".you-confirm", 0
  end

  test "/you offers no button when no mail can go out" do
    join_and_sign_in

    stub_method(MailConfigCheck, :deliverable?, ->(*) { false }) do
      get you_path
    end

    assert_select ".you-confirm", 0
  end

  test "a suppressed address is told why, and offered no button" do
    pl = join_and_sign_in
    EmailSuppression.record!(pl.email_address, reason: "complaint")

    get you_path

    assert_select ".you-confirm", 1
    assert_select ".you-confirm form", 0
    assert_select ".you-confirm-body", text: /#{Regexp.escape(pl.email_address)}/
  end

  test "the account page marks the address Not confirmed" do
    join_and_sign_in

    get you_account_path

    assert_select ".you-tag.is-amber", text: I18n.t("you.email_unconfirmed")
    assert_select "#profile .you-confirm form[action=?]", player_email_confirmations_path
  end

  test "the resend mails the signed-in account and nothing else" do
    pl = join_and_sign_in
    clear_enqueued_jobs

    post player_email_confirmations_path, params: { email: "someone-else@test.com" }

    assert_redirected_to you_path
    assert_equal 1, confirmation_jobs.size
    player_arg = confirmation_jobs.first["arguments"][3]["args"].first
    assert_equal pl.to_global_id.to_s, player_arg["_aj_globalid"]
    assert_equal I18n.t("player_email_confirmation.resent", email: pl.email_address), flash[:notice]
  end

  test "the resend is for signed-in accounts only" do
    post player_email_confirmations_path

    assert_redirected_to you_path
    assert_empty confirmation_jobs
  end

  test "a confirmed account's resend sends nothing" do
    pl = join_and_sign_in
    pl.verify_email!
    clear_enqueued_jobs

    post player_email_confirmations_path

    assert_empty confirmation_jobs
    assert_equal I18n.t("player_email_confirmation.already_confirmed"), flash[:notice]
  end

  test "one account can cause at most three confirmation mails a day" do
    with_memory_cache do
      join_and_sign_in
      # The join's own mail is the first of the three.
      2.times { post player_email_confirmations_path }
      assert_equal 3, confirmation_jobs.size

      post player_email_confirmations_path

      assert_equal 3, confirmation_jobs.size
      assert_equal I18n.t("player_email_confirmation.too_many"), flash[:alert]
    end
  end
end
