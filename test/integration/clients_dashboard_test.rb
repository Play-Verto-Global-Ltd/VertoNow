require "test_helper"

# The Clients dashboard (/clients): every client account a Playverto staff
# member works in, with numbers, and a switch into each. Staff only — for
# anyone else the route is not there.
class ClientsDashboardTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: PlayvertoStaff::SLUG) { |o| o.name = "Playverto" }
    @staff = User.create!(name: "Jamie", email_address: "cd-staff-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD)
    @playverto.memberships.create!(user: @staff, role: "member")

    @alpbach  = Organisation.create!(name: "Alpbach", slug: "cd-alp-#{SecureRandom.hex(3)}")
    @riders   = Organisation.create!(name: "Riders for Health", slug: "cd-rfh-#{SecureRandom.hex(3)}")
    @alpbach.memberships.create!(user: @staff, role: "admin")
    @riders.memberships.create!(user: @staff, role: "member")

    @customer = User.create!(name: "Client", email_address: "cd-client-#{SecureRandom.hex(3)}@test.com",
                             password: PASSWORD)
    @alpbach.memberships.create!(user: @customer, role: "admin")
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  # A response that counts as a responder: `answered` is derived from the
  # answers on save (Response#sync_answered), so it has to hold one.
  def respond(survey, status: "completed")
    survey.responses.create!(session_token: SecureRandom.uuid, status: status,
                             answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
  end

  def card_stats(org)
    Nokogiri::HTML(response.body)
            .css(".clients-card[data-organisation-id='#{org.id}'] .clients-card-stat-value")
            .map { |n| n.text.strip }
  end

  def make_verto(org, title:, live: true)
    org.surveys.create!(title: title, theme: "T", audience_age: "a", key_insight: "k",
                        default_locale: "en", locales: [ "en" ],
                        publish_token: live ? SecureRandom.hex(8) : nil)
  end

  # ── Who gets in ────────────────────────────────────────────────────────────

  test "a Playverto member sees every client account they belong to, and not Playverto itself" do
    sign_in @staff
    get clients_path
    assert_response :success

    assert_match "Alpbach", response.body
    assert_match "Riders for Health", response.body
    assert_select ".clients-card", 2
    assert_select ".clients-card[data-organisation-id='#{@playverto.id}']", 0,
                  "the Playverto workspace is home, not a client"
  end

  test "a customer gets a 404, not a refusal — the page does not exist for them" do
    sign_in @customer
    get clients_path
    assert_response :not_found
  end

  test "a signed-out visitor gets a 404 too, never a sign-in bounce that confirms the route" do
    get clients_path
    assert_response :not_found
  end

  # ── What it says ───────────────────────────────────────────────────────────

  test "each card carries the account's Vertos, live count, responders, completion and seats" do
    live  = make_verto(@alpbach, title: "Live one")
    make_verto(@alpbach, title: "Live two")
    make_verto(@alpbach, title: "Draft", live: false)
    # An archived Verto and its respondents are out of the tally.
    gone = make_verto(@alpbach, title: "Archived")
    gone.update_columns(deleted_at: Time.current)
    respond(gone)

    3.times { respond(live) }
    respond(live, status: "started")
    # Opened, nothing answered: not a responder.
    live.responses.create!(session_token: SecureRandom.uuid, status: "started")

    sign_in @staff
    get clients_path

    assert_equal %w[3 2 4 75% 2], card_stats(@alpbach),
                 "expected Vertos, Live, Responders, Completion, Members in that order"
    assert_equal [ "0", "0", "0", "—", "1" ], card_stats(@riders)
  end

  test "the totals strip sums across every client" do
    make_verto(@alpbach, title: "A")
    respond(make_verto(@riders, title: "R"))

    sign_in @staff
    get clients_path

    values = css_select(".dash-stat-value").map { |n| n.text.strip }
    assert_equal [ "2", "2", "2", "1", "100%" ], values,
                 "expected Clients, Vertos, Live, Responders, Completion"
  end

  test "the account being acted in is marked current; every other one gets a switch" do
    sign_in @staff
    post switch_organisation_path, params: { organisation_id: @alpbach.id }
    get clients_path

    assert_select ".clients-card[data-organisation-id='#{@alpbach.id}'][data-current='true'] .clients-card-current"
    assert_select ".clients-card[data-organisation-id='#{@alpbach.id}'] form[action='#{switch_organisation_path}']", 0
    assert_select ".clients-card[data-organisation-id='#{@riders.id}'] form[action='#{switch_organisation_path}']"
    assert_select ".clients-card[data-organisation-id='#{@riders.id}'] input[name='organisation_id'][value='#{@riders.id}']"
  end

  test "the role beside each name is the staff member's role in that account" do
    sign_in @staff
    get clients_path

    assert_select ".clients-card[data-organisation-id='#{@alpbach.id}'] .clients-card-role", text: I18n.t("nav.role_admin")
    assert_select ".clients-card[data-organisation-id='#{@riders.id}'] .clients-card-role", text: I18n.t("nav.role_member")
  end

  test "clients are listed most recently opened first, then the never-opened by name" do
    zed = Organisation.create!(name: "Zed Trust", slug: "cd-zed-#{SecureRandom.hex(3)}")
    zed.memberships.create!(user: @staff, role: "admin")
    @staff.memberships.find_by(organisation: @riders).update_column(:last_visited_at, 2.days.ago)
    @staff.memberships.find_by(organisation: zed).update_column(:last_visited_at, 1.hour.ago)

    sign_in @staff
    get clients_path

    # Signing in lands the staff member in their FIRST membership (Playverto),
    # so no client is current and the stored timestamps decide the order.
    ids = css_select(".clients-card").map { |n| n["data-organisation-id"].to_i }
    assert_equal [ zed.id, @riders.id, @alpbach.id ], ids
    assert_match I18n.t("clients.never_opened"), response.body
    assert_match I18n.t("clients.opened_ago", when: "about 1 hour"), response.body
  end

  test "a staff member in no client account yet sees an empty state, not an error" do
    lone = User.create!(name: "New", email_address: "cd-new-#{SecureRandom.hex(3)}@test.com", password: PASSWORD)
    @playverto.memberships.create!(user: lone, role: "member")

    sign_in lone
    get clients_path
    assert_response :success
    assert_match I18n.t("clients.empty_title"), response.body
    assert_select ".clients-card", 0
  end

  # ── The doors to it ────────────────────────────────────────────────────────

  test "the command palette offers staff a Clients tile and customers nothing" do
    sign_in @staff
    get root_path
    assert_select "a.command-palette-tile[href='#{clients_path}']"

    sign_in @customer
    get root_path
    assert_select "a.command-palette-tile[href='#{clients_path}']", 0
  end
end
