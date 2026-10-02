# The Verto Integrity Score: whether a response was given with care, scored 0–100
# and banded, so results and the Data Commons can be relied on. Mike's proposal
# ("Replacing Clarity: the Verto Integrity Score"), as revised with the owner on
# 2026-10-02. It scores the RESPONSE, never the person — the bands say
# "integrity", not "quality of the respondent".
#
# ── What it reads ────────────────────────────────────────────────────────────
# Nothing new is captured for it beyond a few compact signals the player sends
# with the answers (Response#integrity, see Response.merge_integrity), and
# everything it can work out from what a response already holds:
#
#   speed           time on each answered question (dwell_ms) against a
#                   reading floor for that card and audience — and, once a
#                   question has enough timed answers, against a quarter of its
#                   own median. The floor comes first because a Verto's own
#                   median cannot see a crowd that speeds, says nothing at n=1,
#                   and moves under every stored score as answers arrive.
#   straightlining  the same position across a block: a tap card's statements,
#                   or a run of adjacent questions sharing one scale or option
#                   list (which is also how imported matrices arrived).
#   untouched       range sliders answered without ever being touched: their
#                   opening position, recorded as a choice nobody made.
#   reach           on answer lists long enough to scroll, whether the
#                   respondent reached the end of the list.
#   effort          free text that is a character, a key-mash or a repeat.
#   total           a finished run's total time answering (the sum of its
#                   per-question times) against the time it takes to read
#                   everything answered, and once 30 finished runs are timed,
#                   a quarter of their median total.
#
# Answer changes add a small bonus and never penalise. Total time is Mike's
# "total completion time", judged against the WHOLE run rather than card by
# card — it catches a run that clears every card's floor by a hair yet takes a
# fraction of what everyone else took — and its weight comes out of speed's,
# so timing as a whole counts no more than it did before (owner's call,
# 2026-10-02, after it had first been left out as double counting). Media
# engagement is dropped: the only media are decorative autoplay headers, so it
# would measure the phone, not the person.
#
# Weights are renormalised over the components a response actually has — a
# Verto with no free text is not marked down for missing effort — and are
# starting points, to be tuned against shadow-mode data (see `bin/rails
# integrity:report`).
#
# ── Bands ────────────────────────────────────────────────────────────────────
#   high (75–100) · medium (50–74) · low (under 50)
#   unscored    collected before the player sent signals, or imported from a
#               partner's export: there is nothing to score. Kept in results
#               and the Commons, and left out of the Commons' 70% rule.
#   unverified  collected by the live player after it began sending signals,
#               yet arriving without them. The save endpoints are public JSON,
#               so "send nothing" must not be a way to step around the score;
#               treated as Low wherever a band decides anything.
module ResponseIntegrity
  module_function

  # 2: total time joined the score (2026-10-02).
  VERSION = 2

  BANDS        = %w[high medium low unscored unverified].freeze
  SCORED_BANDS = %w[high medium low unverified].freeze
  # The bands a gate lets through: engaged responses, and ones that predate
  # the measurement (unscored) and so cannot be judged by it.
  PASSING_BANDS = %w[high medium unscored].freeze

  HIGH_FROM   = 75
  MEDIUM_FROM = 50

  WEIGHTS = { speed: 25, total: 10, straightlining: 20, untouched: 15, reach: 15, effort: 15 }.freeze
  # Answer changes are a positive signal only: reconsidering is care.
  MAX_CHANGE_BONUS = 5

  # A response with no signal stamp is "unscored" if it was created before the
  # player began sending signals, "unverified" after. The gap covers player
  # pages already open at deploy time and submissions waiting in a device's
  # offline queue, both of which arrive without a stamp through no fault of
  # the respondent.
  SIGNALS_SINCE = Time.utc(2026, 10, 9)

  # The cohort median only joins the reading floor once a question has this
  # many timed answers: below it a median is a few people's habits.
  COHORT_MIN_ANSWERS = 30
  COHORT_FAST_SHARE  = 0.25

  # A block needs this many answered items before identical positions mean
  # anything: three people strongly agreeing with three statements is common.
  MIN_BLOCK = 4

  # Reading floor. Characters rather than words, so a language without spaces
  # is not read as one long word. The rate is a fast skim — about twice a
  # typical reading speed — so the floor flags answers given faster than the
  # card could have been read, not ordinary quick readers.
  ADULT_CHARS_PER_SEC = 40.0
  YOUNG_CHARS_PER_SEC = 25.0
  TYPE_MIN_MS = {
    "yes_no" => 500, "rating" => 500, "range" => 600, "nps" => 600,
    "multiple_choice" => 700, "select_one_grid" => 900, "select_many" => 900,
    "select_many_grid" => 900, "scenario" => 1000, "prioritise" => 1500,
    "open_ended" => 1500
  }.freeze
  DEFAULT_TYPE_MIN_MS = 700
  TAP_STATEMENT_MIN_MS = 400

  CHOICE_TYPES = %w[multiple_choice yes_no select_one_grid scenario].freeze

  Result = Struct.new(:score, :band, :components, :bonus, :reasons, keyword_init: true)

  # The Data Commons' rule (Mike's proposal, the owner's decision of
  # 2026-10-02): a Verto contributes only while at least this share of its
  # scored responses are High or Medium. Unscored responses are left out of
  # the count on both sides — a Verto collected before scoring began, or
  # imported, has nothing to judge, and is not failed for it.
  COMMONS_MIN_RELIABLE_SHARE = 0.7

  # Whether creators see scores, bands and the exclude-Low filter, and whether
  # the Commons gate applies them. Off until the shadow-mode tuning with Mike
  # is done: scores are computed and stored either way.
  def visible?
    ENV["INTEGRITY_SCORES_VISIBLE"] == "1"
  end

  # A Verto's answered responses by band, and of the scored ones, how many are
  # High or Medium — what the Commons' rule is applied to, and what the
  # review queue shows. One grouped count over an indexed column.
  def commons_standing(survey)
    counts   = survey.responses.where(answered: true).reorder(nil).group(:integrity_band).count
    scored   = SCORED_BANDS.sum { |band| counts[band].to_i }
    reliable = counts["high"].to_i + counts["medium"].to_i
    { scored: scored, reliable: reliable, share: scored.zero? ? nil : reliable.to_f / scored }
  end

  # Whether a Verto may contribute to the Data Commons on integrity grounds.
  # Always true in shadow mode, and for a Verto with nothing scored.
  def commons_eligible?(survey, standing = nil)
    return true unless visible?

    share = (standing || commons_standing(survey))[:share]
    share.nil? || share >= COMMONS_MIN_RELIABLE_SHARE
  end

  # Score one response and write the result. Never raises: integrity is
  # derived data and must not fail the save that stored the answers.
  def apply!(response, survey:)
    result = score(response, survey: survey)
    attrs  = { integrity_score: result.score, integrity_band: result.band, integrity_version: VERSION }
    response.update_columns(attrs) if attrs.any? { |k, v| response[k] != v }
    result
  rescue StandardError => e
    ErrorReporting.report("ResponseIntegrity.apply!", e, response_id: response&.id)
    nil
  end

  # held_texts: { "card_index/slot" => text } for free text the moderator is
  # holding. nil looks it up (one query, only when the answers carry a marker).
  def score(response, survey:, held_texts: nil, baseline: nil)
    signals = response.integrity.is_a?(Hash) ? response.integrity : {}
    return Result.new(score: nil, band: stampless_band(response), components: {}, bonus: 0, reasons: []) unless stamped?(signals)

    cards    = Array(survey.cards)
    answers  = response.answers.is_a?(Hash) ? response.answers : {}
    dwell    = response.dwell_ms.is_a?(Hash) ? response.dwell_ms : {}
    baseline ||= survey.respond_to?(:integrity_baseline) ? survey.integrity_baseline : nil
    young    = young_audience?(survey.audience_age)
    untouched = Array(signals["untouched"]).map(&:to_s).to_set
    reasons  = []

    components = {
      speed:          speed(cards, answers, dwell, untouched, baseline, young, reasons),
      total:          total_time(response, cards, answers, dwell, baseline, young, reasons),
      straightlining: straightlining(cards, answers, untouched, reasons),
      untouched:      untouched_share(cards, answers, untouched, reasons),
      reach:          reach(signals, reasons),
      effort:         effort(cards, answers, held_texts || held_texts_for(response), reasons)
    }.compact

    return Result.new(score: nil, band: "unscored", components: {}, bonus: 0, reasons: reasons) if components.empty?

    weight = components.sum { |k, _| WEIGHTS[k] }
    base   = components.sum { |k, v| WEIGHTS[k] * v } / weight * 100
    bonus  = change_bonus(signals)
    total  = (base + bonus).round.clamp(0, 100)
    Result.new(score: total, band: band_for(total), components: components, bonus: bonus, reasons: reasons)
  end

  def band_for(score)
    if score >= HIGH_FROM then "high"
    elsif score >= MEDIUM_FROM then "medium"
    else "low"
    end
  end

  def stamped?(signals)
    signals["v"].is_a?(Integer) && signals["v"].positive?
  end

  # No stamp: a player response after the measurement began is unverified;
  # anything older, and anything imported (imports never pass through the
  # player, so they carry no device kind), is unscored.
  def stampless_band(response)
    from_player = response.device_kind.present?
    created     = response.created_at || Time.current
    from_player && created >= SIGNALS_SINCE ? "unverified" : "unscored"
  end

  # ── speed ──────────────────────────────────────────────────────────────────

  def speed(cards, answers, dwell, untouched, baseline, young, reasons)
    timed = 0
    fast  = 0
    cohort = baseline.is_a?(Hash) && baseline["cards"].is_a?(Hash) ? baseline["cards"] : {}

    cards.each_with_index do |card, idx|
      key = idx.to_s
      next unless question_card?(card) && Response.answered_entry?(answers[key])
      next if untouched.include?(key) # scored by its own component
      ms = dwell[key]
      next unless ms.is_a?(Numeric) && ms.positive?

      timed += 1
      floor = reading_floor_ms(card, answers[key], young)
      cohort_stat = cohort[key]
      if cohort_stat.is_a?(Hash) && cohort_stat["n"].to_i >= COHORT_MIN_ANSWERS && cohort_stat["median_ms"].to_f.positive?
        floor = [ floor, cohort_stat["median_ms"].to_f * COHORT_FAST_SHARE ].max
      end
      fast += 1 if ms < floor
    end
    return nil if timed.zero?

    reasons << "speed: #{fast} of #{timed} timed answers faster than the card could be read" if fast.positive?
    1.0 - (fast.to_f / timed)
  end

  def reading_floor_ms(card, answer, young)
    rate = young ? YOUNG_CHARS_PER_SEC : ADULT_CHARS_PER_SEC
    type = card["type"].to_s
    if type == "tap_card"
      swiped = answer.is_a?(Hash) && answer["value"].is_a?(Hash) ? answer["value"].keys : []
      statements = swiped.presence || Array(card["options"])
      return statements.sum { |s| TAP_STATEMENT_MIN_MS + (1000.0 * text_length(s) / rate) } +
             (1000.0 * text_length(card["text"]) / rate)
    end

    chars = text_length(card["text"]) + text_length(card["description"])
    chars += Array(card["options"]).sum { |o| text_length(o) } if card.key?("options")
    chars += Array(card["pages"]).sum { |p| p.is_a?(Hash) ? text_length(p["text"]) : 0 } if type == "scenario"
    TYPE_MIN_MS.fetch(type, DEFAULT_TYPE_MIN_MS) + (1000.0 * chars / rate)
  end

  # The creator writes the audience in their own words ("11-16", "youth",
  # "under 16s", "adults"), so this reads it loosely: anything that names
  # young people, or an age range ending under 18, reads at the slower rate.
  def young_audience?(audience)
    text = audience.to_s.downcase
    return true if text.match?(/youth|child|kid|teen|pupil|school|primary|young/)
    return true if text.match?(/under\s*(1[0-8]|[1-9])s?\b/)

    upper = text.scan(/\b(\d{1,2})\s*[-–to]+\s*(\d{1,2})\b/).map { |_a, b| b.to_i }.max
    upper.present? && upper < 18
  end

  # ── total time ─────────────────────────────────────────────────────────────

  # Only a finished run has a whole to judge. The bar is the time it takes to
  # read every question card answered (the per-card floors, summed), raised
  # to a quarter of the Verto's median total once COHORT_MIN_ANSWERS finished
  # runs have been timed (survey.integrity_baseline["total"], nightly).
  def total_time(response, cards, answers, dwell, baseline, young, reasons)
    return nil unless response.status.to_s == "completed"

    total = dwell.values.sum { |v| v.is_a?(Numeric) && v.positive? ? v : 0 }
    return nil unless total.positive?

    bar = cards.each_with_index.sum do |card, idx|
      question_card?(card) && Response.answered_entry?(answers[idx.to_s]) ? reading_floor_ms(card, answers[idx.to_s], young) : 0
    end
    cohort = baseline.is_a?(Hash) ? baseline["total"] : nil
    if cohort.is_a?(Hash) && cohort["n"].to_i >= COHORT_MIN_ANSWERS && cohort["median_ms"].to_f.positive?
      bar = [ bar, cohort["median_ms"].to_f * COHORT_FAST_SHARE ].max
    end
    return nil unless bar.positive?
    return 1.0 if total >= bar

    reasons << "total time: the whole Verto in #{(total / 1000.0).round}s, under the #{(bar / 1000.0).round}s bar"
    0.0
  end

  # ── straight-lining ────────────────────────────────────────────────────────

  def straightlining(cards, answers, untouched, reasons)
    blocks = tap_blocks(cards, answers) + run_blocks(cards, answers, untouched)
    eligible = blocks.select { |positions| positions.size >= MIN_BLOCK }
    return nil if eligible.empty?

    straight = eligible.count { |positions| positions.uniq.size == 1 }
    reasons << "straight-lining: #{straight} of #{eligible.size} blocks given one answer throughout" if straight.positive?
    1.0 - (straight.to_f / eligible.size)
  end

  # Each tap card is a block of its own statements, positioned on its scale.
  def tap_blocks(cards, answers)
    cards.each_with_index.filter_map do |card, idx|
      next unless card.is_a?(Hash) && card["type"].to_s == "tap_card" && !QuizGrading.graded?(card)
      value = answers[idx.to_s].is_a?(Hash) ? answers[idx.to_s]["value"] : nil
      next unless value.is_a?(Hash)

      keys = TapScales.keys_for(card)
      value.values.filter_map { |k| keys.index(k.to_s) }
    end
  end

  # Runs of adjacent question cards that share one scale or one option list.
  # Untouched sliders are left out: their sameness is the untouched signal's,
  # not a choice to say the same thing.
  def run_blocks(cards, answers, untouched)
    blocks = []
    run_sig = nil
    run     = []
    flush = -> { blocks << run.compact if run_sig; run_sig = nil; run = [] }

    cards.each_with_index do |card, idx|
      sig = block_signature(card)
      if sig.nil?
        flush.call
        next
      end
      flush.call unless sig == run_sig
      run_sig = sig
      key = idx.to_s
      run << (untouched.include?(key) ? nil : position(card, answers[key]))
    end
    flush.call
    blocks.select { |b| b.any? }
  end

  def block_signature(card)
    return nil unless card.is_a?(Hash) && question_card?(card) && !QuizGrading.graded?(card)

    type = card["type"].to_s
    case type
    when *CHOICE_TYPES then [ type, Array(card["options"]).map(&:to_s) ]
    when "range"       then [ type, Array(card["options"]).size ]
    when "nps"         then [ type, Array(card["options"]).size ]
    when "rating"      then [ type ]
    end
  end

  def position(card, answer)
    return nil unless answer.is_a?(Hash)
    value = answer["value"]
    return nil if value.nil?

    case card["type"].to_s
    when *CHOICE_TYPES then Array(card["options"]).map(&:to_s).index(value.to_s)
    when "range", "nps", "rating" then (value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)) ? value.to_i : nil
    end
  end

  # ── untouched sliders ──────────────────────────────────────────────────────

  def untouched_share(cards, answers, untouched, reasons)
    answered_ranges = cards.each_with_index.count do |card, idx|
      card.is_a?(Hash) && card["type"].to_s == "range" && Response.answered_entry?(answers[idx.to_s])
    end
    return nil if answered_ranges.zero?

    still = untouched.count do |key|
      card = cards[key.to_i]
      card.is_a?(Hash) && card["type"].to_s == "range" && Response.answered_entry?(answers[key])
    end
    reasons << "untouched sliders: #{still} of #{answered_ranges} left where they opened" if still.positive?
    1.0 - (still.to_f / answered_ranges)
  end

  # ── list reach ─────────────────────────────────────────────────────────────

  def reach(signals, reasons)
    seen = signals["seen"]
    return nil unless seen.is_a?(Hash) && seen.any?

    reached = seen.values.count { |v| v == 1 }
    missed  = seen.size - reached
    reasons << "long lists: #{missed} of #{seen.size} never scrolled to the end" if missed.positive?
    reached.to_f / seen.size
  end

  # ── free-text effort ───────────────────────────────────────────────────────

  # Runs of adjacent keys that no word contains. Deliberately NOT every run:
  # "erty" is in poverty, property and liberty, "wert" and "rtyu" are close
  # behind, and a respondent naming the biggest problem in their town must not
  # be marked down for spelling it.
  KEYBOARD_RUNS = %w[qwer asdf sdfg dfgh fghj ghjk hjkl zxcv xcvb cvbn vbnm
                     tyui yuio uiop 1234 2345 3456 4567 5678 6789].freeze

  def effort(cards, answers, held_texts, reasons)
    texts = []
    Moderation::FreeTextSlots.each(cards, answers) { |_key, _slot, text, _card| texts << text }
    held_texts.each_value { |text| texts << text if text.is_a?(String) && text.strip != "" }
    return nil if texts.empty?

    low = texts.count { |t| low_effort_text?(t) }
    reasons << "free text: #{low} of #{texts.size} answers a character, a repeat or a key-mash" if low.positive?
    1.0 - (low.to_f / texts.size)
  end

  # Language-neutral on purpose: no vowel ratios or word lists, which break in
  # Arabic, Hebrew, Hindi, Japanese and Korean. Short is not low effort on its
  # own — "No", "Bus", "犬が好き" are answers — only nothing, one character,
  # one character repeated, two characters alternated at length ("ababab",
  # but not an emphatic "Nooo"), or a run of keys.
  def low_effort_text?(text)
    t = text.to_s.unicode_normalize(:nfkc).strip
    return true if t.grapheme_clusters.size < 2
    return true unless t.match?(/[\p{L}\p{N}]/)

    compact = t.downcase.gsub(/\s+/, "")
    chars   = compact.grapheme_clusters
    return true if chars.size >= 3 && chars.uniq.size == 1
    return true if chars.size >= 6 && chars.uniq.size <= 2
    return true if chars.size <= 10 && KEYBOARD_RUNS.any? { |run| compact.include?(run) }

    false
  end

  def held_texts_for(response)
    return {} unless response.respond_to?(:persisted?) && response.persisted?
    answers = response.answers.is_a?(Hash) ? response.answers : {}
    return {} unless answers.values.any? { |a| Response.held_entry?(a) }

    # Rows whose marker sits in the answer: still held, or removed (the text is
    # kept until the sweep). A released row's text is back in the answer and
    # already counted; a superseded one was replaced by the respondent.
    response.held_texts.where(status: HeldText::OPEN + %w[removed]).where.not(text: nil)
            .pluck(:card_index, :slot, :text)
            .to_h { |idx, slot, text| [ "#{idx}/#{slot}", text ] }
  end

  # ── answer changes ─────────────────────────────────────────────────────────

  def change_bonus(signals)
    changes = signals["changes"]
    return 0 unless changes.is_a?(Hash)

    [ changes.values.sum { |n| n.is_a?(Integer) ? n : 0 }, MAX_CHANGE_BONUS ].min
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  def question_card?(card)
    card.is_a?(Hash) && CardTypes.question?(card["type"]) && !CardTypes.retired?(card["type"])
  end

  def text_length(value)
    return 0 unless value.is_a?(String)
    # Rich-text cards carry markup; the floor is about what is read.
    value.gsub(/<[^>]*>/, "").strip.grapheme_clusters.size
  end
end
