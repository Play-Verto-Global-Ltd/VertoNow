require "test_helper"

# The results page's header — tally, exports, and the two filters — moved out of
# the results-feed turbo frame and above the AI summary, and is rendered outside
# the scrolling div so it stays put while the feed moves.
#
# The structural assertion is the one worth having: everything else here is
# visible on the page, but "is it inside the frame?" is invisible until a
# creator clicks a filter and watches the header fail to update, because a
# frame navigation replaces the frame and nothing else.
class ResultsHeaderTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "O", slug: "rh-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "rh-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Header", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] } ]
    )
    sign_in(@user)
  end

  # Same shape as viewer_role_test's — these tests are about rendered markup,
  # and a session cookie is the cheapest way to get to it.
  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # The condensed header folds the standalone Overall chip away and lets the
  # segment picker name Overall itself. That leaves the picker's PANEL as the
  # only way back — so a reader who narrows to one country and then scrolls
  # can never widen again unless the panel carries its own reset.
  test "the segment picker's panel carries the way back to Overall" do
    3.times { @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed", region_country: "GB", answers: { "0" => { "value" => "A" } }) }
    Response::MIN_REGION_SAMPLE_SIZE.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                                region_country: "US", answers: { "0" => { "value" => "B" } })
    end

    get survey_results_path(@survey, segment: "region_US")
    assert_response :success

    reset = css_select(".rh-segments-panel .rh-group--reset a").first
    assert reset, "the picker's panel has no Overall row — a condensed reader cannot widen again"
    assert_includes reset.text, "Overall"
    assert_equal survey_results_path(@survey), reset["href"]
  end

  # The date window is rendered twice: as the segmented control the expanded
  # header shows, and as a menu naming only the one in force for the condensed
  # one. Both are real controls, so both have to point at the same places — a
  # menu that dropped a range, or linked to the wrong one, would only be
  # noticed by someone scrolling.
  test "the collapsed date menu offers the same ranges as the segmented control" do
    get survey_results_path(@survey, range: "30d")

    control = css_select(".rh-when .rh-when-btn")
    menu    = css_select(".rh-when-menu-panel .rh-menu-item")

    assert_equal 4, control.size
    assert_equal control.map { |a| a["href"] }, menu.map { |a| a["href"] }
    assert_equal control.map { |a| a.text.strip }, menu.map { |a| a.text.strip }

    assert_equal "Last 30 days", css_select(".rh-when-menu summary .rh-picker-active").first.text.strip,
      "the collapsed pill does not name the range actually in force"
  end

  test "the header renders before the results-feed frame, not inside it" do
    get survey_results_path(@survey)
    assert_response :success

    header = response.body.index('class="results-header"')
    frame  = response.body.index('id="results-feed"')

    assert header, "no results header"
    assert frame,  "no results feed frame"
    assert header < frame,
      "the header renders inside or after the feed frame — a filter click would replace the frame and leave the header showing the old selection"
  end

  test "the filters live in the header, above the AI summary card" do
    get survey_results_path(@survey)

    filters = response.body.index('class="results-header-filters"')
    summary = response.body.index('id="av-card"')

    assert filters && summary
    assert filters < summary, "the filters are still below the AI summary card"
  end

  test "the date window is one control with exactly one active option" do
    get survey_results_path(@survey, range: "7d")
    assert_response :success

    assert_select ".rh-when .rh-when-btn", 4
    assert_select ".rh-when .rh-when-btn.is-active", 1
    assert_select ".rh-when .rh-when-btn.is-active", text: /7 days/i
  end

  test "exports are one menu — the CSV, XLSX and respondent-data rows share it" do
    get survey_results_path(@survey)

    assert_select "details.results-export-menu summary.rh-pill", text: /Export/

    # assert_select, not assert_match: these hrefs carry query strings, and the
    # rendered markup escapes their ampersands.
    menu = "details.results-export-menu"
    %w[responses summary].each do |kind|
      assert_select "#{menu} a[href=?]",
        survey_results_export_path(@survey, kind: kind, segment: "overall")
    end
    assert_select "#{menu} a[href=?]", survey_respondent_data_path(@survey)
  end

  test "the AI report is the page's only solid pill" do
    get survey_results_path(@survey)

    assert_select ".rh-pill--ai", 1
  end
end
