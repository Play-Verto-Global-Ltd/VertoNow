require "test_helper"

# CommonQuestionAggregator rolls a set's answers up across every Verto that
# attached it — including, for a funder portfolio, across every grantee
# organisation at once.
#
# It used to do that by loading every response of every contributing Verto into
# memory WHOLE (quiz scores, token totals, region strings, consent snapshots) to
# read one JSON column, then firing an EXISTS query per survey on top. On a
# 512MB instance that is the shape that trips the memory watchdog — P1-8.
class CommonQuestionAggregatorTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "O", slug: "cqa-#{SecureRandom.hex(3)}")
    @set = @org.common_question_sets.create!(name: "Wellbeing", theme: "T", key_insight: "x",
                                             default_locale: "en")
    @q = @set.common_questions.create!(position: 0, text: "How safe do you feel?",
                                       card_type: "yes_no", options: %w[Yes No])
  end

  def survey_with_set(title: "S", snapshot: @q.text, responses: 0)
    s = @org.surveys.create!(title: title, theme: "T", audience_age: "all", key_insight: "x",
                             default_locale: "en", locales: [ "en" ],
                             cards: [
                               { "type" => "welcome_card", "title" => "hi" },
                               { "type" => "yes_no", "text" => snapshot, "options" => %w[Yes No],
                                 "common_question_set_id" => @set.id, "common_question_id" => @q.id }
                             ])
    responses.times do |i|
      s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                          answers: { "1" => { "value" => i.even? ? "Yes" : "No" } })
    end
    s
  end

  def aggregate(surveys)
    CommonQuestionAggregator.new(@set, surveys).aggregate
  end

  # ── It still produces the same answer ─────────────────────────────────────

  test "it clusters answers across every contributing Verto" do
    a = survey_with_set(title: "A", responses: 3)
    b = survey_with_set(title: "B", responses: 2)

    per_question, _variants, total_surveys, total_responses = aggregate([ a, b ])

    assert_equal 2, total_surveys
    assert_equal 5, total_responses
    row = per_question.first
    assert_equal @q, row[:common_question]
    assert_equal 5, row[:total], "every answer counted, across both Vertos"
  end

  test "wording drift is still surfaced" do
    a = survey_with_set(title: "A", responses: 1)
    b = survey_with_set(title: "B", snapshot: "How safe is your area?", responses: 1)

    per_question, variants, = aggregate([ a, b ])
    assert per_question.first[:drift?], "the two snapshots differ from the master text"
    assert_equal 2, variants[@q.id].keys.size
  end

  test "a Verto with no responses contributes nothing" do
    a = survey_with_set(title: "A", responses: 2)
    b = survey_with_set(title: "B", responses: 0)

    _pq, _v, total_surveys, total_responses = aggregate([ a, b ])
    assert_equal 1, total_surveys, "'surveys contributing data' means what it says"
    assert_equal 2, total_responses
  end

  test "blank answers are skipped but still counted as responses" do
    s = survey_with_set(title: "A")
    s.responses.create!(session_token: SecureRandom.uuid, answers: { "1" => { "value" => "" } })
    s.responses.create!(session_token: SecureRandom.uuid, answers: {})

    per_question, _v, _ts, total_responses = aggregate([ s ])
    assert_equal 2, total_responses, "they responded, they just didn't answer this one"
    assert_equal 0, per_question.first[:total]
  end

  # The Other box is an answer on its own, and it combines with a tick: the
  # set's roll-up counts the same people the Verto's own results page counts,
  # once each.
  test "a write-in alone is an answer, and a write-in beside a tick is one respondent" do
    s = survey_with_set(title: "A")
    s.responses.create!(session_token: SecureRandom.uuid, answers: { "1" => { "value" => nil, "other" => "Mostly" } })
    s.responses.create!(session_token: SecureRandom.uuid, answers: { "1" => { "value" => "Yes", "other" => "but not at night" } })

    per_question, = aggregate([ s ])
    assert_equal 2, per_question.first[:total]
  end

  test "an empty survey list aggregates to zero rather than raising" do
    per_question, _v, total_surveys, total_responses = aggregate([])
    assert_equal 0, total_surveys
    assert_equal 0, total_responses
    assert_equal 1, per_question.size, "one row per master question, even with no data"
  end

  # ── …without loading the world to do it ───────────────────────────────────

  test "responses are read two columns at a time, not whole" do
    s = survey_with_set(title: "A", responses: 2)

    selected = nil
    ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      selected = sql if sql.include?('FROM "responses"') && sql.start_with?("SELECT")
    end
    aggregate([ s ])
    ActiveSupport::Notifications.unsubscribe("sql.active_record")

    assert selected, "expected a responses query"
    assert_no_match(/SELECT\s+"responses"\.\*/, selected,
                    "loading every column to read one JSON field is the whole defect")
    assert_match(/"responses"\."answers"/, selected)
  end

  # The old code fired one EXISTS per survey, AFTER loading all their responses.
  test "it does not re-query per survey to count contributors" do
    surveys = 4.times.map { |i| survey_with_set(title: "S#{i}", responses: 1) }

    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].to_s.include?('FROM "responses"') }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { aggregate(surveys) }

    # find_each issues one batched SELECT per survey; the point is that there is
    # no second per-survey query on top of it.
    assert_operator queries, :<=, surveys.size,
                    "one pass per Verto, not a pass plus an EXISTS each"
  end
