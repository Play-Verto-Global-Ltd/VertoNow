require "test_helper"

# The client accounts a Playverto staff member works in — the data behind the
# Clients dashboard and the staff shape of the Workspaces picker.
class ClientWorkspacesTest < ActiveSupport::TestCase
  def setup
    @playverto = Organisation.find_or_create_by!(slug: PlayvertoStaff::SLUG) { |o| o.name = "Playverto" }
    @staff = User.create!(name: "Nick", email_address: "cw-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    @playverto.memberships.create!(user: @staff, role: "admin")

    @a = client!("Alpbach")
    @b = client!("Bristol Trust")
    @c = client!("Cardiff FC")
  end

  def client!(name)
    org = Organisation.create!(name: name, slug: "cw-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: @staff, role: "admin")
    org
  end

  # `answered` is derived from the answers on save (Response#sync_answered).
  def respond(survey, status: "completed")
    survey.responses.create!(session_token: SecureRandom.uuid, status: status,
                             answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
  end

  def visited!(org, at)
    @staff.memberships.find_by(organisation: org).update_column(:last_visited_at, at)
  end

  test "for lists every account but Playverto, recent first, then never-opened by name" do
    visited!(@c, 1.hour.ago)
    visited!(@a, 1.day.ago)

    assert_equal [ @c, @a, @b ], ClientWorkspaces.for(@staff).map(&:organisation)
  end

  test "for hands back memberships, so the role beside each name is this person's" do
    assert_equal %w[admin admin admin], ClientWorkspaces.for(@staff).map(&:role)
    assert ClientWorkspaces.for(@staff).all?(Membership)
  end

  test "recent_for is the two most recently opened clients, newest first" do
    visited!(@a, 3.hours.ago)
    visited!(@b, 1.hour.ago)
    visited!(@c, 2.hours.ago)

    assert_equal [ @b, @c ], ClientWorkspaces.recent_for(@staff).map(&:organisation)
  end

  test "recent_for leaves out a client that has never been opened" do
    visited!(@a, 1.hour.ago)

    assert_equal [ @a ], ClientWorkspaces.recent_for(@staff).map(&:organisation)
    assert_empty ClientWorkspaces.recent_for(User.create!(name: "N", email_address: "cw-n-#{SecureRandom.hex(3)}@test.com",
                                                          password: "verylongpassword"))
  end

  # The throttled touch can leave the account being acted in with an older
  # stamp than two others; it is still the one on screen, so it leads.
  test "recent_for puts the acting client first even when its stamp is older" do
    visited!(@a, 3.hours.ago)
    visited!(@b, 1.hour.ago)
    visited!(@c, 2.hours.ago)

    assert_equal [ @a, @b ], ClientWorkspaces.recent_for(@staff, current_organisation: @a).map(&:organisation)
  end

  test "recent_for never counts Playverto as a client, current or not" do
    visited!(@a, 1.hour.ago)

    assert_equal [ @a ], ClientWorkspaces.recent_for(@staff, current_organisation: @playverto).map(&:organisation)
  end

  test "recent_for does not lift a stranger's account into the list" do
    other = Organisation.create!(name: "Not mine", slug: "cw-x-#{SecureRandom.hex(3)}")

    assert_empty ClientWorkspaces.recent_for(@staff, current_organisation: other)
  end

  test "stats_for counts kept Vertos, live ones, responders and completions per account" do
    live = @a.surveys.create!(title: "L", theme: "T", audience_age: "a", key_insight: "k",
                              default_locale: "en", locales: [ "en" ], publish_token: "tok-#{SecureRandom.hex(4)}")
    @a.surveys.create!(title: "D", theme: "T", audience_age: "a", key_insight: "k", default_locale: "en", locales: [ "en" ])
    # Closed: published once, taken off /play since. Kept, but not live.
    @a.surveys.create!(title: "C", theme: "T", audience_age: "a", key_insight: "k", default_locale: "en",
                       locales: [ "en" ], publish_token: "tok-#{SecureRandom.hex(4)}", unpublished_at: Time.current)
    2.times { respond(live) }
    respond(live, status: "started")
    live.responses.create!(session_token: SecureRandom.uuid, status: "started")

    stats = ClientWorkspaces.stats_for([ @a, @b ])

    assert_equal 3, stats.vertos[@a.id]
    assert_equal 1, stats.live[@a.id]
    assert_equal 3, stats.responders[@a.id]
    assert_equal 2, stats.completed[@a.id]
    assert_equal 67, stats.completion_rate(@a.id)
    assert_equal 1, stats.members[@a.id]
    assert_nil stats.vertos[@b.id]
    assert_nil stats.completion_rate(@b.id)
  end

  test "stats_for on no accounts is empty rather than an error" do
    stats = ClientWorkspaces.stats_for([])
    assert_equal({}, stats.vertos)
    assert_equal({}, stats.members)
  end
end
