require "test_helper"

# The result cards — surveys/_result_cards, shared with the public
# shared-results page — rebuilt onto the page's dark surface, with the answers
# as rows whose background is their own bar and the Verto's own pictures on
# the question and on the options that have them.
#
# What each test here is worth, checked by breaking the code under it rather
# than assumed:
#
#   - "a scenario card draws its counts" is a regression test for a real bug
#     this pass fixed: the aggregator has always tallied `scenario` and
#     finalize_card has always returned it in the choice shape, but no branch
#     drew it, so the card reported "43 answers" over nothing at all. It fails
#     the moment that type leaves the choice list again.
#   - the two picture tests hold the index→label hop in result_option_thumbs,
#     which mis-renders silently: an off-by-one puts one option's photograph
#     on another option's row and the page still looks fine.
#   - "no tile where there is no picture" is the judgement call made visible.
#     It would pass by construction today; it is here so that reintroducing a
#     placeholder tile is a decision someone makes on purpose.
#   - "every answer in the scale keeps its row" holds the tap card's
#     denominator, which is the bug the stacked bar was written to fix
#     (a statement 40% were unsure about reporting as a straight majority).
class ResultCardsTest < ActionDispatch::IntegrationTest
  IMG_A = "/assets/verto-library/swipe-cards/a.jpg".freeze
  IMG_B = "/assets/verto-library/swipe-cards/b.jpg".freeze
  CARD_IMG = "/assets/verto-library/left-panel/card.jpg".freeze

  def setup
    @org  = Organisation.create!(name: "O", slug: "rc-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "rc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def build_survey(cards)
    @survey = @org.surveys.create!(
      title: "Cards", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current, cards: cards
    )
  end

  def answer(answers)
    @survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                              status: "completed", answers: answers)
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def open_results
    sign_in(@user)
    get survey_results_path(@survey)
    assert_response :success
  end

  test "a scenario card draws its counts like any other choice card" do
    build_survey([ { "type" => "scenario", "text" => "A free taster session",
                     "options" => [ "Go along", "Give it a miss" ] } ])
    3.times { answer("0" => { "value" => "Go along" }) }
    answer("0" => { "value" => "Give it a miss" })

    open_results

    assert_select ".rc-row", 2,
      "a scenario card reported its answer count over no rows at all"
    assert_select ".rc-row .rc-label", text: "Go along"
    assert_select ".rc-row .rc-pct", text: "75%"
  end

  test "an option with a picture gets it on its row, and one without gets none" do
    build_survey([ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[Red Green],
                     "option_images" => [ IMG_A, "" ] } ])
    answer("0" => { "value" => "Red" })
    answer("0" => { "value" => "Green" })

    open_results

    assert_select ".rc-othumb", 1, "one option has a picture, so exactly one row draws a thumbnail"
    assert_select ".rc-row", 2
    # The thumbnail must be on RED's row — the one whose slot holds the image.
    red = css_select(".rc-row").find { |row| row.text.include?("Red") }
    assert red.css(".rc-othumb").any?, "the picture landed on the wrong option's row"
    assert_includes red.css(".rc-othumb").first["style"], IMG_A
  end

  # Counts come back sorted by size, so the row order is NOT the card's option
  # order the moment one option outpolls another — which is exactly when an
  # index-keyed lookup would start putting pictures on the wrong rows.
  test "the pictures follow their options when the rows are reordered by count" do
    build_survey([ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[First Second],
                     "option_images" => [ IMG_A, IMG_B ] } ])
    3.times { answer("0" => { "value" => "Second" }) }
    answer("0" => { "value" => "First" })

    open_results

    rows = css_select(".rc-row")
    assert_includes rows.first.text, "Second", "the bigger count should sort first"
    assert_includes rows.first.css(".rc-othumb").first["style"], IMG_B
    assert_includes rows.last.css(".rc-othumb").first["style"], IMG_A
  end

  test "the card's own picture sits beside the question; a card without one gets no tile" do
    build_survey([
      { "type" => "multiple_choice", "text" => "With art", "options" => %w[A B], "image" => CARD_IMG },
      { "type" => "multiple_choice", "text" => "Without art", "options" => %w[A B] }
    ])
    answer("0" => { "value" => "A" }, "1" => { "value" => "A" })

    open_results

    thumbs = css_select(".rc-thumb")
    assert_equal 1, thumbs.size,
      "a card with no art was given a tile — placeholder tiles read as a picture that failed to load"
    assert_includes thumbs.first["style"], CARD_IMG
  end

  # The scale is the card's own (TapScales), and every answer on it keeps a
  # row even at zero: the percentages are shares of the whole scale, and a
  # scale drawn with its unpicked answers missing reads as a different one.
  test "a tap card draws every answer in its scale, including the ones nobody picked" do
    build_survey([ { "type" => "tap_card", "text" => "Swipe these",
                     "options" => [ "Statement one" ], "option_images" => [ IMG_A ] } ])
    4.times { answer("0" => { "value" => { "Statement one" => "yes" } }) }

    open_results

    assert_select ".rc-group", 1
    assert_select ".rc-group .rc-row", TapScales.for_card(@survey.cards.first).size
    assert_select ".rc-row.is-zero", 2, "the two unpicked answers should be recessed, not dropped"
    assert_select ".rc-group-head .rc-othumb", 1, "the statement's own picture belongs on its caption"
  end

  # The public share page renders this same partial with shared: true. Card art
  # is what every respondent already saw, so it stays; free text does not.
  test "the shared page keeps the pictures and redacts the free text" do
    build_survey([ { "type" => "open_ended", "text" => "In your words", "image" => CARD_IMG } ])
    answer("0" => { "value" => "Something identifying" })
    @survey.update_columns(results_share_active: true, results_share_token: SecureRandom.hex(12))

    get shared_results_path(@survey.results_share_token)
    assert_response :success

    assert_select ".rc-thumb", 1
    assert_select ".freeform-preview-item", 0
    assert_select ".rc-sub"
    assert_no_match(/Something identifying/, response.body)
  end
end