end

# The Common Questions index showed two tallies — how many Vertos use a set, and
# how many responses those Vertos hold — by eager-loading every response row of
# every attached Verto and calling .size on them.
class CommonQuestionSetsIndexCountsTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "cqi-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "cqi-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @set = @org.common_question_sets.create!(name: "Wellbeing", theme: "T", key_insight: "x", default_locale: "en")
    @q = @set.common_questions.create!(position: 0, text: "Safe?", card_type: "yes_no", options: %w[Yes No])

    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def attached_survey(responses: 0, attach: true)
    card = { "type" => "yes_no", "text" => "Safe?", "options" => %w[Yes No] }
    card.merge!("common_question_set_id" => @set.id, "common_question_id" => @q.id) if attach
    s = @org.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "x",
                             default_locale: "en", locales: [ "en" ], cards: [ card ])
    responses.times { s.responses.create!(session_token: SecureRandom.uuid, answers: {}) }
    s
  end

  # Asserted on the rendered tiles rather than on assigns, which needs the
  # rails-controller-testing gem this app doesn't carry.
  def stat(label)
    node = css_select("div").find { |d| d.text.strip == label }
    node&.parent&.at_css("div")&.text&.strip
  end

  test "the counts are right" do
    attached_survey(responses: 3)
    attached_survey(responses: 2)
    attached_survey(responses: 9, attach: false)   # not using the set

    get common_question_sets_path
    assert_response :success
    assert_equal "2", stat(I18n.t("common_questions.stat_vertos", default: "In Vertos"))
    assert_equal "5", stat(I18n.t("common_questions.stat_responses", default: "Responses")),
                 "only the attached Vertos' responses"
  end

  test "no attached Vertos counts zero without querying for responses at all" do
    attached_survey(responses: 4, attach: false)

    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].to_s.include?('FROM "responses"') }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get common_question_sets_path }

    assert_response :success
    assert_equal "0", stat(I18n.t("common_questions.stat_responses", default: "Responses"))
    assert_equal 0, queries
  end

  test "responses are counted in SQL, never loaded" do
    attached_survey(responses: 3)

    statements = []
    collector = ->(*, payload) { statements << payload[:sql].to_s if payload[:sql].to_s.include?('FROM "responses"') }
    ActiveSupport::Notifications.subscribed(collector, "sql.active_record") { get common_question_sets_path }

    assert_response :success
    assert_equal 1, statements.size, "one COUNT, not a load per Verto"
    assert_match(/SELECT COUNT/i, statements.first)
    assert_no_match(/"responses"\."answers"/, statements.first,
                    "the answers JSON has no business being read to produce a tally")
  end
end
