# Builds tabular exports of a Verto's results from its (segment-scoped)
# responses. Returns plain arrays-of-arrays so the same rows can be streamed as
# CSV (ResultsExportsController) or written to a Google Sheet (GoogleSheetsWriter).
#
# Two tables are produced:
#   * #response_rows — one row per respondent, one column per question.
#   * #summary_rows  — aggregated counts/percentages, mirroring the results screen.
#
# `answers` is untrusted client JSON keyed by card index ("0", "1", …) with the
# shape { "type", "value", "other"? }; every accessor guards nil / wrong types.
class ResultsExport
  # "Device" is the device KIND (phone/desktop); "Device group" is the
  # leaderboard's anonymous browser identity — rows sharing one came from the
  # same browser. "Responder" is the anonymous name for a respondent-code
  # identity. Both are minted names (PlayerAlias / RespondentAlias), never the
  # digests: a digest is a stable cross-export handle on a hashed value, and
  # the leak tests hold this file to never emitting one.
  RESPONSE_HEADER = [ "Response ID", "Submitted at", "Source", "Language",
                      "Duration (seconds)", "Device", "Responder", "Device group" ].freeze
  RESPONDER_COLUMN    = RESPONSE_HEADER.index("Responder")
  DEVICE_GROUP_COLUMN = RESPONSE_HEADER.index("Device group")
  # The Verto Integrity Score's band (ResponseIntegrity), after every other
  # column so nothing reading the file by position moves. The band only: the
  # number and the signals behind it stay out of exports, as Mike's proposal
  # asks — a creator filtering a spreadsheet on "score < 48" is acting on a
  # precision the score does not have. Only while scores are visible at all.
  INTEGRITY_HEADER = "Integrity band".freeze
  # The whole run's time answering (Response#total_dwell_ms), after the
  # per-question dwell block it is the sum of.
  TOTAL_DWELL_HEADER = "Total dwell time (seconds)".freeze
  SUMMARY_HEADER  = [ "Card #", "Card type", "Question", "Answer option", "Count", "Percentage", "Total answers" ].freeze
  CHOICE_TYPES    = %w[multiple_choice yes_no select_one_grid select_many select_many_grid scenario].freeze

  # Spreadsheet formula-injection guard: Excel/Sheets treat a cell beginning
  # with one of these as a formula, so a respondent's free-text answer like
  # `=HYPERLINK(...)` would execute when the owner opens the export (and would
  # auto-evaluate in the Google Sheet). Such strings are prefixed with a quote.
  FORMULA_TRIGGERS = [ "=", "+", "-", "@", "\t", "\r" ].freeze

  def initialize(survey:, responses:, aggregated:)
    @survey     = survey
    @responses  = responses
    @aggregated = aggregated
  end

  # [header, *one row per response]. Question columns skip welcome cards.
  # Materialised form for the Google Sheets writer (needs the full array for its
  # batch API); the CSV download streams via each_row instead.
  def response_rows
    [].tap { |rows| each_response_row { |row| rows << row } }
  end

  # [header, *one row per answer option] built from the aggregated results.
  def summary_rows
    [].tap { |rows| each_summary_row { |row| rows << row } }
  end

  # Entry point for the CSV download: yields one already-sanitized row at a
  # time, so the controller never holds the generated CSV string in memory.
  # Response rows are buffered once internally to be grouped by responder
  # (see each_response_row); the summary path streams as before.
  def each_row(summary:, &block)
    summary ? each_summary_row(&block) : each_response_row(&block)
  end

  private

  # One row per response, grouped by responder: a coded responder's runs sit
  # together (responders in name order, runs in play order), then every
  # uncoded row in today's chronological order — so a deck with no codes
  # exports byte-identically ordered to before the grouping existed.
  #
  # Rows are buffered as plain cell arrays before yielding: find_each cannot
  # honour a custom ORDER BY, and a SQL ORDER BY over the nullable digest
  # would sort NULLs differently on SQLite and Postgres. The buffer holds
  # formatted cells (never AR objects), which puts this path's peak memory
  # where the Sheets/XLSX paths already are — both materialise every row.
  def each_response_row
    integrity = ResponseIntegrity.visible?
    yield csv_safe_row(RESPONSE_HEADER +
                       question_cards.map { |card, _idx| question_text(card) } +
                       question_cards.map { |card, _idx| dwell_header(card) } +
                       [ TOTAL_DWELL_HEADER ] +
                       (integrity ? [ INTEGRITY_HEADER ] : []))

    buffered = []
    each_export_response do |response|
      answers = response.answers.is_a?(Hash) ? response.answers : {}
      cells = [
        response.id,
        response.created_at&.strftime("%Y-%m-%d %H:%M"),
        source_label(response),
        response.locale,
        response.duration_seconds,
        response.device_kind,
        # Filled from the minted-name maps below. The placeholders are nil —
        # never the digests — so a fill bug cannot leak one into a cell.
        nil,
        nil
      ] + question_cards.map { |card, idx| format_answer(card, answers[idx.to_s]) } +
        # Dwell time per question, as a block AFTER the answers rather than
        # interleaved beside each one: every column that existed before keeps
        # its position, so nothing reading this file by column index moves.
        # Seconds to one decimal; blank where the player recorded nothing
        # (a response from before dwell existed, a card never shown). The
        # time is given for a card the respondent viewed and skipped too —
        # that is real behaviour — whereas the summary's typical figure is
        # over answers only (DwellTimes).
        question_cards.map { |_card, idx| response.dwell_seconds_at(idx) || "" } +
        [ response.total_dwell_seconds || "" ] +
        (integrity ? [ response.integrity_band.to_s ] : [])
      buffered << { cells: cells,
                    code_digest: response.respondent_code_digest.presence,
                    device_digest: response.player_key_digest.presence,
                    at: response.created_at || Time.at(0),
                    id: response.id }
    end

    responder_names = alias_names(buffered.map { |row| row[:code_digest] },
                                  RespondentAlias, :code_digest)
    device_names    = alias_names(buffered.map { |row| row[:device_digest] },
                                  PlayerAlias, :key_digest)

    buffered.each do |row|
      row[:cells][RESPONDER_COLUMN]    = responder_names[row[:code_digest]] || ""
      row[:cells][DEVICE_GROUP_COLUMN] = device_names[row[:device_digest]] || ""
    end

    # Names are unique per survey, so the responder name alone is the group
    # key; blank names (no code) sort behind every named group.
    buffered.sort_by! do |row|
      name = row[:cells][RESPONDER_COLUMN]
      [ name.empty? ? 1 : 0, name, row[:at], row[:id] ]
    end

    buffered.each { |row| yield csv_safe_row(row[:cells]) }
  end

  # digest → minted anonymous name for every distinct digest in the buffered
  # rows. Minting is idempotent and happens at read time (the leaderboard's
  # posture), so the first export of a Verto names everyone it lists.
  def alias_names(digests, model, digest_key)
    digests.compact.uniq.index_with do |digest|
      model.ensure_for!(:survey => @survey, digest_key => digest).anon_name
    end
  end

  def each_summary_row
    yield csv_safe_row(SUMMARY_HEADER)
    @aggregated.each_with_index do |result, idx|
      type = result[:type].to_s
      next unless CardTypes.question?(type)

      number   = idx + 1
      question = question_text(result[:card])
      total    = result[:total].to_i
      summary_option_rows(result, type).each do |label, count, pct|
        yield csv_safe_row([ number, type, question, label, count, pct, total ])
      end
      # How long it typically took to answer, in the rating card's "Average
      # (1–5)" shape: a figure in the Count column, no percentage. Its own
      # "Total answers" is the number of answers the figure is over, which can
      # be fewer than the card's — responses collected before dwell existed
      # have no time to contribute.
      #
      # "Time to answer", not "Dwell time", and the difference is the
      # population: these rows are over respondents who ANSWERED the card
      # (DwellTimes), the same figure the results page shows beside the answer
      # count. The per-response table's "Dwell time" columns are time on the
      # card, answered or not — so the median of that column is not this row,
      # and the two names say why.
      next unless (stat = dwell_stats[idx])

      yield csv_safe_row([ number, type, question, TIME_TO_ANSWER_MEDIAN_LABEL, dwell_seconds(stat[:median_ms]), nil, stat[:n] ])
      yield csv_safe_row([ number, type, question, TIME_TO_ANSWER_MEAN_LABEL,   dwell_seconds(stat[:mean_ms]),   nil, stat[:n] ])
    end
  end

  TIME_TO_ANSWER_MEDIAN_LABEL = "Time to answer — median (seconds)".freeze
  TIME_TO_ANSWER_MEAN_LABEL   = "Time to answer — mean (seconds)".freeze

  # The per-question header for a dwell column, built from the same text the
  # answer column uses so the two line up by eye.
  def dwell_header(card)
    "Dwell time (seconds): #{question_text(card)}"
  end

  def dwell_seconds(ms)
    (ms.to_f / 1000).round(1)
  end

  # Per-card typical time to answer, over the same responses the rows are
  # (DwellTimes — answered cards only, median first). Computed on demand: the
  # per-response table reads each row's own figures and never needs this.
  def dwell_stats
    @dwell_stats ||= DwellTimes.for(Array(@survey.cards), @responses)
  end

  # Iterate the response set without loading it all at once. For an AR relation,
  # batch through find_each selecting only the columns the export reads; for an
  # in-memory array (e.g. tests), iterate directly.
  def each_export_response(&block)
    if @responses.respond_to?(:find_each)
      @responses.reorder(nil)
        .select(:id, :created_at, :locale, :survey_share_id, :survey_link_id, :answers,
                :started_at, :completed_at, :device_kind, :dwell_ms,
                :respondent_code_digest, :player_key_digest, :integrity_band)
        .find_each(batch_size: 500, &block)
    else
      @responses.each(&block)
    end
  end

  # [card, original_index] for every non-welcome card, so answers (keyed by the
  # original card index) still line up after welcome cards are dropped.
  def question_cards
    @question_cards ||= Array(@survey.cards).each_with_index.reject do |card, _idx|
      card.is_a?(Hash) && !CardTypes.question?(card["type"])
    end
  end

  def question_text(card)
    return "Untitled" unless card.is_a?(Hash)
    card["text"].presence || card["prompt"].presence || card["title"].presence || "Untitled"
  end

  # Maps a response back to a human label for which link it came through,
  # mirroring the results-screen segment labels: a named custom link, else a
  # partner share, else the Verto's own address. A response carries at most one
  # of the two ids (PlayerController#load_survey_and_share resolves a share OR
  # a link), so the order here is a tie-break, not a policy.
  def source_label(response)
    if response.survey_link_id && (name = link_labels[response.survey_link_id])
      return name
    end
    return "Direct link" if response.survey_share_id.nil?
    share_labels[response.survey_share_id] || "Partner"
  end

  # Every link, recalled ones included — a paused link's old responses still
  # point at it. A deleted link nullifies (SurveyLink has_many :responses,
  # dependent: :nullify), so those rows read "Direct link" again.
  def link_labels
    @link_labels ||= @survey.survey_links.pluck(:id, :name).to_h
  end

  def share_labels
    @share_labels ||= @survey.survey_shares
      .includes(:partner_organisation, partnership_verto: :partnership)
      .each_with_object({}) do |share, h|
        partnership_name = share.partnership_verto&.partnership&.name
        h[share.id]   = partnership_name ? "#{share.display_name} · #{partnership_name}" : share.display_name
      end
  end

  # One CSV cell for a single answer, formatted per card type.
  def format_answer(card, answer)
    return "" unless answer.is_a?(Hash)

    value = answer["value"]
    other = answer["other"].presence
    # Free text the moderator is holding or has removed: the cell says so,
    # rather than reading as an unanswered question — see Moderation::Hold.
    held = answer["held"].is_a?(Hash) ? answer["held"] : {}
    value = held_placeholder(held["value"]) if value.nil? && held["value"]
    other = held_placeholder(held["other"]) if other.nil? && held["other"]

    text =
      case card["type"].to_s
      when "select_many", "select_many_grid"
        Array(value).map(&:to_s).reject(&:blank?).join("; ")
      when "range"
        range_label(card, value)
      when "tap_card"
        # The stored value is a key ("strongly_agree"); the cell says what the
        # respondent actually saw ("Strongly agree"), falling back to the raw key
        # for an answer collected on a scale the card no longer carries.
        if value.is_a?(Hash)
          labels = TapScales.for_card(card).to_h { |r| [ r["key"], r["label"] ] }
          value.map { |label, key| "#{label}: #{labels[key.to_s] || key}" }.join("; ")
        else
          ""
        end
      when "contact_form"
        # "Name: …; Company: …" — one readable cell, fields in a fixed order.
        value.is_a?(Hash) ? Survey::CONTACT_FIELDS.filter_map { |f| "#{f.capitalize}: #{value[f]}" if value[f].present? }.join("; ") : ""
      else
        # multiple_choice, yes_no, select_one_grid, nps, rating, open_ended, …
        value.nil? ? "" : value.to_s
      end

    return text unless other
    text.present? ? "#{text}; Other: #{other}" : "Other: #{other}"
  end

  HELD_PLACEHOLDER    = "[awaiting moderation]".freeze
  REMOVED_PLACEHOLDER = "[removed by moderation]".freeze

  def held_placeholder(marker)
    marker == "removed" ? REMOVED_PLACEHOLDER : HELD_PLACEHOLDER
  end

  # A range answer's stored value is the zero-based step index; show its label.
  def range_label(card, value)
    return value.to_s unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
    i = value.to_i
    (Array(card["options"])[i].presence || "Step #{i + 1}").to_s
  end

  # [[label, count, percentage], …] for one aggregated result. Mirrors the
  # per-type rendering in app/views/surveys/results.html.erb.
  def summary_option_rows(result, type)
    counts = result[:counts] || {}
    case type
    when *CHOICE_TYPES
      # `counts` already includes an "Other" bucket when free-text was given.
      grand = counts.values.sum
      counts.sort_by { |_label, n| -n }.map { |label, n| [ label.to_s, n, pct(n, grand) ] }
    when "range"
      labels = Array(result.dig(:card, "options"))
      n      = [ labels.size, 2 ].max
      grand  = counts.values.sum
      Array.new(n) do |i|
        c = counts[i].to_i
        [ (labels[i].presence || "Step #{i + 1}").to_s, c, pct(c, grand) ]
      end + other_rows(result)
    when "rating"
      grand = counts.values.sum
      star_rows = (1..5).map { |star| [ "#{star} star#{star == 1 ? '' : 's'}", counts[star].to_i, pct(counts[star].to_i, grand) ] }
      star_rows + [ [ "Average (1–5)", result[:avg], nil ] ] + other_rows(result)
    when "nps"
      grand = counts.values.sum
      counts.keys.sort_by(&:to_i).map { |k| [ k.to_s, counts[k].to_i, pct(counts[k].to_i, grand) ] } + other_rows(result)
    when "prioritise"
      # counts[label] = sum of ranks; mean position = sum / total (lower = higher
      # priority). Export the ranked order with each option's average position.
      total = [ result[:total].to_i, 1 ].max
      counts.map { |label, sum| [ label.to_s, sum.to_f / total ] }
            .sort_by { |_l, mean| mean }
            .each_with_index.map { |(label, mean), i| [ "#{i + 1}. #{label}", "avg #{mean.round(2)}", nil ] }
    when "tap_card"
      responses = TapScales.for_card(result[:card])
      counts.flat_map do |label, tallies|
        tallies = {} unless tallies.is_a?(Hash)
        tot = responses.sum { |r| tallies[r["key"]].to_i }
        responses.map do |r|
          n = tallies[r["key"]].to_i
          [ "#{label} — #{r['label']}", n, pct(n, tot) ]
        end
      end + other_rows(result)
    when "open_ended"
      [ [ "(free-text responses)", Array(result[:texts]).size, nil ] ] + other_rows(result)
    else
      other_rows(result)
    end
  end

  # An "Other" free-text row for types that don't fold it into `counts`.
  def other_rows(result)
    others = Array(result[:other_texts])
    return [] if others.empty?
    [ [ "Other (free text)", others.size, nil ] ]
  end

  def pct(count, grand)
    return 0.0 unless grand.to_f.positive?
    ((count.to_f / grand) * 100).round(1)
  end

  def csv_safe_row(row)
    row.map { |cell| csv_safe(cell) }
  end

  # Neutralize a single cell against spreadsheet formula injection (see
  # FORMULA_TRIGGERS). Non-strings (counts, ids, percentages) pass through.
  def csv_safe(value)
    return value unless value.is_a?(String)
    value.start_with?(*FORMULA_TRIGGERS) ? "'#{value}" : value
  end
end
