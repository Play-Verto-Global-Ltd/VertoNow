require "test_helper"

# Workspaces: the account you are acting in, shown beside the logo and
# switchable from there or from the ⌘K palette. The membership model already
# supported several accounts per user — what was missing was any affordance
# saying so.
class WorkspaceSwitcherTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "Multi", email_address: "ws-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @first  = Organisation.create!(name: "Acme Research", slug: "acme-#{SecureRandom.hex(3)}")
    @second = Organisation.create!(name: "Beta Foundation", slug: "beta-#{SecureRandom.hex(3)}")
    @first.memberships.create!(user: @user, role: "admin")
    @second.memberships.create!(user: @user, role: "member")

    @solo = User.create!(name: "Solo", email_address: "solo-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @solo_org = Organisation.create!(name: "Only Org", slug: "only-#{SecureRandom.hex(3)}")
    @solo_org.memberships.create!(user: @solo, role: "admin")
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "a single-workspace user sees the workspace as context, with nothing to open" do
    sign_in @solo
    get root_path
    assert_response :success

    assert_match "Only Org", response.body
    assert_match 'data-static="true"', response.body
    refute_match "command-palette#toggleWorkspace", response.body,
                 "a one-row menu is noise — the chip should be static"
  end

  test "a multi-workspace user gets a switcher listing every workspace with its role" do
    sign_in @user
    get root_path
    assert_response :success

    assert_match "command-palette#toggleWorkspace", response.body
    assert_match 'data-command-palette-target="workspacePopover"', response.body
    assert_match "Acme Research", response.body
    assert_match "Beta Foundation", response.body
    # The current workspace is marked, not offered as a destination.
    assert_match 'data-current="true"', response.body
    # Roles come from the preloaded membership hash.
    assert_match I18n.t("nav.role_admin"), response.body
    assert_match I18n.t("nav.role_member"), response.body
  end

  test "switching moves the acting account and shows that account's Vertos" do
    @first.surveys.create!(title: "Acme Verto", theme: "T", audience_age: "a", key_insight: "k",
                           default_locale: "en", locales: [ "en" ])
    @second.surveys.create!(title: "Beta Verto", theme: "T", audience_age: "a", key_insight: "k",
                            default_locale: "en", locales: [ "en" ])
    sign_in @user

    post switch_organisation_path, params: { organisation_id: @second.id }
    assert_redirected_to root_url
    follow_redirect!

    assert_match "Beta Verto", response.body
    refute_match "Acme Verto", response.body, "still showing the workspace we switched away from"
  end

  # Deliberate: every deep page is scoped to Current.organisation.surveys, so
  # returning to one after the org changes would 404.
  test "switching lands on the target workspace's home, not the page you came from" do
    funder_org = Organisation.create!(name: "Funder Co", slug: "fund-#{SecureRandom.hex(3)}",
                                      funder_enabled: true)
    funder_org.memberships.create!(user: @user, role: "admin")
    sign_in @user

    post switch_organisation_path, params: { organisation_id: funder_org.id }
    assert_redirected_to funders_url,
                         "a funder-owner workspace should land on its own dashboard"
  end

  test "switching to a workspace you do not belong to is a silent no-op" do
    outsider = Organisation.create!(name: "Not Yours", slug: "not-#{SecureRandom.hex(3)}")
    sign_in @user
    get root_path

    post switch_organisation_path, params: { organisation_id: outsider.id }
    follow_redirect!

    assert_match "Acme Research", response.body, "the acting workspace should not have changed"
    refute_match "Not Yours", response.body
  end

  test "the command palette lists the other workspaces as searchable entries" do
    sign_in @user
    get root_path
    assert_response :success

    assert_match 'data-section="workspaces"', response.body
    # The target and search text must sit on the BUTTON: filter() reads
    # dataset.searchText and Enter calls .click(), and clicking a form is inert.
    assert_match(/<button[^>]*data-command-palette-target="item"[^>]*data-search-text="beta foundation[^"]*"/,
                 response.body)
  end

  test "the user menu no longer carries a second copy of the switcher" do
    sign_in @user
    get root_path

    # Exactly one switch form per other workspace — the old flat list in the
    # user popover plus the new switcher would give two.
    forms = response.body.scan(%r{action="#{switch_organisation_path}"}).size
    assert_equal 2, forms,
                 "expected one switch form in the workspace popover and one in the palette, got #{forms}"
  end

  # ── Recording where you are ──────────────────────────────────────────────

  test "switching records the visit on the target membership, every time" do
    sign_in @user
    membership = @user.memberships.find_by(organisation: @second)
    membership.update_column(:last_visited_at, 10.minutes.ago)

    post switch_organisation_path, params: { organisation_id: @second.id }

    assert_in_delta Time.current, membership.reload.last_visited_at, 2.seconds,
                    "a switch inside the throttle window must still move the stamp"
  end

  test "landing in a workspace records the visit without a switch" do
    assert_nil @user.memberships.find_by(organisation: @first).last_visited_at

    sign_in @user
    get root_path

    assert_in_delta Time.current, @user.memberships.find_by(organisation: @first).reload.last_visited_at, 2.seconds
  end

  test "a switch you are not allowed records nothing" do
    outsider = Organisation.create!(name: "Not Yours", slug: "not-#{SecureRandom.hex(3)}")
    sign_in @user

    post switch_organisation_path, params: { organisation_id: outsider.id }

    assert_nil Membership.find_by(organisation: outsider)
  end

  # ── The staff picker ─────────────────────────────────────────────────────
  # Playverto staff work in every client account. Their picker leads with the
  # Playverto workspace, then a row to the Clients dashboard, then the two
  # clients they were in most recently — not every account they belong to.

  def make_staff_with_clients(names)
    playverto = Organisation.find_or_create_by!(slug: PlayvertoStaff::SLUG) { |o| o.name = "Playverto" }
    staff = User.create!(name: "Jamie", email_address: "ws-staff-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    # Playverto first, so signing in lands there (memberships.first).
    playverto.memberships.create!(user: staff, role: "member")
    clients = names.map do |name|
      org = Organisation.create!(name: name, slug: "ws-c-#{SecureRandom.hex(3)}")
      org.memberships.create!(user: staff, role: "admin")
      org
    end
    [ staff, playverto, clients ]
  end

  def popover_rows(body)
    doc = Nokogiri::HTML(body)
    doc.css("[data-command-palette-target='workspacePopover'] .bottom-bar-workspace-item")
       .map { |row| row.css(".bottom-bar-workspace-item-name").text.strip }
  end

  test "staff see Playverto, See all clients, then the two most recently opened clients" do
    staff, _playverto, clients = make_staff_with_clients([ "Alpbach", "Riders for Health", "Unleash Football", "History CoLab" ])
    staff.memberships.find_by(organisation: clients[1]).update_column(:last_visited_at, 3.hours.ago)
    staff.memberships.find_by(organisation: clients[2]).update_column(:last_visited_at, 1.hour.ago)
    staff.memberships.find_by(organisation: clients[3]).update_column(:last_visited_at, 2.hours.ago)

    sign_in staff
    get root_path
    assert_response :success

    # Alpbach, never opened, is not among the rows — the ⌘K palette still lists
    # it, since that surface is searched rather than read.
    assert_equal [ "Playverto", I18n.t("nav.see_all_clients"), "Unleash Football", "History CoLab" ],
                 popover_rows(response.body)
    assert_select "[data-command-palette-target='workspacePopover'] a.bottom-bar-workspace-cta[href='#{clients_path}']"
    # Playverto is where they are, so it is the marked row.
    assert_select "[data-command-palette-target='workspacePopover'] .bottom-bar-workspace-item[data-current='true'] .bottom-bar-workspace-item-name",
                  text: "Playverto"
  end

  test "the client being acted in leads the recent two and is marked current" do
    staff, _playverto, clients = make_staff_with_clients([ "Alpbach", "Riders for Health", "Unleash Football" ])
    staff.memberships.find_by(organisation: clients[1]).update_column(:last_visited_at, 2.hours.ago)
    staff.memberships.find_by(organisation: clients[2]).update_column(:last_visited_at, 1.hour.ago)

    sign_in staff
    post switch_organisation_path, params: { organisation_id: clients[0].id }
    follow_redirect!

    assert_equal [ "Playverto", I18n.t("nav.see_all_clients"), "Alpbach", "Unleash Football" ],
                 popover_rows(response.body)
    assert_select "[data-command-palette-target='workspacePopover'] .bottom-bar-workspace-item[data-current='true'] .bottom-bar-workspace-item-name",
                  text: "Alpbach"
  end

  test "staff who have opened no client yet still get the door to all of them" do
    staff, = make_staff_with_clients([ "Alpbach" ])

    sign_in staff
    get root_path

    assert_equal [ "Playverto", I18n.t("nav.see_all_clients") ], popover_rows(response.body)
  end

  test "a customer's picker is the full list, with no clients row" do
    sign_in @user
    get root_path

    assert_equal [ "Acme Research", "Beta Foundation" ], popover_rows(response.body)
    refute_match I18n.t("nav.see_all_clients"), response.body
    assert_select "[data-command-palette-target='workspacePopover'][data-staff='false']"
  end
end
