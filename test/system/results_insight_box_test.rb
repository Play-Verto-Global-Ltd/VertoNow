require "application_system_test_case"

# The box beside each question — the reading of that chart over the card's own
# "why we asked" tagging.
#
# Three things here need a browser and have no other coverage:
#
#   * WHERE it sits. It is absolutely positioned out into the page's right
#     margin, which is a layout that fails in exactly one way — by being wider
#     than the margin it was given and putting the whole page into horizontal
#     scroll. No markup assertion can see that.
#   * WHICH card it lands on. The fetch returns a map keyed by deck index and
#     the controller hands each reading to the slot carrying that index. A
#     reading under the wrong chart is the failure that matters, and it looks
#     completely correct — so the fixture below deliberately reads only two of
#     the six questions and the test checks the other four stay empty.
#   * That the shimmer GOES. A question the model declined to read must end up
#     with no box, not with a placeholder that waits forever.
#
# The readings come from the endpoint's own cache (seeded below), so this
# drives the real controller, the real fetch and the real fill without a model
# call — the cold-cache path is covered by QuestionInsightsEndpointTest.
class ResultsInsightBoxTest < ApplicationSystemTestCase
  WIDE   = 1600 # room for the rail, the 780px feed and the 268px box
  NARROW = 1280 # one pixel under the breakpoint, where the box comes back in

  READINGS = {
    "1" => "Cost is the barrier for three in four, well ahead of time.",
    "3" => "Most would come back, which is not what the barrier question suggested."
  }.freeze

  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "ib-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ib-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    cards = [ { "type" => "welcome_card", "title" => "Hi" } ] +
            (1..6).map do |n|
              card = { "type" => "multiple_choice", "text" => "Question #{n}", "options" => %w[A B] }
              # Only the first question carries framework tagging, which is
              # what a real deck looks like — the tagging exists on cards the
              # generator wrote, not on the ones typed by hand.
              n == 1 ? card.merge("competency" => "agency", "condition" => "belonging",
                                  "outcome" => "Whether the barrier is the place or the people.") : card
            end

    @survey = @org.surveys.create!(
      title: "Barriers", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current, cards: cards
    )
    6.times do
      answers = (1..6).to_h { |i| [ i.to_s, { "value" => "A" } ] }
      @survey.responses.create!(session_token: SecureRandom.uuid, answered: true,
                                status: "completed", answers: answers)
    end

    # The endpoint replays this rather than calling the model: same segment,
    # same count. Both have to match or it reads afresh — which in a test
    # environment means a real request to Anthropic.
    @survey.update_columns(results_insights: {
      "segment" => "overall", "count" => @survey.responses.where(answered: true).count,
      "questions" => READINGS
    })
  end

  def open_results(width)
    page.driver.browser.resize(width: width, height: 900)
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    assert_selector ".rc-card", minimum: 6, wait: 5
    wait_for_stimulus
  end

  # The fetch is in flight when the page renders; every test here is about the
  # state it settles into, so wait for the shimmer to have gone everywhere.
  def wait_for_readings
    assert_no_selector ".rc-tell-wait", wait: 5
  end

  def box_for(idx)
    find(".rc-tell[data-index='#{idx}']", visible: :all)
  end

  test "each reading lands on the question it was written about, and no other" do
    open_results(WIDE)
    wait_for_readings

    READINGS.each do |idx, text|
      assert_equal text, box_for(idx).find(".rc-tell-body").text,
        "the reading for card #{idx} is not the one under it"
    end

    # The four the model didn't read keep no box at all. A visible empty one
    # would read as a reading that failed to load.
    unread = all(".rc-tell", visible: :all).reject { |el| READINGS.key?(el["data-index"]) }
    assert_equal 4, unread.size
    unread.each do |el|
      refute el.visible?, "card #{el['data-index']} was given a box with nothing in it"
    end
  end

  test "the box sits in the right-hand margin without widening the page" do
    open_results(WIDE)
    wait_for_readings

    settle_box(find("#rc-card-1"))
    geometry = evaluate_script(<<~JS)
      (() => {
        const aside = document.querySelector(".rc-tell[data-index='1']").closest(".rc-aside")
        const card  = aside.closest(".rc-card")
        const a = aside.getBoundingClientRect(), c = card.getBoundingClientRect()
        return {
          asideLeft:  Math.round(a.left),
          cardRight:  Math.round(c.right),
          asideRight: Math.round(a.right),
          viewport:   document.documentElement.clientWidth,
          overflowX:  document.documentElement.scrollWidth > document.documentElement.clientWidth
        }
      })()
    JS

    assert_operator geometry["asideLeft"], :>=, geometry["cardRight"],
      "the box is overlapping the answers rather than sitting beside them"
    assert_operator geometry["asideRight"], :<=, geometry["viewport"],
      "the box runs off the right of the window"
    refute geometry["overflowX"], "the box put the results page into horizontal scroll"
  end

  # Under the breakpoint there is no margin to hang it in, so it comes back
  # into the card under the answers — the alternative being a box that either
  # overlaps the chart or scrolls the page sideways on a laptop.
  test "under 1290px it comes back into the card, below the answers" do
    open_results(NARROW)
    wait_for_readings

    settle_box(find("#rc-card-1"))
    geometry = evaluate_script(<<~JS)
      (() => {
        const aside = document.querySelector(".rc-tell[data-index='1']").closest(".rc-aside")
        const rows  = aside.closest(".rc-card").querySelector(".rc-rows, .rc-row")
        const a = aside.getBoundingClientRect(), r = rows.getBoundingClientRect()
        return {
          position:  getComputedStyle(aside).position,
          asideTop:  Math.round(a.top),
          rowsBottom: Math.round(r.bottom),
          overflowX: document.documentElement.scrollWidth > document.documentElement.clientWidth
        }
      })()
    JS

    assert_equal "static", geometry["position"]
    assert_operator geometry["asideTop"], :>=, geometry["rowsBottom"],
      "the box is sitting over the answers instead of under them"
    refute geometry["overflowX"]
  end

  # The divider under the answers separates them from what is said about them.
  # Most cards have neither half — no framework tagging, and no reading, since
  # the model is free to decline one — so the common case below the breakpoint
  # was an empty box drawing its own rule and 28px of space under every set of
  # answers on the page.
  test "a card with nothing to say draws no divider under its answers" do
    open_results(NARROW)
    wait_for_readings

    borders = evaluate_script(<<~JS)
      (() => {
        const px = (n) => Math.round(parseFloat(getComputedStyle(n).borderTopWidth))
        const of = (i) => {
          const a = document.querySelector(`#rc-card-${i} .rc-aside`)
          return a ? px(a) : null
        }
        return { tagged: of(1), bare: of(2), unread: of(5) }
      })()
    JS

    assert_equal 1, borders["tagged"], "the card with both halves keeps its divider"
    assert_equal 0, borders["bare"],   "a card with no Why and no reading drew a rule over nothing"
    assert_equal 0, borders["unread"]
  end

  # The Why half is rendered from the card and needs no request at all, so it
  # must be readable before — and regardless of whether — the reading arrives.
  test "the why box is there from the first paint, with its framework badges" do
    open_results(WIDE)

    # The tagging is on card 1 — the welcome screen ahead of it is not a
    # question and gets no box at all.
    within("#rc-card-1") do
      assert_selector ".rc-why-head"
      assert_selector ".rc-why-badge", count: 2
      assert_text "Whether the barrier is the place or the people."
    end
  end
end
