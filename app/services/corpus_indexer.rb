# Turns one approved Verto's responses into the rows Ask Verto answers from.
#
# This is the only place respondent data is read for Ask Verto. It runs inside the
# owning account, aggregates with the app's existing AggregatesSurveyResults (so
# there is exactly one aggregation implementation in the codebase, not two that
# can disagree), applies small-cell suppression, and writes counts. Nothing that
# identifies a person is carried across.
#
# ── The prioritise trap ────────────────────────────────────────────────────────
# AggregatesSurveyResults stores a prioritise card's counts as a SUM OF 1-BASED
# RANKS (see accumulate_value: `st[:counts][label] += (i + 1)`), not as a
# frequency. It looks exactly like a count and it is the opposite of one — a
# LOWER number means a HIGHER priority. Indexed naively, "Money: 480" would be
# read by the model, and by any reader, as 480 people choosing money, when it
# means money was ranked highly. Every prioritise citation would be confidently
# wrong with no visible symptom.
#
# So prioritise is converted to a mean rank here and stored under a distinct
# shape ("mean_rank"), never as `distribution` counts. If a future card type
# accumulates something that isn't a frequency, it must be handled here too or
# excluded — INDEXABLE_TYPES is deliberately an allow-list for that reason.
class CorpusIndexer
  include AggregatesSurveyResults

  # Only these types produce a citable distribution. An allow-list, not a
  # deny-list: a new card type is silently absent from Ask Verto until someone
  # decides what citing it would mean, which is the safe direction to fail.
  #
  # Excluded on purpose:
  #   contact_form    collects a name and an email. Never.
  #   prioritise      rank sums, not counts — see above. Indexed separately.
  #   welcome_card,
  #   consent_gate,
  #   token_checkpoint   not questions.
  INDEXABLE_TYPES = %w[
    multiple_choice yes_no select_one_grid select_many select_many_grid
    scenario tap_card range nps rating open_ended
  ].freeze

  # Types whose distribution is a straight {label => count}.
  COUNT_TYPES = %w[
    multiple_choice yes_no select_one_grid select_many select_many_grid scenario
  ].freeze

  def self.indexable?(type) = INDEXABLE_TYPES.include?(type.to_s)

  # Every response that answered SOMETHING — not only the ones that reached the
  # last card.
  #
  # Completion used to be the gate here and in SegmentAggregator: `status`
  # is "completed" only when the export said 100%, and half of some exports
  # never did (WLL digital: 22,572 of 50,835 sessions, against 44,585 carrying
  # real answers). But a respondent who answered eleven of twenty-four questions
  # answered those eleven, and a per-question distribution has always counted
  # the people who answered THAT question. The completion filter was never
  # making the numbers more honest — it was removing answers that were given.
  #
  # Sessions with nothing in them are still out: they are real and they are
  # stored, but they belong in no question's denominator. `answered` is the
  # app's own canonical definition of that (Response.answered_entry?), kept in
  # step by a before_save and indexed alongside survey_id.
  #
  # Low and unverified responses are out too, once integrity scores are live
  # (ResponseIntegrity.visible?): the Privacy Notice tells respondents the
  # Commons is built from responses given with care. Whatever the creator's
  # own results switch says — that is a view of their results; this is what
  # leaves their account. Unscored responses (collected before scoring, or
  # imported) stay in: there is nothing in them to judge.
  def self.countable_responses(survey)
    scope = survey.responses.where(answered: true)
    ResponseIntegrity.visible? ? scope.where(integrity_band: ResponseIntegrity::PASSING_BANDS) : scope
  end

  def initialize(entry, themer: OpenTextThemer.new)
    @entry  = entry
    @survey = entry.survey
    @themer = themer
  end

  # Rebuild this entry's index in place.
  #
  # Rows are matched on `cid` and UPDATED rather than deleted and recreated, so a
  # corpus_question keeps its id across re-indexes. That id is the citation: a
  # delete-and-recreate would silently re-point every citation already stored on
  # an answered message.
  def call
    responses = self.class.countable_responses(@survey)
    total     = responses.count
    return skip!(total) if total < CorpusEntry.min_sample_size
    # The Commons' 70% rule, held here as well as in the review queue
    # (CorpusChecks#integrity): an approved Verto whose responses have since
    # slipped under it stops contributing at the next nightly refresh, rather
    # than staying cited on the strength of an earlier approval.
    return skip!(total) unless ResponseIntegrity.commons_eligible?(@survey)

    cards      = Array(@survey.cards)
    aggregated = aggregate_results(cards, responses)
    segments   = SegmentAggregator.new(@survey, cards).call

    seen_cids = []

    CorpusEntry.transaction do
      cards.each_with_index do |card, idx|
        type = card["type"].to_s
        next unless self.class.indexable?(type) || type == "prioritise"
        # The offered scope is enforced here, where data crosses the boundary
        # — a question outside the offer never becomes a corpus row, whatever
        # the picker sent. Questions excluded by a narrowed re-offer drop out
        # via the seen_cids sweep below, like any other removed question.
        next unless @entry.offers_card?(card)

        result = aggregated[idx]
        next if result.nil? || result[:total].to_i < CorpusEntry.min_sample_size

        cid = card["cid"].presence || "idx_#{idx}"
        seen_cids << cid

        question = @entry.corpus_questions.find_or_initialize_by(cid: cid)
        question.assign_attributes(
          position:       idx,
          card_type:      type,
          question_text:  card["text"].to_s.presence || card["title"].to_s,
          options:        Array(card["options"]).map(&:to_s),
          theme:          card["theme"].presence || @survey.theme,
          distribution:   distribution_for(type, result, card),
          response_count: result[:total].to_i,
          segments:       segments[idx] || {}
        )
        question.save!

        index_quotes(question, result) if type == "open_ended"
      end

      # Questions that no longer exist in the deck (or fell below the sample
      # floor) leave the corpus. Their citations on old messages become stale,
      # which AskMessage#stale_sources surfaces — the right outcome, rather than
      # answering from a question that isn't there any more.
      @entry.corpus_questions.where.not(cid: seen_cids).destroy_all

      @entry.update!(indexed_at: Time.current, response_count: total)
    end

    @entry
  end

  # A read-only preview for the review queue: the same aggregation `call`
  # would store, computed in memory and never persisted, filtered to what the
  # creator actually offered — so a reviewer approves exactly what would
  # become citable. Flat-count types render as bars; open text and nested
  # shapes (tap_card) show their totals only, because previewing themes
  # honestly would need the themer and a decline must not cost an AI pass.
  PREVIEW_QUESTIONS = 6
  PREVIEW_BARS = 5

  def preview_rows
    responses  = self.class.countable_responses(@survey)
    cards      = Array(@survey.cards)
    aggregated = aggregate_results(cards, responses)

    rows = []
    cards.each_with_index do |card, idx|
      break if rows.size >= PREVIEW_QUESTIONS

      type = card["type"].to_s
      next unless self.class.indexable?(type)
      next unless @entry.offers_card?(card)

      result = aggregated[idx]
      next if result.nil? || result[:total].to_i.zero?

      counts = type == "open_ended" ? {} : distribution_for(type, result, card).except("avg")
      counts = counts.select { |_label, value| value.is_a?(Numeric) }
      counted = counts.values.sum

      rows << {
        text:  card["text"].to_s.presence || card["title"].to_s,
        type:  type,
        total: result[:total].to_i,
        bars:  counts.sort_by { |_label, value| -value }.first(PREVIEW_BARS).map do |label, value|
          { label: label, count: value.to_i,
            percent: counted.zero? ? 0 : (value * 100.0 / counted).round(1) }
        end
      }
    end
    rows
  end

  private

  def skip!(total)
    # Below the floor the Verto contributes nothing, and any rows it had must go.
    CorpusEntry.transaction do
      @entry.corpus_questions.destroy_all
      @entry.update!(indexed_at: Time.current, response_count: total)
    end
    @entry
  end

  # The shape the tools read. Distinct shapes rather than one hash of counts,
  # because "48% chose this" and "this ranked 2.1 on average" are different claims
  # and a single shape would let the model state one as the other.
  def distribution_for(type, result, card)
    case type
    when *COUNT_TYPES
      stringify_counts(result[:counts])
    when "tap_card"
      # {statement => {response key => count}}, already the right shape — but the
      # keys are resolved to the words the respondent saw, for the same reason
      # `range` resolves its indices below: a citation should read "Strongly
      # agree", not "strongly_agree", and on a relabelled scale the key may not
      # even be the creator's word for it.
      labels = TapScales.for_card(card).to_h { |r| [ r["key"], r["label"] ] }
      result[:counts].transform_values do |v|
        next v.to_i unless v.is_a?(Hash)
        v.each_with_object({}) { |(key, n), out| out[labels[key.to_s] || key.to_s] = n.to_i }
      end
    when "range", "nps"
      # Steps are indices into the card's option labels; resolve them here so a
      # citation reads "Very worried", not "step 3".
      labels = Array(card["options"]).map(&:to_s)
      result[:counts].each_with_object({}) do |(step, count), out|
        out[labels[step.to_i] || "Step #{step.to_i + 1}"] = count.to_i
      end
    when "rating"
      stringify_counts(result[:counts]).merge("avg" => result[:avg])
    when "prioritise"
      # See the class comment. counts[label] is a SUM OF RANKS; total is the
      # number of respondents who ordered the list. Mean rank is the only honest
      # reading, and it is stored under its own key so nothing can mistake it for
      # a frequency.
      total = result[:total].to_i
      return {} if total.zero?

      ranks = result[:counts].each_with_object({}) do |(label, rank_sum), out|
        out[label.to_s] = (rank_sum.to_f / total).round(2)
      end
      { "mean_rank" => ranks }
    when "open_ended"
      # Themes are filled in by index_quotes; the count is what's citable here.
      { "responses" => result[:total].to_i }
    else
      {}
    end
  end

  def stringify_counts(counts)
    counts.each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_i }
  end

  # Open text: themes with counts, plus the quotes that survive redaction.
  def index_quotes(question, result)
    texts = Array(result[:texts]).select { |t| t.is_a?(String) }
    return if texts.empty?

    kept, drops = QuoteRedactor.redact_all(texts)
    themed = @themer.call(question_text: question.question_text, texts: kept)

    question.update!(
      distribution: {
        "responses" => result[:total].to_i,
        "themes"    => themed[:themes],
        # The denominator the THEME counts were taken over, which is not the
        # same number as `responses`: redaction drops answers before theming
        # ever sees them, and an enormous column is batched across a stride.
        # Handing both to Ask Verto with nothing distinguishing them is how a
        # theme covering 40 of 250 read answers gets cited as 40 of 27,088.
        "themed_over" => themed[:read].to_i,
        "sampled"     => !!themed[:sampled],
        "redacted"  => drops.transform_keys(&:to_s)
      }.compact
    )

    sync_quotes!(question, themed[:quotes])
  rescue => e
    # A Verto must still be citable for its closed questions when the theming
    # call fails. Quotes are the enrichment, not the point.
    ErrorReporting.report("CorpusIndexer#index_quotes", e, corpus_question_id: question.id)
    question.update!(distribution: { "responses" => result[:total].to_i })
  end

  # A quote's id IS a citation — an answered message stores "[[q:1234]]" and
  # renders it server-side on replay. Destroying and recreating the set on every
  # re-index therefore re-pointed every quote marker already sitting in someone's
  # thread: the same care corpus_questions get from being matched on `cid`, and
  # for the same reason.
  #
  # A quote has no id of its own in the source, so it is matched on its redacted
  # body — which is what it is. Same words, same row, same id.
  def sync_quotes!(question, quotes)
    existing = question.corpus_quotes.index_by(&:body)
    kept = []

    quotes.each do |quote|
      row = existing[quote[:body]]
      if row
        row.update!(theme: quote[:theme])
      else
        row = question.corpus_quotes.create!(body: quote[:body], theme: quote[:theme])
      end
      kept << row.id
    end

    # A quote the model no longer picks does go — a citation to it becomes a
    # stale source, which AskMessage#stale_sources already tells the reader
    # about. That is honest; silently re-pointing it at different words is not.
    question.corpus_quotes.where.not(id: kept).destroy_all
  end
end
