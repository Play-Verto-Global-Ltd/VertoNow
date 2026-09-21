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
