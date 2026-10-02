require "test_helper"

# The Verto Integrity Score, component by component. Built on in-memory
# responses and a plain survey double wherever the database adds nothing, so
# each rule can be read off the test that pins it.
class ResponseIntegrityTest < ActiveSupport::TestCase
  Deck = Struct.new(:cards, :audience_age, :integrity_baseline, keyword_init: true)

  CHOICE = %w[Never Rarely Sometimes Often Always].freeze

  def deck(cards, audience: "adults", baseline: {})
    Deck.new(cards: cards, audience_age: audience, integrity_baseline: baseline)
  end

  def response(answers:, dwell: {}, signals: { "v" => 1 }, device_kind: "phone", created_at: Time.utc(2026, 11, 1))
    Response.new(answers: answers, dwell_ms: dwell, integrity: signals, device_kind: device_kind, created_at: created_at)
  end

  def score(resp, deck_)
    ResponseIntegrity.score(resp, survey: deck_, held_texts: {})
  end

  # ── bands with nothing to score ────────────────────────────────────────────

  test "a response without a signal stamp is unscored before the player sent signals, unverified after" do
    cards = [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ]
    old   = response(answers: { "0" => { "value" => "Yes" } }, signals: {}, created_at: ResponseIntegrity::SIGNALS_SINCE - 1.day)
    late  = response(answers: { "0" => { "value" => "Yes" } }, signals: {}, created_at: ResponseIntegrity::SIGNALS_SINCE + 1.day)
    imported = response(answers: { "0" => { "value" => "Yes" } }, signals: {}, device_kind: nil,
                        created_at: ResponseIntegrity::SIGNALS_SINCE + 1.day)

    assert_equal "unscored",   score(old, deck(cards)).band
    assert_equal "unverified", score(late, deck(cards)).band, "sending nothing must not step around the score"
    assert_equal "unscored",   score(imported, deck(cards)).band, "imports never pass through the player"
    assert_nil score(late, deck(cards)).score
  end

  test "a stamped response with nothing scoreable is unscored, not low" do
    cards = [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ]
    result = score(response(answers: { "0" => { "value" => "Yes" } }), deck(cards))
    assert_equal "unscored", result.band
  end

  # ── speed ──────────────────────────────────────────────────────────────────

  test "an answer faster than the card could be read counts against speed; a considered one does not" do
    long = "How often do you feel you have enough time in the day to do the things that matter to you?"
    cards = [ { "type" => "multiple_choice", "text" => long, "options" => CHOICE } ] * 2
    resp  = response(answers: { "0" => { "value" => "Often" }, "1" => { "value" => "Never" } },
                     dwell: { "0" => 600, "1" => 9_000 })

    result = score(resp, deck(cards))
    assert_in_delta 0.5, result.components[:speed], 0.001
    assert_match "1 of 2 timed answers", result.reasons.join
  end

  test "a young audience reads more slowly, so the same time can be fast for adults and fine for children" do
    text  = "Which of these things would you most like to do at the weekend with your friends?"
    cards = [ { "type" => "multiple_choice", "text" => text, "options" => %w[Football Reading Gaming Cooking] } ]
    adult = ResponseIntegrity.reading_floor_ms(cards.first, nil, false)
    young = ResponseIntegrity.reading_floor_ms(cards.first, nil, true)
    assert_operator young, :>, adult

    assert ResponseIntegrity.young_audience?("11-16")
    assert ResponseIntegrity.young_audience?("youth")
    assert ResponseIntegrity.young_audience?("under 16s")
    assert_not ResponseIntegrity.young_audience?("adults")
    assert_not ResponseIntegrity.young_audience?("18-24")
    assert_not ResponseIntegrity.young_audience?("under 25")
    assert_not ResponseIntegrity.young_audience?("all")
  end

  test "once a question has enough timed answers, under a quarter of its median is fast too" do
    cards = [ { "type" => "yes_no", "text" => "Ok?", "options" => %w[Yes No] } ]
    resp  = response(answers: { "0" => { "value" => "Yes" } }, dwell: { "0" => 2_000 })
    thin  = { "cards" => { "0" => { "n" => ResponseIntegrity::COHORT_MIN_ANSWERS - 1, "median_ms" => 20_000 } } }
    full  = { "cards" => { "0" => { "n" => ResponseIntegrity::COHORT_MIN_ANSWERS, "median_ms" => 20_000 } } }

    assert_equal 1.0, score(resp, deck(cards, baseline: thin)).components[:speed], "too few answers to trust a median"
    assert_equal 0.0, score(resp, deck(cards, baseline: full)).components[:speed]
  end

  # ── total time ─────────────────────────────────────────────────────────────

  test "a finished run a fraction of everyone else's is caught by total time, though every card cleared its floor" do
    cards = Array.new(4) { |i| { "type" => "yes_no", "text" => "Q#{i}?", "options" => %w[Yes No] } }
    answers = (0..3).to_h { |i| [ i.to_s, { "value" => i.even? ? "Yes" : "No" } ] }
    run   = response(answers: answers, dwell: (0..3).to_h { |i| [ i.to_s, 2_000 ] })
    crowd = { "total" => { "n" => ResponseIntegrity::COHORT_MIN_ANSWERS, "median_ms" => 60_000 } }

    alone = score(run, deck(cards))
    assert_equal 1.0, alone.components[:total], "8s clears the time it takes to read four short questions"
    assert_equal 1.0, alone.components[:speed]

    judged = score(run, deck(cards, baseline: crowd))
    assert_equal 0.0, judged.components[:total], "8s is under a quarter of the usual minute"
    assert_equal 1.0, judged.components[:speed], "no single card was too fast"
    assert_match "total time: the whole Verto in 8s, under the 15s bar", judged.reasons.join
  end

  test "total time judges only finished runs, and only once enough of them are timed to trust a median" do
    cards = [ { "type" => "yes_no", "text" => "Ok?", "options" => %w[Yes No] } ]
    thin  = { "total" => { "n" => ResponseIntegrity::COHORT_MIN_ANSWERS - 1, "median_ms" => 60_000 } }
    run   = response(answers: { "0" => { "value" => "Yes" } }, dwell: { "0" => 2_000 })

    assert_equal 1.0, score(run, deck(cards, baseline: thin)).components[:total]
    run.status = "started"
    assert_nil score(run, deck(cards)).components[:total], "a partial run has no whole to judge"
  end

  # ── straight-lining ────────────────────────────────────────────────────────

  test "the same answer down a run of questions sharing one option list is straight-lining" do
    cards = Array.new(4) { |i| { "type" => "multiple_choice", "text" => "Statement #{i}", "options" => CHOICE } }
    same  = response(answers: (0..3).to_h { |i| [ i.to_s, { "value" => "Often" } ] })
    mixed = response(answers: { "0" => { "value" => "Often" }, "1" => { "value" => "Never" },
                                "2" => { "value" => "Often" }, "3" => { "value" => "Often" } })

    assert_equal 0.0, score(same, deck(cards)).components[:straightlining]
    assert_equal 1.0, score(mixed, deck(cards)).components[:straightlining]
  end

  test "a short run is not judged, and a different option list breaks the run" do
    cards = Array.new(3) { |i| { "type" => "multiple_choice", "text" => "S#{i}", "options" => CHOICE } } +
            [ { "type" => "multiple_choice", "text" => "Other list", "options" => %w[A B C] } ]
    resp  = response(answers: (0..2).to_h { |i| [ i.to_s, { "value" => "Often" } ] }.merge("3" => { "value" => "A" }))
    assert_nil score(resp, deck(cards)).components[:straightlining]
  end

  test "a tap card's statements are a block of their own" do
    card = { "type" => "tap_card", "text" => "Agree?", "options" => [ "A", "B", "C", "D" ] }
    keys = TapScales.keys_for(card)
    same = response(answers: { "0" => { "value" => %w[A B C D].index_with { keys.first } } })
    assert_equal 0.0, score(same, deck([ card ])).components[:straightlining]
  end

  test "untouched sliders are left out of straight-lining, which their own component covers" do
    cards = Array.new(4) { |i| { "type" => "range", "text" => "Scale #{i}", "options" => CHOICE } }
    resp  = response(answers: (0..3).to_h { |i| [ i.to_s, { "value" => 2 } ] },
                     signals: { "v" => 1, "untouched" => %w[0 1 2 3] })
    result = score(resp, deck(cards))
    assert_nil result.components[:straightlining]
    assert_equal 0.0, result.components[:untouched]
  end

  # ── untouched, reach, effort, changes ──────────────────────────────────────

  test "untouched is the share of answered sliders left where they opened" do
    cards = Array.new(4) { |i| { "type" => "range", "text" => "Scale #{i}", "options" => CHOICE } }
    resp  = response(answers: (0..3).to_h { |i| [ i.to_s, { "value" => i } ] }, signals: { "v" => 1, "untouched" => [ "1" ] })
    assert_in_delta 0.75, score(resp, deck(cards)).components[:untouched], 0.001
  end

  test "reach is the share of scrolling lists read to the end; lists that fit are not judged" do
    cards = [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ]
    resp  = response(answers: { "0" => { "value" => "Yes" } }, signals: { "v" => 1, "seen" => { "0" => 1, "1" => 0 } })
    assert_in_delta 0.5, score(resp, deck(cards)).components[:reach], 0.001
    assert_nil score(response(answers: { "0" => { "value" => "Yes" } }), deck(cards)).components[:reach]
  end

  test "low-effort free text is a character, a repeat or a key-mash — not merely short" do
    %w[x aaaa ababab asdf qwerty ?? 🙂🙂].each { |t| assert ResponseIntegrity.low_effort_text?(t), t.inspect }
    [ "No", "Nooo", "Bus", "犬が好き", "لا أعرف", "Fewer delays please", "42", "ok",
      "poverty", "property", "liberty" ].each do |t|
      assert_not ResponseIntegrity.low_effort_text?(t), t.inspect
    end
  end

  test "effort counts free text and Other write-ins, held ones included, and skips structured inputs" do
    cards = [ { "type" => "open_ended", "text" => "Why?" },
              { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B], "allow_other" => true },
              { "type" => "open_ended", "text" => "Born?", "input" => "month", "demographic" => true } ]
    resp  = response(answers: { "0" => { "value" => "asdf" }, "1" => { "value" => nil, "other" => "A real reason" },
                                "2" => { "value" => "1990-01" } })
    result = ResponseIntegrity.score(resp, survey: deck(cards), held_texts: { "0/value" => "Because the bus is late" })
    assert_in_delta 2.0 / 3, result.components[:effort], 0.001
  end

  test "answer changes add a capped bonus and never take anything away" do
    cards = [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ]
    resp  = response(answers: { "0" => { "value" => "Yes" } }, dwell: { "0" => 50 },
                     signals: { "v" => 1, "changes" => { "0" => 40 } })
    result = score(resp, deck(cards))
    assert_equal ResponseIntegrity::MAX_CHANGE_BONUS, result.bonus
    assert_equal ResponseIntegrity::MAX_CHANGE_BONUS, result.score, "speed 0 plus the bonus"
  end

  # ── the score ──────────────────────────────────────────────────────────────

  test "weights are renormalised over the components a response has, and the band follows the score" do
    cards = Array.new(4) { |i| { "type" => "range", "text" => "Scale #{i}", "options" => CHOICE } }
    calm  = response(answers: (0..3).to_h { |i| [ i.to_s, { "value" => i % 5 } ] },
                     dwell: (0..3).to_h { |i| [ i.to_s, 8_000 ] })
    result = score(calm, deck(cards))
    assert_equal 100, result.score
    assert_equal "high", result.band
    assert_equal %i[speed straightlining total untouched].sort, result.components.keys.sort

    rushed = response(answers: (0..3).to_h { |i| [ i.to_s, { "value" => 2 } ] },
                      dwell: (0..3).to_h { |i| [ i.to_s, 100 ] }, signals: { "v" => 1, "untouched" => %w[0 1 2 3] })
    assert_equal "low", score(rushed, deck(cards)).band
  end

  test "apply! writes the score, band and version, and survives a fault without failing the save" do
    org    = Organisation.create!(name: "O", slug: "ri-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(title: "T", theme: "T", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ],
                                 cards: Array.new(4) { |i| { "type" => "range", "text" => "Scale #{i}", "options" => CHOICE } })
    resp = survey.responses.create!(session_token: SecureRandom.uuid, device_kind: "phone",
                                    answers: (0..3).to_h { |i| [ i.to_s, { "value" => i % 5 } ] },
                                    dwell_ms: (0..3).to_h { |i| [ i.to_s, 8_000 ] }, integrity: { "v" => 1 })

    ResponseIntegrity.apply!(resp, survey: survey)
    resp.reload
    assert_equal [ 100, "high", ResponseIntegrity::VERSION ], [ resp.integrity_score, resp.integrity_band, resp.integrity_version ]

    stub_method(ResponseIntegrity, :score, ->(*, **) { raise "boom" }) do
      assert_nil ResponseIntegrity.apply!(resp, survey: survey)
    end
  ensure
    survey&.destroy
    org&.destroy
  end
end
