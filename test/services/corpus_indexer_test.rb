require "test_helper"

# What crosses the organisation boundary, and what must not.
#
# Two of these tests guard failure modes that are silent — the kind that ship,
# get cited in a funder's report, and are only noticed by someone who happens to
# know the data:
#
#   * prioritise counts are SUMS OF RANKS, not frequencies. Indexed as counts,
#     every prioritise citation is confidently wrong with no visible symptom.
#   * a suppressed cell must be ABSENT, not zero. A published "0" says nobody in
#     that group answered that way, which in a small group is a statement about
#     named people.
class CorpusIndexerTest < ActiveSupport::TestCase
  # Themes and quotes need a Claude call; every test here is about the numbers,
  # so the themer is a stub that returns nothing.
  class NullThemer
    def call(**) = { themes: [], quotes: [] }
  end

  def setup
    @org = Organisation.create!(name: "O", slug: "ci-#{SecureRandom.hex(3)}")
  end

  def survey_with(cards)
    @org.surveys.create!(title: "S", theme: "Climate", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards)
  end

  # n completed responses, each answering card 0 with the value yielded.
  def seed!(survey, n)
    n.times do |i|
      survey.responses.create!(
        session_token: SecureRandom.hex(8), status: "completed",
        answers: yield(i)
      )
    end
  end

  def index!(survey)
    entry = CorpusEntry.create!(survey: survey, organisation: @org,
                                opted_in_at: Time.current, review_status: "approved")
    CorpusIndexer.new(entry, themer: NullThemer.new).call
    entry.reload
  end

  # The floor defaults to 10, the Privacy Notice's minimum group (see "by
  # default the floor is the Privacy Notice's minimum group" below). The tests
  # that guard the SUPPRESSION MACHINERY set 30 — the original floor, still one
  # ASK_VERTO_MIN_CELL away — explicitly. They are not describing the default;
  # they are proving the mechanism follows whatever floor a deployment sets,
  # which is the only thing that makes setting one a real option.
  def with_floor(size = 30, &block) = CorpusEntry.with_min_sample_size(size, &block)

  # ── The prioritise trap ───────────────────────────────────────────────────
  test "prioritise is stored as a mean rank, never as counts" do
    survey = survey_with([ { "type" => "prioritise", "cid" => "c_p", "text" => "Rank these",
                             "options" => [ "Money", "Time", "Info" ] } ])
    # Everyone ranks Money first, Time second, Info third. As RANK SUMS that is
    # Money 40, Time 80, Info 120 for 40 respondents — numbers that look exactly
    # like counts and mean the opposite (lower = more important).
    seed!(survey, 40) { { "0" => { "value" => [ "Money", "Time", "Info" ] } } }

    entry = index!(survey)
    question = entry.corpus_questions.find_by(cid: "c_p")

    assert_not_nil question
    assert_equal %w[mean_rank], question.distribution.keys,
      "a prioritise distribution must expose ONLY mean_rank — a counts key would be read as a frequency"
    assert_in_delta 1.0, question.distribution["mean_rank"]["Money"], 0.01
    assert_in_delta 2.0, question.distribution["mean_rank"]["Time"], 0.01
    assert_in_delta 3.0, question.distribution["mean_rank"]["Info"], 0.01
    # The raw rank sums (40, 80, 120) must not survive anywhere.
    assert_not_includes question.distribution.to_json, "120"
  end

  # The card type is retired, but decks that ran while it was live still hold
  # both the card and what it collected — so "never indexed" is still a live
  # guarantee about data Ask Verto can reach, not a historical note.
  test "contact_form is never indexed" do
    survey = survey_with([ { "type" => "contact_form", "cid" => "c_cf", "text" => "Stay in touch" } ])
    seed!(survey, 40) { { "0" => { "value" => { "name" => "Real Person", "email" => "a@b.com" } } } }

    entry = index!(survey)

    assert_empty entry.corpus_questions
    assert_not_includes entry.corpus_questions.to_json, "a@b.com"
  end

  # ── Sample floors ─────────────────────────────────────────────────────────
  test "a Verto under the sample floor indexes nothing" do
    with_floor do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, CorpusEntry.min_sample_size - 1) { { "0" => { "value" => "Yes" } } }

    entry = index!(survey)

    assert_empty entry.corpus_questions
    assert_equal CorpusEntry.min_sample_size - 1, entry.response_count
    assert_not_nil entry.indexed_at, "it was still looked at — that is not the same as never indexed"
    end
  end

  test "a question answered by too few people is left out even when the Verto clears the floor" do
    with_floor do
    survey = survey_with([
      { "type" => "yes_no", "cid" => "c_answered", "text" => "Everyone answers", "options" => %w[Yes No] },
      { "type" => "yes_no", "cid" => "c_skipped",  "text" => "Almost nobody does", "options" => %w[Yes No] }
    ])
    seed!(survey, 40) do |i|
      answers = { "0" => { "value" => "Yes" } }
      answers["1"] = { "value" => "No" } if i < 3
      answers
    end

    entry = index!(survey)

    assert_equal [ "c_answered" ], entry.corpus_questions.pluck(:cid)
    end
  end

  test "falling below the floor on re-index removes what was there" do
    with_floor do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, 40) { { "0" => { "value" => "Yes" } } }
    entry = index!(survey)
    assert_equal 1, entry.corpus_questions.count

    survey.responses.limit(20).destroy_all
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    assert_empty entry.reload.corpus_questions
    end
  end

  # ── Answers count whether or not the Verto was finished ──────────────────
  test "a respondent who stopped part-way still counts on the questions they answered" do
    # The corpus used to see status: "completed" only, which on the WLL digital
    # export was 22,572 of 50,835 sessions against 44,585 carrying real answers.
    # Half the answers people gave were imported and then invisible.
    survey = survey_with([
      { "type" => "yes_no", "cid" => "c_early", "text" => "Asked first", "options" => %w[Yes No] },
      { "type" => "yes_no", "cid" => "c_late",  "text" => "Asked last",  "options" => %w[Yes No] }
    ])
    # 10 finished; 30 answered the first question and left.
    seed!(survey, 10) { { "0" => { "value" => "Yes" }, "1" => { "value" => "Yes" } } }
    survey.responses.update_all(status: "completed")
    seed!(survey, 30) { { "0" => { "value" => "No" } } }
    survey.responses.where.not(id: survey.responses.limit(10).ids).update_all(status: "started")

    entry = index!(survey)

    early = entry.corpus_questions.find_by(cid: "c_early")
    late  = entry.corpus_questions.find_by(cid: "c_late")

    assert_equal 40, early.response_count, "everyone who answered it answered it"
    assert_equal({ "Yes" => 10, "No" => 30 }, early.distribution)
    assert_equal 10, late.response_count, "and the later question counts only the people who reached it"
    assert_equal 40, entry.response_count
  end

  test "a session with no answers at all is in no question's denominator" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, 30) { { "0" => { "value" => "Yes" } } }
    seed!(survey, 12) { {} }

    entry = index!(survey)

    assert_equal 30, entry.corpus_questions.first.response_count,
      "someone who opened the Verto and left answered nothing, and counting them would deflate every share"
  end

  test "by default the floor is the Privacy Notice's minimum group" do
    # The Privacy Notice promises respondents that no result — "a report, the
    # Data Commons or an Ask Verto answer" — is produced from a group of fewer
    # than 10, and the owner chose (2026-10-02) to make the product keep that
    # promise. It replaces a default of 1, under which every answer counted: a
    # one-respondent Verto was citable, and so was a segment of one child.
    assert_equal 10, CorpusEntry.min_sample_size
    assert_equal Response::MIN_REGION_SAMPLE_SIZE, CorpusEntry.min_sample_size,
      "one minimum group across the product — Ask Verto must not publish what the results page withholds"

    floor  = CorpusEntry.min_sample_size
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    # Women exactly on the line, men one under it.
    seed!(survey, floor) { { "0" => { "value" => "Money" } } }
    survey.responses.update_all(demographic_gender: "Female")
    seed!(survey, floor - 1) { { "0" => { "value" => "Time" } } }
    survey.responses.where(demographic_gender: nil).update_all(demographic_gender: "Male")

    question = index!(survey).corpus_questions.find_by(cid: "c_m")

    assert_equal({ "Money" => floor, "Time" => floor - 1 }, question.distribution)
    assert_equal floor, question.segments.dig("Gender: Female", "n"), "a group of exactly the floor is citable"
    assert_not question.segments.key?("Gender: Male"),
      "a group one under the floor is the kind the notice says no result comes from"
  end

  test "by default a Verto with fewer answers than the minimum group is not cited at all" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, CorpusEntry.min_sample_size - 1) { { "0" => { "value" => "Yes" } } }

    entry = index!(survey)

    assert_empty entry.corpus_questions
    assert_equal CorpusEntry.min_sample_size - 1, entry.response_count
  end

  test "a deployment can still lower the floor, all the way to every answer counting" do
    # ASK_VERTO_MIN_CELL (or with_min_sample_size) overrides the default. Below
    # 10 it breaks the Privacy Notice's promise, but it is the deployment's
    # setting to make — and at 1 nothing is suppressed: one respondent is a
    # citable cell, and a segment of one is a citable segment.
    with_floor(1) do
      survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                               "options" => [ "Money", "Time" ] } ])
      seed!(survey, 1) { { "0" => { "value" => "Money" } } }
      survey.responses.update_all(demographic_gender: "Female")

      question = index!(survey).corpus_questions.find_by(cid: "c_m")

      assert_equal 1, CorpusEntry.min_sample_size
      assert_not_nil question, "a one-respondent Verto is citable under a floor of 1"
      assert_equal({ "Money" => 1 }, question.distribution)
      assert_equal 1, question.segments.dig("Gender: Female", "n")
    end
    assert_equal 10, CorpusEntry.min_sample_size, "the override ends with its block"
  end

  # ── Breakdowns beyond the choice types ────────────────────────────────────
  test "a scale question gets a breakdown, in the scale's own words" do
    # range, nps, rating and tap_card used to get no breakdown at all, which on
    # the WLL deck meant every scale question — the data was right there and
    # "how did girls answer this scale?" had no answer anywhere in the corpus.
    survey = survey_with([ { "type" => "range", "cid" => "c_r", "text" => "How worried?",
                             "options" => [ "Not at all", "Not very", "Neutral", "Somewhat", "Very" ] } ])
    seed!(survey, 40) { |i| { "0" => { "value" => i < 25 ? 4 : 1 } } }
    # order(:id): an unordered LIMIT returns insertion order on SQLite but
    # arbitrary rows on Postgres, and these 25 must be the 25 who answered 4
    # (this exact line failed CI's test_postgres while passing locally).
    survey.responses.order(:id).limit(25).update_all(demographic_gender: "Female")
    survey.responses.where(demographic_gender: nil).update_all(demographic_gender: "Male")

    segments = index!(survey).corpus_questions.find_by(cid: "c_r").segments

    assert_equal 25, segments.dig("Gender: Female", "n")
    assert_equal({ "Very" => 25 }, segments.dig("Gender: Female", "distribution"),
      "a breakdown must read 'Very', not 'step 4' — the same number under two names is two numbers")
    assert_equal({ "Not very" => 15 }, segments.dig("Gender: Male", "distribution"))
  end

  test "a card sort keeps its per-option tallies in a breakdown" do
    survey = survey_with([ { "type" => "tap_card", "cid" => "c_t", "text" => "Which of these?",
                             "options" => [ "Cost", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => { "Cost" => "yes", "Time" => "no" } } } }
    survey.responses.update_all(demographic_gender: "Female")

    cell = index!(survey).corpus_questions.find_by(cid: "c_t").segments.dig("Gender: Female", "distribution")

    # Keyed by the WORDS, not the stored keys — the same rule the range case
    # above states: a breakdown reading "yes: 40" beside a whole-Verto figure
    # reading "Yes: 40" is the same number wearing two names. It matters more
    # now a creator can rename a response, at which point the key stops being
    # a word anyone chose.
    assert_equal 40, cell.dig("Cost", "Yes")
    assert_equal 40, cell.dig("Time", "No")
  end

  test "prioritise still gets no breakdown, because a segmented rank sum is worse than none" do
    survey = survey_with([ { "type" => "prioritise", "cid" => "c_p", "text" => "Rank these",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => [ "Money", "Time" ] } } }
    survey.responses.update_all(demographic_gender: "Female")

    assert_empty index!(survey).corpus_questions.find_by(cid: "c_p").segments
  end

  # ── Citation stability ────────────────────────────────────────────────────
  # A themer that returns fixed quotes, so a re-index is comparable.
  class FixedThemer
    def initialize(bodies) = @bodies = bodies
    def call(**) = { themes: [ { "label" => "Cost", "count" => 30 } ],
                     quotes: @bodies.map { |b| { body: b, theme: "Cost" } } }
  end

  test "re-indexing keeps a quote's id, because the id IS the citation" do
    # corpus_questions are carefully matched on `cid` so a citation survives a
    # re-index. Quotes were destroyed and recreated, so every "[[q:1234]]" marker
    # already sitting in someone's thread silently re-pointed at different words.
    survey = survey_with([ { "type" => "open_ended", "cid" => "c_o", "text" => "Say more" } ])
    seed!(survey, 40) { |i| { "0" => { "value" => "Something worth quoting number #{i}" } } }
    entry = CorpusEntry.create!(survey: survey, organisation: @org,
                                opted_in_at: Time.current, review_status: "approved")

    bodies = [ "Something worth quoting number 1", "Something worth quoting number 2" ]
    CorpusIndexer.new(entry, themer: FixedThemer.new(bodies)).call
    before = entry.reload.corpus_questions.first.corpus_quotes.order(:id).pluck(:id, :body)
    assert_equal 2, before.size

    CorpusIndexer.new(entry, themer: FixedThemer.new(bodies)).call
    after = entry.reload.corpus_questions.first.corpus_quotes.order(:id).pluck(:id, :body)

    assert_equal before, after,
      "same words must keep the same id — a re-created quote re-points every citation to it"
  end

  test "a quote the model stops picking goes, rather than being re-pointed" do
    survey = survey_with([ { "type" => "open_ended", "cid" => "c_o", "text" => "Say more" } ])
    seed!(survey, 40) { |i| { "0" => { "value" => "Something worth quoting number #{i}" } } }
    entry = CorpusEntry.create!(survey: survey, organisation: @org,
                                opted_in_at: Time.current, review_status: "approved")

    kept = "Something worth quoting number 1"
    CorpusIndexer.new(entry, themer: FixedThemer.new([ kept, "Something worth quoting number 2" ])).call
    kept_id = entry.reload.corpus_questions.first.corpus_quotes.find_by(body: kept).id

    CorpusIndexer.new(entry, themer: FixedThemer.new([ kept ])).call
    quotes = entry.reload.corpus_questions.first.corpus_quotes

    assert_equal [ kept_id ], quotes.pluck(:id),
      "the dropped one becomes a stale source, which the reader is told about — " \
      "silently handing its id to different words is what must not happen"
  end

  test "re-indexing keeps a question's id, because the id IS the citation" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, 40) { { "0" => { "value" => "Yes" } } }
    entry = index!(survey)
    original_id = entry.corpus_questions.first.id

    seed!(survey, 5) { { "0" => { "value" => "No" } } }
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    question = entry.reload.corpus_questions.first
    assert_equal original_id, question.id,
      "a delete-and-recreate would silently re-point every citation already stored on an answered message"
    assert_equal 45, question.response_count
  end

  test "a question deleted from the deck leaves the corpus" do
    survey = survey_with([
      { "type" => "yes_no", "cid" => "c_a", "text" => "Keep", "options" => %w[Yes No] },
      { "type" => "yes_no", "cid" => "c_b", "text" => "Drop", "options" => %w[Yes No] }
    ])
    seed!(survey, 40) { { "0" => { "value" => "Yes" }, "1" => { "value" => "No" } } }
    entry = index!(survey)
    assert_equal 2, entry.corpus_questions.count

    survey.update!(cards: [ Array(survey.cards).first ])
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    assert_equal [ "c_a" ], entry.reload.corpus_questions.pluck(:cid)
  end

  # ── Readability of what is stored ─────────────────────────────────────────
  # Range cards are always a 5-point scale (Survey::RANGE_POINTS) — a 4-option
  # card has a centre inserted on save, which shifts every label after it. The
  # indexer therefore reads the STORED options, and this test uses five so the
  # labels it asserts are the ones a respondent actually saw.
  test "range steps are stored as their labels, not as indexes" do
    survey = survey_with([ { "type" => "range", "cid" => "c_r", "text" => "How worried?",
                             "options" => [ "Not at all", "Not very", "Neutral", "Somewhat", "Very" ] } ])
    seed!(survey, 40) { |i| { "0" => { "value" => i < 30 ? 3 : 4 } } }

    entry = index!(survey)
    dist = entry.corpus_questions.find_by(cid: "c_r").distribution

    assert_equal 30, dist["Somewhat"]
    assert_equal 10, dist["Very"]
    assert_not dist.key?("3"), "a citation must read 'Somewhat', never 'step 3'"
  end

  test "rating keeps its average alongside the counts" do
    survey = survey_with([ { "type" => "rating", "cid" => "c_rt", "text" => "Rate it" } ])
    seed!(survey, 40) { |i| { "0" => { "value" => i.even? ? 4 : 2 } } }

    dist = index!(survey).corpus_questions.find_by(cid: "c_rt").distribution

    assert_in_delta 3.0, dist["avg"], 0.01
    assert_equal 20, dist["4"]
  end

  test "ranked_options turns a distribution into ordered shares" do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { |i| { "0" => { "value" => i < 30 ? "Money" : "Time" } } }

    ranked = index!(survey).corpus_questions.find_by(cid: "c_m").ranked_options

    assert_equal "Money", ranked.first[:label]
    assert_in_delta 75.0, ranked.first[:percent], 0.01
    assert_in_delta 25.0, ranked.last[:percent], 0.01
  end

  # ── Segments ──────────────────────────────────────────────────────────────
  # A programme run twice — digitally and on paper — is one study whose halves
  # are worth comparing. Merging them into one Verto is what lets Ask Verto cite
  # the combined sample; this dimension is what stops that merge losing the
  # comparison.
  test "collection mode becomes a breakdown when a Verto was run more than one way" do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => "Money" } } }
    survey.responses.limit(40).update_all(collection_mode: "digital")
    seed!(survey, 35) { { "0" => { "value" => "Time" } } }
    survey.responses.where(collection_mode: nil).update_all(collection_mode: "paper")

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert segments.key?("Collected: digital")
    assert segments.key?("Collected: paper")
    assert_equal 40, segments["Collected: digital"]["n"]
    assert_equal 35, segments["Collected: paper"]["n"]
    assert_equal 40, segments["Collected: digital"]["distribution"]["Money"]
  end

  test "an ordinary Verto gets no collection-mode breakdown at all" do
    # Every response came through the player, so the column is NULL and the
    # dimension must simply not appear — not appear as one meaningless cell.
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => "Money" } } }

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert(segments.keys.none? { |k| k.start_with?("Collected:") })
  end

  test "a collection mode under the floor is suppressed like any other cell" do
    with_floor do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => "Money" } } }
    survey.responses.limit(40).update_all(collection_mode: "digital")
    seed!(survey, 5) { { "0" => { "value" => "Time" } } }
    survey.responses.where(collection_mode: nil).update_all(collection_mode: "paper")

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert segments.key?("Collected: digital")
    assert_not segments.key?("Collected: paper"),
      "a mode with 5 respondents describes individuals, not a cohort"
    end
  end

  test "a segment cell under the floor is absent, not zero" do
    with_floor do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    # 40 women (clears 30), 5 men (does not).
    seed!(survey, 40) { { "0" => { "value" => "Money" }, "_g" => nil } }
    survey.responses.limit(40).update_all(demographic_gender: "Female")
    seed!(survey, 5) { { "0" => { "value" => "Time" } } }
    survey.responses.where(demographic_gender: nil).update_all(demographic_gender: "Male")

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert segments.key?("Gender: Female")
    assert_not segments.key?("Gender: Male"),
      "a published zero is as identifying as a published one — the cell must be absent"
    end
  end

  # ── Offered scope: the boundary is enforced at indexing ───────────────────
  def scoped_cards
    [
      { "type" => "multiple_choice", "cid" => "c_own", "text" => "Own question?",
        "options" => [ "Yes", "No" ] },
      { "type" => "multiple_choice", "cid" => "c_common", "text" => "Common question?",
        "options" => [ "Yes", "No" ], "common_question_set_id" => 77 }
    ]
  end

  test "a question outside the offered scope never becomes a corpus row" do
    survey = survey_with(scoped_cards)
    seed!(survey, 40) { { "0" => { "value" => "Yes" }, "1" => { "value" => "No" } } }

    entry = CorpusEntry.create!(survey: survey, organisation: @org,
                                opted_in_at: Time.current, review_status: "approved",
                                offered_scope: { "own_questions" => false,
                                                 "common_question_set_ids" => [ 77 ] })
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    assert_equal [ "c_common" ], entry.corpus_questions.pluck(:cid),
      "the picker is presentation — this filter is the boundary"
  end

  test "a narrowed re-offer sweeps previously indexed questions out" do
    survey = survey_with(scoped_cards)
    seed!(survey, 40) { { "0" => { "value" => "Yes" }, "1" => { "value" => "No" } } }
    entry = index!(survey)
    assert_equal %w[c_own c_common].sort, entry.corpus_questions.pluck(:cid).sort

    entry.update!(offered_scope: { "own_questions" => true, "common_question_set_ids" => [] })
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    assert_equal [ "c_own" ], entry.corpus_questions.pluck(:cid),
      "a question the creator stopped offering must leave the corpus at re-index"
  end

  test "preview_rows shows only offered questions, with shares" do
    survey = survey_with(scoped_cards)
    seed!(survey, 40) { |i| { "0" => { "value" => i < 30 ? "Yes" : "No" }, "1" => { "value" => "No" } } }
    entry = CorpusEntry.create!(survey: survey, organisation: @org,
                                opted_in_at: Time.current,
                                offered_scope: { "own_questions" => true,
                                                 "common_question_set_ids" => [] })

    rows = CorpusIndexer.new(entry, themer: NullThemer.new).preview_rows

    assert_equal [ "Own question?" ], rows.map { |r| r[:text] }
    top = rows.first[:bars].first
    assert_equal "Yes", top[:label]
    assert_equal 30, top[:count]
    assert_in_delta 75.0, top[:percent], 0.01
    assert_equal 40, rows.first[:total]
  end
end
