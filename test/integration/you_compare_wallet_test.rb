require "test_helper"

# The two pages an account exists for: what you said next to what everyone
# said, and what you collected.
#
# Three properties carry this file, and all three are about what these pages
# must NOT do. They must not become a way around small-cell suppression; they
# must not overrule the creator's own comparison switch; and they must not
# merge two Vertos' token piles just because both creators happened to name a
# token "gold".
class YouCompareWalletTest < ActionDispatch::IntegrationTest
  # The small-cell floor both pages are held to, as the player is.
  MIN = Response::MIN_REGION_SAMPLE_SIZE

  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Hello" },
    { "type" => "multiple_choice", "cid" => "q", "text" => "What would you want first?",
      "options" => [ "Wider pavements", "More trees", "Somewhere to sit" ] }
  ].freeze

  def org(name = "Haverley") = Organisation.create!(name: name, slug: "yc-#{SecureRandom.hex(3)}")

  def survey(owner: nil, cards: CARDS, **attrs)
    (owner || org).surveys.create!(
      title: "T", theme: "Car-free High Street", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards.map(&:dup),
      show_results_comparison: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def answered(s, value: "More trees", tokens: nil, key: nil)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        completed_at: 1.day.ago,
                        answers: { "1" => { "type" => "multiple_choice", "value" => value } },
                        token_totals: tokens || {},
                        player_key_digest: key ? s.player_key_digest(key) : nil)
  end

  # Enough other people to clear MIN_REGION_SAMPLE_SIZE on their own.
  def crowd(s, n = MIN, value: "Wider pavements")
    n.times { answered(s, value: value) }
  end

  # A share as the pages print it: a whole percent.
  def pct(count, of) = "#{(count * 100.0 / of).round}%"

  def sign_in_with(claims)
    pl = Player.for_email("yc-#{SecureRandom.hex(4)}@test.com")
    _link, raw = PlayerSignInLink.mint!(
      player: pl, claim_payload: claims.map { |r| { "response_id" => r.id, "source" => "signup" } })
    post player_sign_in_path(raw)
    pl
  end

  # ── The comparison ────────────────────────────────────────────────────────

  test "it shows your answer against everyone else's" do
    s = survey
    crowd(s, value: "Wider pavements")
    mine = answered(s, value: "More trees")
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_response :success
    assert_select ".you-q-prompt", text: "What would you want first?"
    assert_select ".you-q-mine", text: /More trees/
    # Their own bar is marked, and only theirs.
    assert_select ".you-bar-row.is-mine", 1
    assert_select ".you-bar-row.is-mine .you-bar-label", text: "More trees"
    # MIN of MIN + 1 chose the other option.
    assert_select ".you-bar-row", 3
    assert_match pct(MIN, MIN + 1), response.body
  end

  test "under the small-cell floor it refuses the comparison, exactly as the player does" do
    # Four responders total: on a Verto this small the "comparison" IS the
    # other respondents' answers, attributable by anyone who knows who was
    # asked. An account must not be a way around that.
    s = survey
    crowd(s, 3)
    mine = answered(s, value: "More trees")
    assert_operator s.responses.where(answered: true).count, :<, Response::MIN_REGION_SAMPLE_SIZE
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_response :success
    assert_select ".you-bar-row", 0
    assert_select ".you-sub", text: I18n.t("you.comparison_too_few")
  end

  test "the creator's comparison switch still decides, and the Verto is kept either way" do
    s = survey(show_results_comparison: false)
    crowd(s)
    mine = answered(s, value: "More trees")
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_response :success
    assert_select ".you-bar-row", 0
    assert_select ".you-sub", text: I18n.t("you.comparison_off", org: s.organisation.name)
    assert_select "h1.you-h1", text: "Car-free High Street", count: 1
  end

  test "a question with no set options shows your answer without inventing a chart" do
    s = survey(cards: [ { "type" => "welcome_card", "cid" => "w", "text" => "Hi" },
                        { "type" => "open_ended", "cid" => "o", "text" => "Anything else?" } ])
    MIN.times do
      s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                          answers: { "1" => { "type" => "open_ended", "value" => "Something" } })
    end
    mine = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                               answers: { "1" => { "type" => "open_ended", "value" => "Wider pavements please" } })
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_select ".you-q-mine", text: /Wider pavements please/
    assert_select ".you-bar-row", 0
  end

  # ── Every kind of question ────────────────────────────────────────────────
  #
  # The aggregator stores each type its own way — rank SUMS for a ranking,
  # integer-keyed tallies for a scale, a Hash per statement for a swipe card —
  # and the page used to read every one of them as a flat label => count map.
  # A swipe card therefore 500ed the whole page for anyone who had answered one
  # (Hash#to_i), a scale drew only 0% bars, and a ranking drew 100/200/300%.
  # The decks below have the shapes the editor and the demo seeder write.

  MIXED = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Hello" },                                # 0
    { "type" => "select_many", "cid" => "m", "text" => "How do you get here?",
      "options" => %w[Bus Bike Walk] },                                                           # 1
    { "type" => "rating", "cid" => "r", "text" => "Rate the street",
      "options" => %w[Poor Fair Good Great Excellent] },                                          # 2
    { "type" => "range", "cid" => "g", "text" => "How confident are you?",
      "options" => %w[Low Middling High] },                                                       # 3
    { "type" => "nps", "cid" => "n", "text" => "Would you recommend it?",
      "options" => (0..10).map(&:to_s) },                                                         # 4
    { "type" => "prioritise", "cid" => "p", "text" => "Rank these",
      "options" => %w[Homes Jobs Parks] },                                                        # 5
    { "type" => "tap_card", "cid" => "t", "text" => "Swipe each one",
      "options" => [ "Cars belong here", "Trees belong here" ] },                                 # 6
    { "type" => "yes_no", "cid" => "y", "text" => "Do you live nearby?" },                        # 7
    { "type" => "contact_form", "cid" => "c", "text" => "Leave your details" },                   # 8
    { "type" => "open_ended", "cid" => "l", "input" => "location", "demographic" => true,
      "text" => "Where do you live?" }                                                            # 9
  ].freeze

  OTHERS_ANSWER = {
    "1" => { "type" => "select_many", "value" => %w[Bus] },
    "2" => { "type" => "rating", "value" => 5 },
    "3" => { "type" => "range", "value" => 2 },
    "4" => { "type" => "nps", "value" => 9 },
    "5" => { "type" => "prioritise", "value" => %w[Homes Jobs Parks] },
    "6" => { "type" => "tap_card", "value" => { "Cars belong here" => "yes", "Trees belong here" => "no" } },
    "7" => { "type" => "yes_no", "value" => "Yes" },
    "8" => { "type" => "contact_form", "value" => { "email" => "someone-else@example.test" } },
    "9" => { "type" => "open_ended", "value" => "ZA|Gauteng" }
  }.freeze

  MY_ANSWER = {
    "1" => { "type" => "select_many", "value" => %w[Bike Walk] },
    "2" => { "type" => "rating", "value" => 2 },
    "3" => { "type" => "range", "value" => 0 },
    "4" => { "type" => "nps", "value" => 3 },
    "5" => { "type" => "prioritise", "value" => %w[Parks Jobs Homes] },
    "6" => { "type" => "tap_card", "value" => { "Cars belong here" => "no", "Trees belong here" => "no" } },
    "7" => { "type" => "yes_no", "value" => "No" },
    "8" => { "type" => "contact_form", "value" => { "email" => "me@example.test" } },
    "9" => { "type" => "open_ended", "value" => "GB|London" }
  }.freeze

  # MIN others who all answered OTHERS_ANSWER, so the comparison clears the
  # floor without the respondent's own run, plus that run (MY_ANSWER).
  def mixed_verto(**attrs)
    s = survey(cards: MIXED, **attrs)
    MIN.times do
      s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                          completed_at: 1.day.ago, answers: OTHERS_ANSWER.deep_dup)
    end
    mine = s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                               completed_at: 1.hour.ago, answers: MY_ANSWER.deep_dup)
    [ s, mine ]
  end

  # One question's block on the page, found by what it asks.
  def question(prompt)
    css_select(".you-q").find { |q| q.at_css(".you-q-prompt")&.text.to_s.strip == prompt } or
      flunk("no block asks #{prompt.inspect}; the page asks #{css_select('.you-q-prompt').map(&:text).inspect}")
  end

  def bars_of(block)
    block.css(".you-bar-row").map do |row|
      { label: row.at_css(".you-bar-label").text.strip, pct: row.at_css(".you-bar-pct").text.strip,
        mine: row["class"].to_s.include?("is-mine") }
    end
  end

  def headings_of(block) = block.css(".you-bar-group").map { |h| h.text.strip }

  test "a swipe card does not take the page down for the person who answered it" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_response :success
  end

  test "a swipe card shows each statement on the card's own scale, with their pick marked" do
    s, mine = mixed_verto
    sign_in_with([ mine ])
    scale = TapScales.for_card(MIXED[6])
    captions = scale.map { |r| r["label"] }

    get you_verto_path(s)
    block = question("Swipe each one")
    bars  = bars_of(block)

    assert_equal [ "Cars belong here", "Trees belong here" ], headings_of(block),
      "the statement heads its own group; folded into each bar's label it truncated before the answer"
    assert_equal captions * 2, bars.map { |b| b[:label] }, "one bar per response, per statement"
    assert_match(/Cars belong here: .+, Trees belong here: .+/, block.at_css(".you-q-mine").text,
                 "their answer names each statement and what they said, not Hash#inspect")
    assert_equal 2, bars.count { |b| b[:mine] }, "exactly one marked bar per statement"
    no = captions[scale.index { |r| r["key"] == "no" }]
    assert_equal [ no, no ], bars.select { |b| b[:mine] }.map { |b| b[:label] }
    # MIN of MIN + 1 said yes to the first statement — a share of that
    # statement, not of the card.
    yes = scale.index { |r| r["key"] == "yes" }
    assert_equal pct(MIN, MIN + 1), bars[yes][:pct]
  end

  test "a rating is drawn on its stars, with their own number marked" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)
    block = question("Rate the street")
    bars  = bars_of(block)

    assert_match "2 ★", block.at_css(".you-q-mine").text
    assert_equal (1..5).map { |i| "#{i} ★" }, bars.map { |b| b[:label] }
    assert_equal [ "2 ★" ], bars.select { |b| b[:mine] }.map { |b| b[:label] }
    assert_equal pct(MIN, MIN + 1), bars.find { |b| b[:label] == "5 ★" }[:pct]
    assert_equal pct(1, MIN + 1),   bars.find { |b| b[:label] == "2 ★" }[:pct]
    assert_equal "0%",  bars.find { |b| b[:label] == "1 ★" }[:pct]
  end

  test "a range or NPS is drawn on the card's own labels, indexed by step" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)

    range = question("How confident are you?")
    assert_match "Low", range.at_css(".you-q-mine").text,
      "stored as step 0, shown as the word the card gave that step"
    assert_equal %w[Low Middling High], bars_of(range).map { |b| b[:label] }
    assert_equal [ "Low" ], bars_of(range).select { |b| b[:mine] }.map { |b| b[:label] }
    assert_equal pct(MIN, MIN + 1), bars_of(range).find { |b| b[:label] == "High" }[:pct]

    nps = question("Would you recommend it?")
    assert_equal (0..10).map(&:to_s), bars_of(nps).map { |b| b[:label] }
    assert_equal [ "3" ], bars_of(nps).select { |b| b[:mine] }.map { |b| b[:label] }
    assert_equal pct(MIN, MIN + 1), bars_of(nps).find { |b| b[:label] == "9" }[:pct]
  end

  test "a ranking shows the group's order by average position, never a percentage over 100" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)
    block = question("Rank these")
    bars  = bars_of(block)

    assert_match "Parks › Jobs › Homes", block.at_css(".you-q-mine").text
    assert_equal [ "1. Homes", "2. Jobs", "3. Parks" ], bars.map { |b| b[:label] },
                 "MIN of MIN + 1 put Homes first, so the group's order is Homes, Jobs, Parks"
    # Homes: MIN people put it 1st and they put it 3rd; Parks the other way round.
    homes = (MIN * 1 + 3) / (MIN + 1.0)
    parks = (MIN * 3 + 1) / (MIN + 1.0)
    assert_equal [ format("avg %.1f", homes), "avg 2.0", format("avg %.1f", parks) ],
                 bars.map { |b| b[:pct] }, "the figure is the mean position, as the player prints it"
    assert bars.none? { |b| b[:mine] },
      "their answer is the WHOLE list, so marking any bar as theirs says nothing"
    block.css(".you-bar-fill").each do |fill|
      assert_operator fill["style"][/width:\s*(\d+)/, 1].to_i, :<=, 100
    end
  end

  test "select-many marks every option they picked" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)
    bars = bars_of(question("How do you get here?"))

    assert_equal %w[Bike Walk], bars.select { |b| b[:mine] }.map { |b| b[:label] }.sort
    assert_equal pct(MIN, MIN + 1), bars.find { |b| b[:label] == "Bus" }[:pct]
  end

  test "a yes/no card that stores no options still gets its bars, from what was answered" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)
    bars = bars_of(question("Do you live nearby?"))

    assert_equal %w[Yes No], bars.map { |b| b[:label] }, "most chosen first, as the player draws it"
    assert_equal [ "No" ], bars.select { |b| b[:mine] }.map { |b| b[:label] }
  end

  test "a location answer is said as the place, not as the stored CC|Label" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)
    block = question("Where do you live?")

    assert_match "London", block.at_css(".you-q-mine").text
    assert_no_match(/GB\|/, block.at_css(".you-q-mine").text)
    assert_empty bars_of(block)
  end

  test "a contact form is never put on the page, theirs or anyone else's" do
    s, mine = mixed_verto
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_no_match(/example\.test/, response.body)
    assert_select ".you-q-prompt", text: "Leave your details", count: 0
  end

  test "the account and the player read one payload, so neither can starve the other" do
    # They share a cache entry on purpose (AggregatesSurveyResults), which is
    # only safe if both build the SAME payload. The account's used to lack the
    # swipe scale and the token rows, so whichever page was opened first decided
    # what the other got for the next ten seconds. The suite's cache is a null
    # store, which is why no test could see it.
    s, mine = mixed_verto(tokenisation_enabled: true,
                          token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    sign_in_with([ mine ])

    stub_method(Rails, :cache, ActiveSupport::Cache::MemoryStore.new) do
      get you_verto_path(s)
      assert_response :success

      get player_results_path(s.publish_token)
      rows = JSON.parse(response.body)["results"]

      tap = rows.find { |r| r["type"] == "tap_card" }
      assert tap["responses"].present?, "the swipe scale the player draws its bars from"
      assert rows.any? { |r| r["type"] == "token_total" }, "the token rows the player folds in"
      assert rows.find { |r| r["type"] == "rating" }.key?("avg")
    end
  end

  # ── A quiz's score ────────────────────────────────────────────────────────
  #
  # On the end screen "How you compare" is asked of the Verto being a quiz and
  # of nothing else — it was never behind show_results_comparison, which is
  # about everyone's ANSWERS. The account's copy follows it.

  QUIZ = [
    { "type" => "welcome_card", "cid" => "w", "text" => "Hello" },
    { "type" => "multiple_choice", "cid" => "a", "text" => "Capital of France?",
      "options" => %w[Paris London], "correct" => "Paris" },
    { "type" => "multiple_choice", "cid" => "b", "text" => "Capital of Spain?",
      "options" => %w[Madrid Rome], "correct" => "Madrid" }
  ].freeze

  def scored(s, score)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        completed_at: 1.day.ago, score: score, quiz_max: 2,
                        answers: { "1" => { "type" => "multiple_choice", "value" => "Paris" } })
  end

  # MIN graded runs besides the one under test, so the score comparison clears
  # the floor without it: one 0, two 1s, and full marks for the rest.
  QUIZ_CROWD = ([ 0, 1, 1 ] + [ 2 ] * (MIN - 3)).freeze

  def quiz_verto(**attrs)
    s = survey(cards: QUIZ, quiz: true, **attrs)
    QUIZ_CROWD.each { |n| scored(s, n) }
    s
  end

  test "a quiz shows your score against everyone's, with your own bucket marked" do
    s = quiz_verto
    sign_in_with([ scored(s, 1) ])

    get you_verto_path(s)

    assert_response :success
    assert_select "#score .you-h2", text: I18n.t("player.quiz_compare_title")
    # QUIZ_CROWD and theirs scored: one scored 0, so 1 of them all is below a
    # score of 1; three scored 1 (two and theirs) and the rest 2.
    total = QUIZ_CROWD.size + 1
    twos  = QUIZ_CROWD.count(2)
    avg   = ((QUIZ_CROWD.sum + 1).to_f / total).round(1)
    assert_select "#score .you-score-meta",
                  text: I18n.t("js.player.quiz_compare_meta", score: 1, max: 2,
                               beat: (100.0 / total).round, avg: avg)
    labels = css_select("#score .you-bar-row .you-bar-label").map { |n| n.text.strip }
    assert_equal %w[0/2 1/2 2/2], labels
    assert_equal [ "1/2" ], css_select("#score .you-bar-row.is-mine .you-bar-label").map { |n| n.text.strip }
    assert_equal [ pct(1, total), pct(3, total), pct(twos, total) ],
                 css_select("#score .you-bar-pct").map { |n| n.text.strip }
  end

  test "the score is there whether or not the creator opened the answers comparison" do
    s = quiz_verto(show_results_comparison: false)
    sign_in_with([ scored(s, 2) ])

    get you_verto_path(s)

    assert_select "#score .you-bar-row", 3
    assert_select "#compare .you-sub", text: I18n.t("you.comparison_off", org: s.organisation.name),
      msg: "the answers stay the creator's to open; the score was never theirs to close"
  end

  test "under the floor the score is refused, and says how many more it needs" do
    s = survey(cards: QUIZ, quiz: true)
    [ 0, 1, 2 ].each { |n| scored(s, n) }
    mine = scored(s, 1)
    sign_in_with([ mine ])

    get you_verto_path(s)

    assert_select "#score .you-bar-row", 0
    assert_select "#score .you-sub", text: I18n.t("you.comparison_too_few")
    assert_select "#score .you-fine",
                  text: I18n.t("you.compare_pending", needed: Response::MIN_REGION_SAMPLE_SIZE, have: 4)
  end

  test "a Verto that is not a quiz has no score card, and a run that was never graded has none" do
    plain = survey
    crowd(plain)
    sign_in_with([ answered(plain) ])
    get you_verto_path(plain)
    assert_select "#score", 0

    q = quiz_verto
    ungraded = q.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                                   answered: true, completed_at: 1.hour.ago, answers: {})
    sign_in_with([ ungraded ])
    get you_verto_path(q)
    assert_select "#score", 0
  end

  test "the list offers a quiz's comparison even when the answers switch is off" do
    s = quiz_verto(show_results_comparison: false)
    sign_in_with([ scored(s, 2) ])

    get you_path

    assert_select ".you-cta-compare", 1
    assert_select ".you-verto-note", text: I18n.t("you.compare_closed", org: s.organisation.name), count: 0
  end

  test "the account fills the player's score cache with what the player reads" do
    s = quiz_verto
    sign_in_with([ scored(s, 1) ])

    stub_method(Rails, :cache, ActiveSupport::Cache::MemoryStore.new) do
      get you_verto_path(s)
      assert_response :success

      get player_scores_path(s.publish_token)
      body = JSON.parse(response.body)

      assert_equal QUIZ_CROWD.size + 1, body["total"]
      assert_equal 2, body["per_question"].size, "the per-question rates the end screen draws"
      assert_equal 3, body["distribution"].size
    end
  end

  # ── Whose Verto is it ─────────────────────────────────────────────────────

  test "a Verto this account has not kept is not found, whether or not it exists" do
    o = org
    mine   = survey(owner: o)
    theirs = survey(owner: o)
    my_run = answered(mine)
    answered(theirs)
    sign_in_with([ my_run ])

    get you_verto_path(theirs)
    assert_redirected_to you_path

    # And an id that is nothing at all reads identically.
    get you_verto_path(999_999)
    assert_redirected_to you_path
  end

  test "signed out, both pages send you to the page that explains what this is" do
    get you_wallet_path
    assert_redirected_to you_path

    get you_verto_path(1)
    assert_redirected_to you_path
  end

  # ── The wallet ────────────────────────────────────────────────────────────

  test "it totals across Vertos and keeps each Verto's piles apart" do
    o = org
    first  = survey(owner: o, tokenisation_enabled: true,
                    token_types: [ { "id" => "gold", "name" => "Ideas", "icon" => "🚲" } ])
    second = survey(owner: o, tokenisation_enabled: true,
                    token_types: [ { "id" => "gold", "name" => "Green", "icon" => "🌳" } ])
    a = answered(first,  tokens: { "gold" => 34 })
    b = answered(second, tokens: { "gold" => 88 })
    sign_in_with([ a, b ])

    get you_wallet_path

    assert_response :success
    assert_select ".you-total", text: "122"
    # Two rows, and the SAME token id means two different things — the piles
    # must not have merged. duplicate! copies token_types verbatim and
    # sanitize_token_types passes creator ids straight through, so this is the
    # ordinary case, not a contrived one.
    assert_select ".you-verto", 2
    assert_select ".you-pile", text: /🚲\s*34\s*Ideas/
    assert_select ".you-pile", text: /🌳\s*88\s*Green/
  end

  test "rows are ordered by when they were answered, not when they were claimed" do
    # A device key can attach a Verto from March to an account today, and one
    # sign-in claims everything at the same microsecond — so claimed_at is both
    # incoherent with the date these pages display and non-deterministic.
    o = org
    older = survey(owner: o, tokenisation_enabled: true,
                   token_types: [ { "id" => "leaf", "name" => "Old", "icon" => "🍂" } ])
    newer = survey(owner: o, tokenisation_enabled: true,
                   token_types: [ { "id" => "leaf", "name" => "New", "icon" => "🌱" } ])
    a = answered(older, tokens: { "leaf" => 1 })
    b = answered(newer, tokens: { "leaf" => 2 })
    a.update_column(:completed_at, 90.days.ago)
    b.update_column(:completed_at, 1.day.ago)
    sign_in_with([ a, b ])

    get you_wallet_path
    # Scoped to the list: the pill's hover breakdown draws the same component
    # for the same rows, in the same order, in the corner of this very page.
    assert_equal [ "🌱 2 New", "🍂 1 Old" ],
                 css_select(".you-list .you-pile").map { |e| e.text.split.join(" ") }

    get you_path
    assert_equal [ newer.id, older.id ].map { |id| you_verto_path(id) },
                 css_select("a.you-verto-link").map { |e| e["href"] }
  end

  test "a Verto that awards nothing is not a row in the wallet" do
    o = org
    with    = survey(owner: o, tokenisation_enabled: true,
                     token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    without = survey(owner: o)
    a = answered(with, tokens: { "leaf" => 5 })
    b = answered(without)
    sign_in_with([ a, b ])

    get you_wallet_path

    assert_select ".you-verto", 1
    assert_select ".you-total", text: "5"
  end

  test "with nothing collected the wallet says so rather than showing a zero" do
    s = survey
    sign_in_with([ answered(s) ])

    get you_wallet_path

    assert_response :success
    assert_select ".you-total", 0
    assert_select ".you-sub", text: I18n.t("you.wallet_empty")
  end

  test "the wallet says why the piles cannot be compared" do
    # Not a disclaimer — anyone reading this will ask, and answering it in the
    # interface is cheaper than answering it in support.
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    sign_in_with([ answered(s, tokens: { "leaf" => 3 }) ])

    get you_wallet_path

    assert_select ".you-foot-note", text: I18n.t("you.wallet_note")
  end

  test "there is no rank that spans Vertos" do
    o = org
    a = survey(owner: o, tokenisation_enabled: true, leaderboard_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    b = survey(owner: o, tokenisation_enabled: true, leaderboard_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    ra = answered(a, tokens: { "leaf" => 10 }, key: "device-1")
    rb = answered(b, tokens: { "leaf" => 90 }, key: "device-1")
    sign_in_with([ ra, rb ])

    get you_wallet_path

    # Each Verto's own board, each with its own anonymous name — the boards
    # were never joined and this must not join them.
    names = css_select(".you-standing").map(&:text)
    assert_equal 2, names.size
    assert_select ".you-total", text: "100"
    # And nothing anywhere claims a position across the two.
    assert_select ".you-total-sub", text: /Across 2 Vertos/
  end

  test "the account's own totals are a snapshot, not a live recomputation" do
    # apply_token_totals recomputes from the CURRENT cards on every save, so a
    # creator re-tuning awards next month changes what future respondents earn.
    # It must not change what this person collected in May.
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    mine = answered(s, tokens: { "leaf" => 40 })
    sign_in_with([ mine ])

    s.update!(cards: CARDS.map(&:dup), token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])

    get you_wallet_path
    assert_select ".you-total", text: "40"
  end

  # ── Getting between them ──────────────────────────────────────────────────

  test "there is no tab row left to mark" do
    # Wallet became the pill in the corner and Next became a strip inside the
    # Verto that points, which left one tab in a row of one. The way back is
    # the same back link the Verto page has always used.
    s = survey
    sign_in_with([ answered(s) ])

    get you_path
    assert_select ".you-tabs", 0

    get you_wallet_path
    assert_select ".you-tabs", 0
    assert_select "a.you-back[href=?]", you_path
  end

  # ── Why a Verto can't be compared ─────────────────────────────────────────
  #
  # Two gates gate the comparison, and from the outside a respondent cannot
  # tell them apart — or tell either from "this is broken". The list says which
  # one, on the row, so nobody opens a Verto to find out there is nothing in it.

  test "a Verto whose results the creator hasn't opened says so on the list" do
    s = survey(show_results_comparison: false)
    crowd(s)
    sign_in_with([ answered(s) ])

    get you_path

    assert_select ".you-verto-note",
                  text: I18n.t("you.compare_closed", org: s.organisation.name)
  end

  test "a Verto below the floor names the floor and the count, not 'soon'" do
    # 2 of 10 tells a respondent whether to come back tomorrow or never.
    # "Not enough yet" tells them nothing and sends them to support.
    s = survey
    crowd(s, 1)
    sign_in_with([ answered(s) ])

    assert_operator s.responses.where(answered: true).count, :<,
                    Response::MIN_REGION_SAMPLE_SIZE
    get you_path

    assert_select ".you-verto-note",
                  text: I18n.t("you.compare_pending",
                               needed: Response::MIN_REGION_SAMPLE_SIZE, have: 2)
  end

  test "a Verto that can be compared is not labelled at all" do
    # Opening it is the point of the row; a badge saying so is noise.
    s = survey
    crowd(s)
    sign_in_with([ answered(s) ])

    get you_path

    assert_select ".you-verto", 1
    assert_select ".you-verto-note", 0
  end

  test "the Verto's own page says when the comparison opens, not just that it hasn't" do
    s = survey
    crowd(s, 2)
    sign_in_with([ answered(s) ])

    get you_verto_path(s)

    assert_select ".you-sub", text: I18n.t("you.comparison_too_few")
    assert_select ".you-fine",
                  text: I18n.t("you.compare_pending",
                               needed: Response::MIN_REGION_SAMPLE_SIZE, have: 3)
  end

  test "the reasons cost one query however many Vertos are listed" do
    # This runs on the page that lists every Verto an account holds, so a
    # per-row count is a per-row query. Counted rather than asserted by eye:
    # the batching is the whole reason the line can live on the list.
    o = org
    claims = 4.times.map do
      s = survey(owner: o)
      crowd(s, 1)
      answered(s)
    end
    sign_in_with(claims)

    counts = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      counts += 1 if payload[:sql].to_s.match?(/COUNT\(\*\).*"responses"/i)
    end
    get you_path
    ActiveSupport::Notifications.unsubscribe(sub)

    assert_select ".you-verto-note", 4
    assert_equal 1, counts,
                 "expected one grouped COUNT over responses for the whole list, got #{counts}"
  end

  # ── What a row lets you do ────────────────────────────────────────────────

  test "exactly one primary per card: Compare when ready, Share otherwise, none when neither" do
    # The whole point of the arrangement: a respondent is never offered two
    # buttons of equal weight, and never one whose destination is the sentence
    # explaining why there is nothing there. Asserted over the four states
    # together rather than one at a time, because "exactly one" is the
    # property — and the reason line stands with Share, not instead of it.
    o = org
    ready  = survey(owner: o)
    thin   = survey(owner: o, theme: "Too few")
    closed = survey(owner: o, theme: "Shut", show_results_comparison: false)
    gone   = survey(owner: o, theme: "Gone", show_results_comparison: false)
    crowd(ready)
    crowd(closed)
    sign_in_with([ answered(ready), answered(thin), answered(closed), answered(gone) ])
    gone.update!(unpublished_at: Time.current)

    get you_path

    rows = css_select(".you-verto")
    assert_equal 4, rows.size
    primaries = rows.to_h do |row|
      [ row.css(".you-verto-title").text.strip, row.css("a.you-cta-primary") ]
    end
    primaries.each { |title, found| assert_operator found.size, :<=, 1, "#{title}: more than one primary" }

    assert_equal 1, primaries["Car-free High Street"].size
    assert primaries["Car-free High Street"].first.classes.include?("you-cta-compare")
    assert_equal you_verto_path(ready, anchor: "compare"), primaries["Car-free High Street"].first["href"]
    assert primaries["Too few"].first.classes.include?("you-cta-share")
    assert primaries["Shut"].first.classes.include?("you-cta-share")
    assert_empty primaries["Gone"], "closed and unplayable, there is nothing to press for"

    # The reason line stands on the two cards that cannot be compared yet, and
    # on those alone.
    assert_select ".you-verto-note", 3
    assert_select "a.you-cta-primary.you-cta-compare", 1
    assert_select "a.you-cta-primary", text: /#{I18n.t("you.cta_compare")}/, count: 1
  end

  test "the impact link is on every card, and Share on every card that can be played" do
    o = org
    closed = survey(owner: o, show_results_comparison: false)
    sign_in_with([ answered(closed) ])

    get you_path

    assert_select "a.you-cta.you-cta-impact[href=?]", you_verto_path(closed, anchor: "impact"),
                  text: I18n.t("you.cta_impact_short")
    # Share hands over the PLAY url — the thing a friend can open — not the
    # account page, which would be a link only this respondent can use. On a
    # closed Verto it is the primary, since sharing is the one thing left.
    assert_select "a.you-cta-primary.you-cta-share[href=?]", play_survey_url(closed.publish_token),
                  text: /#{I18n.t("you.cta_share")}/
  end

  test "a Verto nobody can play any more is not offered for sharing" do
    o = org
    s = survey(owner: o)
    sign_in_with([ answered(s) ])
    # Unpublishing is unpublished_at, not clearing published_at — published?
    # reads the token and the close stamp (Survey#published?).
    s.update!(unpublished_at: Time.current)
    refute s.reload.playable?

    get you_path

    assert_select ".you-verto", 1
    assert_select "a[data-controller=?]", "share-verto", 0
    assert_select "a[href=?]", play_survey_url(s.publish_token), 0
    # The row itself still works — they kept it, and keeping it is the point.
    assert_select "a.you-verto-link[href=?]", you_verto_path(s)
  end

  # ── The wallet pill ───────────────────────────────────────────────────────
  #
  # The wallet stopped being a tab and became a pill in the top corner, so the
  # tests that used to say "the tab is there and marks the page" say it about
  # the pill — and about the thing a tab could never do, which is carry the
  # number that makes it worth pressing.

  def pilled(owner, name, icon, amount, id: "gold")
    s = survey(owner: owner, tokenisation_enabled: true,
               token_types: [ { "id" => id, "name" => name, "icon" => icon } ])
    [ s, answered(s, tokens: { id => amount }) ]
  end

  test "the pill carries the total on every page of the account, and marks the wallet" do
    o = org
    first,  a = pilled(o, "Ideas", "🚲", 34)
    _second, b = pilled(o, "Green", "🌳", 88)
    sign_in_with([ a, b ])

    [ you_path, you_verto_path(first) ].each do |path|
      get path
      assert_select "a.you-purse-pill[href=?]", you_wallet_path, 1, "no wallet pill on #{path}"
      assert_select ".you-purse-total", text: "122"
      # Off the wallet, the pill is a way there and not a marker of where you
      # are. Two aria-currents on one page is a page that cannot say.
      assert_select ".you-purse-pill[aria-current]", 0, "#{path} marked the pill as the current page"
    end

    get you_wallet_path
    assert_select ".you-purse-pill[aria-current=page]", 1
    # And the one number is one computation: the pill and the page it links to
    # cannot disagree about what the account holds.
    assert_select ".you-purse-total", text: "122"
    assert_select ".you-total", text: "122"
  end

  test "the pill's breakdown keeps each Verto's tokens apart, and offers the rest" do
    o = org
    _first,  a = pilled(o, "Ideas", "🚲", 34)
    _second, b = pilled(o, "Green", "🌳", 88)
    sign_in_with([ a, b ])

    get you_path

    # Two Vertos, both using the id "gold" for two different things — the
    # breakdown names each Verto and counts its own tokens under it.
    assert_select ".you-purse-row", 2
    assert_select ".you-purse-row .you-pile", text: /🚲\s*34\s*Ideas/
    assert_select ".you-purse-row .you-pile", text: /🌳\s*88\s*Green/
    assert_select ".you-purse-verto", text: "Car-free High Street", count: 2
    assert_select "a.you-purse-all[href=?]", you_wallet_path, text: /#{I18n.t("you.wallet_see_all")}/
  end

  test "the breakdown is a peek at five, not a second wallet" do
    o = org
    claims = 7.times.map { |i| pilled(o, "Leaves", "🍃", i + 1, id: "leaf-#{i}").last }
    sign_in_with(claims)

    get you_path
    assert_select ".you-purse-row", YouController::PURSE_PREVIEW
    # The rest are not lost, they are behind the CTA.
    assert_select "a.you-purse-all[href=?]", you_wallet_path

    get you_wallet_path
    assert_select ".you-list .you-verto", 7
    assert_select ".you-total", text: "28"
  end

  test "the breakdown is a peek for a pointer, never a second reading of the page" do
    # Every row in it is on the wallet the pill points at, and the pill's own
    # label already carries the total. Exposing it would put the same five
    # Vertos into the reading order of every page of the account.
    o = org
    _s, a = pilled(o, "Ideas", "🚲", 34)
    sign_in_with([ a ])

    get you_path

    assert_select ".you-purse-popover[aria-hidden=true][hidden]", 1
    assert_select ".you-purse-pill[aria-label=?]",
                  I18n.t("you.wallet_pill", total: "34")
    # Nothing inside it is reachable by tab — focusable content inside
    # aria-hidden is a trap rather than a shortcut.
    assert_select ".you-purse-popover a[tabindex=?]", "-1", 1
    assert_select ".you-purse-popover a:not([tabindex])", 0
  end

  test "with nothing collected the chip stays but carries no number, and no breakdown" do
    # The wallet already made this choice: it says "no points yet" rather than
    # showing a zero. The chip is navigation now, and a missing tab reads as a
    # missing page — so it stays, with nothing on it to promise that sentence.
    s = survey
    sign_in_with([ answered(s) ])

    get you_path
    assert_select "a.you-purse-pill[href=?]", you_wallet_path, 1
    assert_select ".you-purse-total", 0
    assert_select ".you-purse-popover", 0
    assert_select ".you-purse-pill[aria-label]", 0

    # The page itself is still reachable, and still says so.
    get you_wallet_path
    assert_response :success
    assert_select ".you-sub", text: I18n.t("you.wallet_empty")
    assert_select ".you-purse-total", 0
    assert_select ".you-purse-popover", 0
  end

  test "signed out there is no pill at all" do
    get you_path

    assert_response :success
    assert_select ".you-purse", 0
  end

  test "every Verto in the list opens its own page" do
    s = survey
    sign_in_with([ answered(s) ])

    get you_path
    assert_select "a.you-verto-link[href=?]", you_verto_path(s)
  end

  test "the account renders in en-US, not only in en" do
    # The whole suite runs in `en`, so a key that is broken only in the
    # GENERATED en-US.yml is invisible to every other test here. That is not
    # hypothetical: wallet_across shipped with %{organisations} in it, the
    # generator respelled the interpolation NAME to %{organizations}, and the
    # page raised MissingInterpolationArgument for every en-US visitor while
    # `en` stayed green. EnglishSpellings now protects placeholders and
    # en_us_locale_test guards the file; this renders the pages under the
    # variant so a future one cannot slip through either.
    s = survey(tokenisation_enabled: true,
               token_types: [ { "id" => "leaf", "name" => "Leaves", "icon" => "🍃" } ])
    crowd(s)
    sign_in_with([ answered(s, tokens: { "leaf" => 12 }) ])

    get you_wallet_path(locale: "en-US")
    assert_response :success
    assert_select ".you-total", text: "12"

    get you_verto_path(s, locale: "en-US")
    assert_response :success
    assert_select ".you-q-prompt"
  end

  test "these pages are never written to a shared browser's disk cache" do
    s = survey
    sign_in_with([ answered(s) ])

    get you_wallet_path
    assert_equal "no-store", response.headers["Cache-Control"]

    get you_verto_path(s)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match(/noindex/, response.headers["X-Robots-Tag"].to_s)
  end
end
