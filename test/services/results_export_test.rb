require "test_helper"

class ResultsExportTest < ActiveSupport::TestCase
  # Computes aggregate_results the same way the controllers do.
  AGG = Class.new do
    include AggregatesSurveyResults
    def build(cards, responses) = aggregate_results(cards, responses)
  end.new

  def setup
    @org = Organisation.create!(name: "T", slug: "rex-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome" },
        { "type" => "multiple_choice", "text" => "Favourite colour?", "options" => %w[Blue Green Red], "allow_other" => true },
        { "type" => "select_many", "text" => "Which fruits?", "options" => %w[Apple Banana Cherry] },
        { "type" => "range", "text" => "How happy?", "options" => %w[Sad Meh Neutral Good Great] },
        { "type" => "rating", "text" => "Rate us" },
        { "type" => "tap_card", "text" => "Agree?", "options" => [ "Stmt A", "Stmt B" ] },
        { "type" => "scenario", "text" => "Which path?", "pages" => [ { "id" => "pg1", "text" => "You reach a fork in the trail." } ], "options" => %w[Left Right] },
        { "type" => "open_ended", "text" => "Comments?" }
      ]
    )
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answers: {
      "1" => { "type" => "multiple_choice", "value" => "Blue" },
      "2" => { "type" => "select_many", "value" => %w[Apple Cherry] },
      "3" => { "type" => "range", "value" => 3 },
      "4" => { "type" => "rating", "value" => 5 },
      "5" => { "type" => "tap_card", "value" => { "Stmt A" => "yes", "Stmt B" => "no" } },
      "6" => { "type" => "scenario", "value" => "Left" },
      "7" => { "type" => "open_ended", "value" => "Great job" }
    })
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "es", answers: {
      "1" => { "type" => "multiple_choice", "value" => nil, "other" => "Purple" },
      "2" => { "type" => "select_many", "value" => %w[Banana] },
      "3" => { "type" => "range", "value" => 0 },
      "4" => { "type" => "rating", "value" => 3 },
      "5" => { "type" => "tap_card", "value" => { "Stmt A" => "no", "Stmt B" => "no" } },
      "6" => { "type" => "scenario", "value" => "Right" },
      "7" => { "type" => "open_ended", "value" => "" }
    })
    responses   = @survey.responses.where(status: "completed").order(:created_at)
    aggregated  = AGG.build(Array(@survey.cards), responses)
    @export     = ResultsExport.new(survey: @survey, responses: responses, aggregated: aggregated)
  end

  def teardown
    @survey.destroy
    @org.destroy
  end

  # Answer columns start after the per-response metadata columns. Derived from
  # the constant rather than hard-coded, so adding a metadata column doesn't
  # send every index below off by one.
  META = ResultsExport::RESPONSE_HEADER.size

  test "response_rows header lists question texts and skips the welcome card" do
    header = @export.response_rows.first
    assert_equal [ "Response ID", "Submitted at", "Source", "Language",
                   "Duration (seconds)", "Device", "Responder", "Device group" ], header.first(META).map(&:to_s)
    questions = [ "Favourite colour?", "Which fruits?", "How happy?", "Rate us", "Agree?", "Which path?", "Comments?" ]
    assert_equal questions, header[META, questions.size]
    # The dwell block comes AFTER every answer column, so nothing that reads
    # this file by column position moves when it is added.
    assert_equal questions.map { |q| "Dwell time (seconds): #{q}" } + [ "Total dwell time (seconds)" ],
                 header[(META + questions.size)..],
                 "the whole run's total follows the per-question block it is the sum of"
    refute_includes header, "Welcome"
  end

  SOURCE_COL = ResultsExport::RESPONSE_HEADER.index("Source")

  # Which address a response came in on. A custom link names itself; recalling
  # the link keeps the name on its old rows; deleting it (nullify) drops them
  # back to the Verto's own address.
  test "the Source column names the custom link a response came through" do
    link = @survey.survey_links.create!(name: "Newsletter", slug: "rex-news-#{SecureRandom.hex(2)}")
    via_link = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                                         survey_link: link,
                                         answers: { "1" => { "type" => "multiple_choice", "value" => "Red" } })
    rebuild_export!

    rows = @export.response_rows.drop(1)
    assert_equal [ "Direct link", "Direct link", "Newsletter" ], rows.map { |r| r[SOURCE_COL] },
                 "the plain rows keep the Verto's own label; the link row carries its name"

    link.update!(active: false)
    rebuild_export!
    assert_equal "Newsletter", @export.response_rows.last[SOURCE_COL], "a recalled link still labels its old responses"

    link.destroy
    rebuild_export!
    assert_equal "Direct link", @export.response_rows.last[SOURCE_COL],
                 "a deleted link nullifies its stamp, so the row reads as the Verto's own again"
    assert_nil via_link.reload.survey_link_id
  end

  def rebuild_export!
    responses  = @survey.responses.where(status: "completed").order(:created_at)
    aggregated = AGG.build(Array(@survey.cards), responses)
    @export    = ResultsExport.new(survey: @survey, responses: responses, aggregated: aggregated)
  end

  test "response_rows formats each card type and the Other free-text" do
    rows = @export.response_rows
    assert_equal 3, rows.size # header + 2 responses

    first = rows[1]
    assert_equal "Blue", first[META]
    assert_equal "Apple; Cherry", first[META + 1]           # select_many joined
    assert_equal "Good", first[META + 2]                    # range index 3 -> options[3]
    assert_equal "5", first[META + 3]                        # rating
    # The response LABEL, not the key it is stored under: "strongly_agree" is
    # not a thing anyone said, and on a renamed scale it isn't even close.
    assert_equal "Stmt A: Yes; Stmt B: No", first[META + 4] # tap_card hash
    assert_equal "Left", first[META + 5]                     # scenario, formatted like multiple_choice
    assert_equal "Great job", first[META + 6]

    second = rows[2]
    assert_equal "Other: Purple", second[META]              # value nil + other
    assert_equal "Banana", second[META + 1]
    assert_equal "Sad", second[META + 2]                    # range index 0
    assert_equal "Right", second[META + 5]
    assert_equal "", second[META + 6]                        # blank open_ended
  end

  # ── Dwell time ─────────────────────────────────────────────────────────────

  test "each response's dwell time per question rides in the block after the answers, in seconds" do
    first, second = @survey.responses.order(:created_at).to_a
    first.update!(dwell_ms:  { "1" => 4210, "3" => 12_000, "7" => 61_449 })
    second.update!(dwell_ms: { "1" => 999 })
    rebuild_export!

    rows   = @export.response_rows
    header = rows.first
    base   = META + 7 # the seven question columns
    assert_equal "Dwell time (seconds): Favourite colour?", header[base]
    assert_equal "Dwell time (seconds): Comments?", header[base + 6]

    assert_equal [ 4.2, "", 12.0, "", "", "", 61.4 ], rows[1][base, 7]
    assert_equal [ 1.0, "", "", "", "", "", "" ],     rows[2][base, 7], "blank where nothing was recorded"
    assert_equal [ 77.7, 1.0 ], [ rows[1][base + 7], rows[2][base + 7] ], "the total is the sum of the run's dwell"
  end

  test "a response from before dwell existed exports blank dwell cells, not zeros" do
    rows = @export.response_rows
    assert_equal Array.new(8, ""), rows[1][(META + 7)..], "seven question columns and the total"
  end

  test "summary_rows carry a median and mean dwell row per question that has any" do
    first, second = @survey.responses.order(:created_at).to_a
    first.update!(dwell_ms:  { "1" => 4000, "3" => 10_000 })
    second.update!(dwell_ms: { "1" => 10_000 })
    rebuild_export!

    rows = @export.summary_rows
    colour = rows.select { |r| r[2] == "Favourite colour?" }
    assert_includes colour, [ 2, "multiple_choice", "Favourite colour?", "Time to answer — median (seconds)", 7.0, nil, 2 ]
    assert_includes colour, [ 2, "multiple_choice", "Favourite colour?", "Time to answer — mean (seconds)", 7.0, nil, 2 ]
    # The timing rows come after the card's own answer rows, so a reader going
    # down the card meets its options first.
    labels = colour.map { |r| r[3] }
    assert_equal labels.size - 2, labels.index("Time to answer — median (seconds)")

    happy = rows.select { |r| r[2] == "How happy?" }
    assert_includes happy, [ 4, "range", "How happy?", "Time to answer — median (seconds)", 10.0, nil, 1 ]
    assert_equal 7, happy.size, "five steps plus the two timing rows"

    fruits = rows.select { |r| r[2] == "Which fruits?" }
    refute fruits.any? { |r| r[3].to_s.start_with?("Time to answer") }, "no dwell recorded, no timing rows"
  end

  test "the summary's time to answer is over answered cards, the per-response dwell is time on the card" do
    first, second = @survey.responses.order(:created_at).to_a
    # The second respondent spent twenty seconds on "Comments?" and left it blank.
    first.update!(dwell_ms:  { "7" => 5000 })
    second.update!(dwell_ms: { "7" => 20_000 })
    rebuild_export!

    comments = @export.summary_rows.select { |r| r[2] == "Comments?" }
    assert_includes comments, [ 8, "open_ended", "Comments?", "Time to answer — median (seconds)", 5.0, nil, 1 ]

    rows = @export.response_rows
    assert_equal [ 5.0, 20.0 ], [ rows[1].last, rows[2].last ], "both times are real, and both are in the row"
  end

  test "summary_rows produce counts and percentages per option" do
    rows = @export.summary_rows
    assert_equal ResultsExport::SUMMARY_HEADER, rows.first

    colour = rows.select { |r| r[2] == "Favourite colour?" }
    assert_includes colour, [ 2, "multiple_choice", "Favourite colour?", "Blue", 1, 50.0, 2 ]
    assert_includes colour, [ 2, "multiple_choice", "Favourite colour?", "Other", 1, 50.0, 2 ]

    happy = rows.select { |r| r[2] == "How happy?" }
    assert_equal 5, happy.size # one row per range step
    assert_includes happy, [ 4, "range", "How happy?", "Good", 1, 50.0, 2 ]

    rating = rows.select { |r| r[2] == "Rate us" }
    assert_includes rating, [ 5, "rating", "Rate us", "Average (1–5)", 4.0, nil, 2 ]

    agree = rows.select { |r| r[2] == "Agree?" }
    assert_includes agree, [ 6, "tap_card", "Agree?", "Stmt B — No", 2, 100.0, 2 ]

    path = rows.select { |r| r[2] == "Which path?" }
    assert_includes path, [ 7, "scenario", "Which path?", "Left", 1, 50.0, 2 ]
    assert_includes path, [ 7, "scenario", "Which path?", "Right", 1, 50.0, 2 ]

    refute rows.any? { |r| r[1] == "welcome_card" }, "welcome card should be excluded from the summary"
  end

  # ── Responder / Device group columns ───────────────────────────────────────
  # A responder = rows sharing respondent_code_digest; the export groups their
  # runs under one minted anonymous name. The digests themselves must never
  # appear — a digest is a stable cross-export handle on a hashed value.

  RESP_COL = ResultsExport::RESPONDER_COLUMN
  DEV_COL  = ResultsExport::DEVICE_GROUP_COLUMN

  def coded_response(code:, at:, device: nil)
    @survey.responses.create!(
      session_token: SecureRandom.uuid, status: "completed", locale: "en",
      answers: { "1" => { "type" => "multiple_choice", "value" => "Blue" } },
      respondent_code_digest: code && @survey.respondent_code_digest(code),
      player_key_digest: device && @survey.player_key_digest(device),
      created_at: at, updated_at: at)
  end

  def fresh_export(responses = @survey.responses.where(status: "completed").order(:created_at))
    ResultsExport.new(survey: @survey, responses: responses,
                      aggregated: AGG.build(Array(@survey.cards), responses))
  end

  test "rows group by responder under one minted name, uncoded rows last" do
    a1 = coded_response(code: "sam14", at: 4.days.ago)
    b  = coded_response(code: "blue7", at: 3.days.ago)
    a2 = coded_response(code: "SAM 14", at: 2.days.ago) # normalizes to sam14

    body = fresh_export.response_rows.drop(1)
    named, blank = body.partition { |r| r[RESP_COL].present? }

    # The two uncoded setup responses trail every named group — even though
    # they were created after the coded ones.
    assert_equal 2, blank.size
    assert_equal blank, body.last(2), "uncoded rows must sort behind every named group"

    sam_rows = named.select { |r| [ a1.id, a2.id ].include?(r[0]) }
    assert_equal 1, sam_rows.map { |r| r[RESP_COL] }.uniq.size,
                 "the same normalized code must always wear the same name"
    assert_equal [ a1.id, a2.id ], sam_rows.map { |r| r[0] }, "runs in play order"
    assert_equal sam_rows[1], body[body.index(sam_rows[0]) + 1],
                 "a responder's runs must sit on adjacent rows"

    blue_name = named.find { |r| r[0] == b.id }[RESP_COL]
    refute_equal sam_rows.first[RESP_COL], blue_name
    assert RespondentAlias.exists?(survey_id: @survey.id, anon_name: blue_name),
           "the label is a minted alias, not derived text"
  end

  test "the export never contains a digest or a typed code" do
    row = coded_response(code: "sam14", at: 1.day.ago, device: "device-uuid-1")

    flat = fresh_export.response_rows.flatten.map(&:to_s).join("|")
    refute_includes flat, row.respondent_code_digest
    refute_includes flat, row.player_key_digest
    refute_includes flat, "sam14"
  end

  test "joining an account never populates Device group" do
    # The defect this guards, found in review before the account shipped: a
    # respondent account that wrote a player_key_digest onto the claimed
    # response would populate this column for exactly the people who opted in,
    # and #alias_names has no feature gate to stop it — so the creator's CSV
    # would report opt-in status under a column about browsers. (The same
    # digest would let a later leaderboard enable build a board out of joiners
    # alone, via LeaderboardStanding.completed_identities.)
    #
    # PlayerController#join therefore writes no digest at all: the run just
    # finished is claimed by session_token. This asserts the outcome rather
    # than the mechanism, so it still holds if the mechanism is rewritten.
    @survey.update!(join_prompt_enabled: true)
    joined = coded_response(code: nil, at: 1.day.ago)
    walked = coded_response(code: nil, at: 2.days.ago)
    player = Player.for_email("re-#{SecureRandom.hex(3)}@test.com")
    PlayerClaim.claim!(player: player, response: joined, source: "signup")

    body = fresh_export.response_rows.drop(1)
    assert_equal "", body.find { |r| r[0] == joined.id }[DEV_COL],
                 "an account must be invisible in the creator's export"
    assert_equal "", body.find { |r| r[0] == walked.id }[DEV_COL]
    assert_nil joined.reload.player_key_digest
  end

  test "Device group wears the leaderboard's exact name, stable across exports" do
    row = coded_response(code: nil, at: 1.day.ago, device: "device-uuid-9")
    board_name = PlayerAlias.ensure_for!(survey: @survey, key_digest: row.player_key_digest).anon_name

    first  = fresh_export.response_rows.drop(1).find { |r| r[0] == row.id }
    assert_equal board_name, first[DEV_COL], "one browser, one name — board and export agree"
    assert_equal "", first[RESP_COL], "no code entered means no responder"

    again = fresh_export.response_rows.drop(1).find { |r| r[0] == row.id }
    assert_equal board_name, again[DEV_COL], "minted names never change between exports"
  end

  test "the relation and in-memory branches produce identical rows" do
    coded_response(code: "sam14", at: 3.days.ago)
    coded_response(code: "blue7", at: 2.days.ago)
    coded_response(code: "sam14", at: 1.day.ago)

    relation = @survey.responses.where(status: "completed").order(:created_at)
    assert_equal fresh_export(relation).response_rows,
                 fresh_export(relation.to_a).response_rows
  end
end
