require "test_helper"

# The Data Commons' side of the Verto Integrity Score: once scores are live,
# Low and unverified responses never leave the account, and a Verto whose
# scored responses are under 70% High or Medium contributes nothing at all.
# Unscored responses — collected before scoring, or imported — are counted in
# the Commons and left out of the 70% rule. In shadow mode none of it applies.
class CorpusIntegrityGateTest < ActiveSupport::TestCase
  class NullThemer
    def call(**) = { themes: [], quotes: [] }
  end

  MIN   = CorpusEntry.min_sample_size
  CARDS = [ { "type" => "multiple_choice", "cid" => "c_col", "text" => "Colour?", "options" => %w[Blue Green] } ].freeze

  def setup
    @org    = Organisation.create!(name: "O", slug: "cig-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "S", theme: "Colours", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS)
    @previous = ENV["INTEGRITY_SCORES_VISIBLE"]
  end

  def teardown
    ENV["INTEGRITY_SCORES_VISIBLE"] = @previous
  end

  def live! = ENV["INTEGRITY_SCORES_VISIBLE"] = "1"

  def add(count, value, band:)
    count.times do
      @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                                answers: { "0" => { "value" => value } }, integrity_band: band)
    end
  end

  def index!
    entry = CorpusEntry.create!(survey: @survey, organisation: @org, opted_in_at: Time.current, review_status: "approved")
    CorpusIndexer.new(entry, themer: NullThemer.new).call
    entry.reload
  end

  def check(key)
    CorpusChecks.run(@survey, answered_count: CorpusIndexer.countable_responses(@survey).count).find { |c| c.key == key }
  end

  test "once live, Low and unverified answers are not counted, and unscored ones are" do
    add(MIN, "Blue", band: "high")
    add(MIN, "Blue", band: "unscored")
    add(2, "Green", band: "low")
    add(1, "Green", band: "unverified")
    live!

    question = index!.corpus_questions.find_by(cid: "c_col")
    assert_equal({ "Blue" => 2 * MIN }, question.distribution.reject { |_k, v| v.to_i.zero? })
    assert_equal 2 * MIN, question.response_count
  end

  test "in shadow mode everything that was answered still counts, and there is no integrity check" do
    add(MIN, "Blue", band: "high")
    add(3, "Green", band: "low")

    question = index!.corpus_questions.find_by(cid: "c_col")
    assert_equal MIN + 3, question.response_count
    assert_nil check(:integrity)
  end

  test "under 70% of scored responses High or Medium, a Verto is declined by the checks and indexes nothing" do
    # 6 High and 4 Low of 10 scored is 60%. The 30 unscored would carry it
    # over the line if they were counted as passing; they are not counted.
    add(6, "Blue", band: "high")
    add(4, "Green", band: "low")
    add(30, "Blue", band: "unscored")
    live!

    result = check(:integrity)
    assert result.fail?
    assert_match(/Only 60% of 10 scored responses are High or Medium; the Data Commons needs 70%/, result.label)

    entry = index!
    assert_empty entry.corpus_questions, "an approved Verto that slips under the rule stops contributing"
  end

  test "at 70% it passes, and a Verto with nothing scored is not failed for it" do
    add(7, "Blue", band: "medium")
    add(3, "Green", band: "unverified")
    add(MIN, "Blue", band: "unscored")
    live!

    assert_equal :pass, check(:integrity).status
    assert_match(/70% of 10 scored/, check(:integrity).label)
    assert_not_empty index!.corpus_questions

    @survey.responses.where.not(integrity_band: "unscored").delete_all
    assert_equal :pass, check(:integrity).status
    assert_match(/no scored responses/, check(:integrity).label)
  end

  test "enrolment declines a Verto the rule fails, with the reason attached" do
    add(MIN, "Blue", band: "low")
    add(MIN, "Blue", band: "unscored")
    add(2, "Green", band: "high")
    live!
    user = User.create!(name: "U", email_address: "cig-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")

    result = CorpusEnrolment.new(@survey, user: user, reviewer: user).call(index: false)
    assert_not result.approved
    assert result.blocked_by.any? { |reason| reason.include?("the Data Commons needs 70%") }
  end
end
