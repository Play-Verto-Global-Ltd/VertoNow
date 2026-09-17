require "test_helper"

# Whether the product can tell that a signed-in account is still being used.
#
# Until this existed it could not. A Session row was written at sign-in and
# never again, so "last active" meant "last signed in" — and the gap between
# those two is the whole working life of a login. Worse, it is READING that
# goes missing: creating, editing, sharing and inviting each leave a row of
# their own, while opening the results of a Verto that is already collecting
# writes nothing anywhere. That is most of what a customer does once their
# Verto is live, so the accounts this under-counted hardest were the ones
# furthest along.
class SessionActivityTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword"

  setup do
    @user = User.create!(name: "U", email_address: "sa-#{SecureRandom.hex(3)}@test.com",
                         password: PASSWORD)
    org = Organisation.create!(name: "O", slug: "sa-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: PASSWORD }
    @session = @user.sessions.first
  end

  test "reading a page records that the account is still being used" do
    # This GET writes nothing else anywhere, which is exactly the case that
    # was invisible.
    @session.update_column(:updated_at, 3.days.ago)

    get root_path

    assert_response :success
    assert_operator @session.reload.updated_at, :>, 1.minute.ago,
      "a signed-in page view is the only trace a reader leaves"
  end

  test "a busy hour is one write, not one per request" do
    @session.update_column(:updated_at, 3.days.ago)
    get root_path
    first = @session.reload.updated_at

    5.times { get root_path }

    assert_equal first.to_f, @session.reload.updated_at.to_f,
      "a session already seen this hour must not be written again — resume_session " \
      "runs on every request, and authenticated? calls it again on every render"
  end

  test "the stamp moves again once the window has passed" do
    get root_path
    @session.update_column(:updated_at, (Session::SEEN_EVERY + 1.minute).ago)

    get root_path

    assert_operator @session.reload.updated_at, :>, 1.minute.ago
  end

  test "resuming a session still gates access" do
    # touch_seen! sits inside resume_session, whose return value is what
    # require_authentication and authenticated? read as a truthy check.
    reset!

    get root_path

    assert_redirected_to new_session_path
  end

  test "a session deleted mid-request does not break the response" do
    @session.update_column(:updated_at, 3.days.ago)
    stale = Session.find(@session.id)
    Session.where(id: @session.id).delete_all

    assert_nothing_raised { stale.touch_seen! }
  end
end
