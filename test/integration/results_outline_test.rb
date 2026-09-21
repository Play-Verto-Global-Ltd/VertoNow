require "test_helper"

# The question outline — the rail in the results feed's left margin.
#
# What is worth holding here is the pairing, not the pixels: the rail is
# rendered from @aggregated and the cards are rendered from @aggregated, and
# nothing in either template says the two must stay in step. If they drift, a
# row's anchor points at a card that isn't the one it names and the page still
# looks completely fine.
class ResultsOutlineTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "O", slug: "ro-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ro-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Outline", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [
        { "type" => "welcome_card", "text" => "Kick off" },
        { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[A B] },
        { "type" => "open_ended", "text" => "In your words" },
        { "type" => "nps", "text" => "How likely?" }
      ]
    )
    2.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                                answers: { "0" => { "value" => true }, "1" => { "value" => "A" },
                                           "2" => { "value" => "Some words" }, "3" => { "value" => 9 } })
    end
    sign_in(@user)
    get survey_results_path(@survey)
    assert_response :success
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "every question gets a row, in the feed's order" do
    rows = css_select(".ro-item")

    assert_equal @survey.cards.size, rows.size
    assert_equal (1..@survey.cards.size).map(&:to_s), rows.map { |r| r.css(".ro-num").text.strip }
  end

  # The one that would fail silently: row N must point at card N.
  test "each row's anchor is the card that row names" do
    rows  = css_select(".ro-item")
    cards = css_select(".rc-card")

    assert_equal rows.size, cards.size, "the rail and the feed disagree about how many questions there are"

    rows.each_with_index do |row, i|
      assert_equal "#rc-card-#{i}", row["href"]
      assert_equal "rc-card-#{i}", cards[i]["id"]
      assert_equal cards[i].css(".s-badge").text.strip, row.css(".ro-type").text.strip,
        "row #{i + 1} names a different type from the card it links to"
    end
  end

  test "a row carries the same answer count as its card" do
    rows  = css_select(".ro-item")
    cards = css_select(".rc-card")

    rows.each_with_index do |row, i|
      assert_equal cards[i].css(".rc-answers").text[/\d+/], row.css(".ro-n").text.strip
    end
  end

  # Auto-refresh replaces the results-feed frame. Inside it, the rail would be
  # rebuilt on every tick — losing the reader's scroll position in it — and,
  # more to the point, it could not sit in the page's left margin at all: the
  # frame is inside the 780px reading column.
  test "the rail is outside the results-feed frame" do
    outline = response.body.index('class="results-outline"')
    frame   = response.body.index('id="results-feed"')

    assert outline && frame
    assert outline < frame,
      "the outline renders inside the results-feed frame — an auto-refresh tick would rebuild it"
  end

  # The rail is chrome for the owner's page. The public share page renders the
  # same cards through the same partial and must not grow one.
  test "the shared page gets the card anchors but no rail" do
    @survey.update_columns(results_share_active: true, results_share_token: SecureRandom.hex(12))

    get shared_results_path(@survey.results_share_token)
    assert_response :success

    assert_select ".results-outline", 0
    assert_select "#rc-card-0", 1
  end
end
