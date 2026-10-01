require "test_helper"

class ResponseTest < ActiveSupport::TestCase
  def setup
    @org    = Organisation.create!(name: "O", slug: "resp-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "yes_no", "text" => "Like it?", "options" => %w[Yes No] } ])
  end

  def build(answers, status: "started")
    @survey.responses.create!(session_token: SecureRandom.uuid, status: status, answers: answers)
  end

  # ── Dwell time ─────────────────────────────────────────────────────────────

  # A deck with a welcome card, three questions and a checkpoint — only the
  # questions may hold time.
  DWELL_CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "yes_no", "text" => "Q1", "options" => %w[Yes No] },
    { "type" => "open_ended", "text" => "Q2" },
    { "type" => "rating", "text" => "Q3" },
    { "type" => "token_checkpoint", "title" => "Half way" }
  ].freeze

  test "merge_dwell keeps the larger figure per card and ignores what it cannot trust" do
    stored   = { "1" => 5000 }
    incoming = {
      "1" => 3000,          # an older, smaller total — stays 5000
      "2" => "1200.6",      # a numeric string is a number; rounded
      "0" => 800,           # the welcome card: timed by the player, held by nobody
      "4" => 800,           # the checkpoint, likewise
      "9" => 10,            # no such card
      "x" => 10,            # not a card index
      "-1" => 10,
      "1.5" => 10,
      "02" => 10,           # card 2 spelled a way nothing reads back
      "007" => 10,
      "3" => -5,            # negative time is not a measurement
      "3" => nil
    }

    assert_equal({ "1" => 5000, "2" => 1201 }, Response.merge_dwell(stored, incoming, cards: DWELL_CARDS))
  end

  test "merge_dwell grows a figure and never shrinks it" do
    assert_equal({ "1" => 9000 }, Response.merge_dwell({ "1" => 5000 }, { "1" => 9000 }, cards: DWELL_CARDS))
    assert_equal({ "1" => 5000 }, Response.merge_dwell({ "1" => 5000 }, {}, cards: DWELL_CARDS))
    assert_equal({ "1" => 5000 }, Response.merge_dwell({ "1" => 5000 }, "junk", cards: DWELL_CARDS))
    assert_equal({}, Response.merge_dwell(nil, nil, cards: DWELL_CARDS))
    assert_equal({}, Response.merge_dwell(nil, { "1" => 5000 }, cards: nil))
  end

  test "merge_dwell caps a day on one card and refuses what cannot be rounded" do
    merged = Response.merge_dwell({}, { "1" => 1e15, "2" => Float::NAN, "3" => Float::INFINITY }, cards: DWELL_CARDS)
    assert_equal({ "1" => Response::DWELL_CAP_MS }, merged)
  end

  test "merge_dwell leaves the stored hash alone" do
    stored = { "1" => 5000 }.freeze
    Response.merge_dwell(stored, { "1" => 9000 }, cards: DWELL_CARDS)
    assert_equal({ "1" => 5000 }, stored)
  end

  test "dwell_seconds_at reads whole milliseconds as seconds to one decimal, nil when unrecorded" do
    r = Response.new(dwell_ms: { "1" => 12_449, "0" => 0 })
    assert_equal 12.4, r.dwell_seconds_at(1)
    assert_equal 12.4, r.dwell_seconds_at("1")
    assert_nil r.dwell_seconds_at(0), "zero is nothing recorded, not an instant answer"
    assert_nil r.dwell_seconds_at(7)
    assert_nil Response.new(dwell_ms: nil).dwell_seconds_at(1)
  end

  test "dwell time is not an answer" do
    r = @survey.responses.create!(session_token: SecureRandom.uuid, answers: {}, dwell_ms: { "1" => 8000 })
    assert_not r.answered
  end

  test "declining consent purges the dwell times with the answers" do
    r = build({ "1" => { "value" => "Yes" } })
    r.update!(dwell_ms: { "1" => 8000 })
    r.purge_for_declined_consent!
    r.save!
    assert_equal({}, r.reload.dwell_ms)
  end

  test "answered flag is true when any card has a value" do
    r = build({ "1" => { "value" => "Yes" } })
    assert r.answered, "a real answer should mark the response answered"
  end

  test "answered flag is false with no value present" do
    assert_not build({}).answered
    assert_not build({ "1" => { "value" => "" } }).answered, "blank value is not an answer"
    assert_not build({ "1" => { "other" => "" } }).answered
  end

  test "answered flag is kept in sync on update" do
    r = build({})
    assert_not r.answered
    r.update!(answers: { "1" => { "value" => "No" } })
    assert r.answered
  end

  # ── Survey responder counts (driven by the flag, in SQL) ──

  test "responders_count counts only responses that answered" do
    build({ "1" => { "value" => "Yes" } }, status: "completed")
    build({ "1" => { "value" => "No" } },  status: "started")
    build({})                                # not a responder
    assert_equal 2, @survey.responders_count
  end

  test "completion_rate is the share of responders who completed" do
    build({ "1" => { "value" => "Yes" } }, status: "completed")
    build({ "1" => { "value" => "No" } },  status: "completed")
    build({ "1" => { "value" => "Yes" } }, status: "started")
    assert_equal 67, @survey.completion_rate # 2 of 3 responders completed
  end

  test "completion_rate is nil with no responders" do
    build({})
    assert_nil @survey.completion_rate
  end
end
