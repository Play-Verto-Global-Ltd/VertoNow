# Per-question breakdowns by gender, age band and country, with small-cell
# suppression applied to every cell.
#
# The suppression rule is applied per CELL, not per segment: a segment that
# clears the floor overall can still fail on a single question that most of them
# skipped.
#
# The floor itself is CorpusEntry.min_sample_size, an account setting. It
# defaults to 1 — no suppression — on this deployment, by the owner's decision:
# every answer counts. `ASK_VERTO_MIN_CELL=30` restores the original, which is
# stricter than the results screen's, because inside an account a segment of
# five reveals nothing the creator cannot already see, and Ask Verto publishes
# across an organisation boundary.
#
# A failing cell is DROPPED, never zeroed. A published "0" is as identifying as a
# published "1" — it says nobody in that group answered that way, which in a small
# group is a statement about named people. Absent means absent.
#
# Only single dimensions are computed. No gender × age, no age × country. Crosses
# are where re-identification actually happens, and the honest answer is not to
# store them at all rather than to store them and hope the floor holds.
class CorpusIndexer
  class SegmentAggregator
    include AggregatesSurveyResults

    # How many segments one Verto contributes, per dimension.
    #
    # A cap trades coverage for index size, and it does so SILENTLY — a Verto
    # fielded in 219 countries used to publish the largest 8 and simply not
    # mention the other 211, so "how did respondents in Togo answer?" had no
    # answer and no explanation. The default is now unlimited, matching the
    # standing instruction that every answer counts; `ASK_VERTO_MAX_SEGMENTS=8`
    # restores the old behaviour if the index ever needs bounding.
    MAX_PER_DIMENSION = ENV.fetch("ASK_VERTO_MAX_SEGMENTS", 10_000).to_i

    def initialize(survey, cards)
      @survey = survey
      @cards  = cards
    end

    # Returns { card_index => { segment_label => { "distribution" => {...}, "n" => 123 } } }
    def call
      base = CorpusIndexer.countable_responses(@survey)
      out  = Hash.new { |h, k| h[k] = {} }

      segments(base).each do |label, scope|
        aggregated = aggregate_results(@cards, scope)

        @cards.each_index do |idx|
          result = aggregated[idx]
          next if result.nil?

          n = result[:total].to_i
          # The cell rule. Below the floor this segment simply does not exist for
          # this question.
          next if n < CorpusEntry.min_sample_size

          counts = countable(result, @cards[idx] || {})
          next if counts.blank?

          out[idx][label] = { "n" => n, "distribution" => counts }
        end
      end

      out
    end

    private

    # [[label, scope]] for every dimension, largest first, capped. Each scope is
    # already floored at MIN_SAMPLE_SIZE overall — a segment that can't clear it
    # in total will never clear it on a question.
    def segments(base)
      gender(base) + age(base) + country(base) + collection_mode(base)
    end

    # How the response was collected, when a Verto was run more than one way.
    #
    # Absent for almost every Verto — the column is NULL when a response came
    # through the player, which is the ordinary case — so this dimension simply
    # doesn't appear rather than producing a single meaningless "everyone" cell.
    # It exists because a programme that ran on paper AND digitally is one study
    # whose two halves are worth comparing, and merging them into one Verto
    # would otherwise throw that comparison away.
    def collection_mode(base)
      base.reorder(nil).where.not(collection_mode: nil)
          .group(:collection_mode).count
          .select { |_mode, n| n >= CorpusEntry.min_sample_size }
          .sort_by { |_mode, n| -n }.first(MAX_PER_DIMENSION)
          .map { |mode, _n| [ "Collected: #{mode}", base.where(collection_mode: mode) ] }
    end

    def gender(base)
      base.reorder(nil).where.not(demographic_gender: nil)
          .group(:demographic_gender).count
          .select { |_g, n| n >= CorpusEntry.min_sample_size }
          .sort_by { |_g, n| -n }.first(MAX_PER_DIMENSION)
          .map { |gender, _n| [ "Gender: #{gender}", base.where(demographic_gender: gender) ] }
    end

    def age(base)
      this_year = Date.current.year

      ResolvesResultSegments::AGE_BANDS.filter_map do |label, min_age, max_age|
        # Same two-generation join as the results page: a birth year from a
        # pre-slider Verto, a band key from one carrying the slider. The
        # reporting bands stay the coarser ones so a figure published from
        # this Verto last month and one published next month mean the same.
        keys  = DemographicQuestions.age_band_keys_within(min_age, max_age)
        scope = base.where(demographic_birth_year: (this_year - max_age)..(this_year - min_age))
                    .or(base.where(demographic_age_band: keys))
        next if scope.reorder(nil).count < CorpusEntry.min_sample_size

        [ "Age: #{label}", scope ]
      end.first(MAX_PER_DIMENSION)
    end

    # Country, not sub-region: a sub-region label plus an age band is a much
    # smaller group than either alone, and the map UI is country-granularity
    # everywhere else in the app anyway.
    def country(base)
      base.reorder(nil).where.not(region_country: nil)
          .group(:region_country).count
          .select { |_c, n| n >= CorpusEntry.min_sample_size }
          .sort_by { |_c, n| -n }.first(MAX_PER_DIMENSION)
          .map do |code, _n|
            [ "Country: #{WorldRegions.name_for(code)}", base.where(region_country: code) ]
          end
    end

    # Segment breakdowns are published for every type whose counts are
    # frequencies — which is every indexable type except prioritise.
    #
    # It used to be COUNT_TYPES only, so `range`, `nps`, `rating`, `tap_card`
    # and `open_ended` got no breakdown at all: on the WLL deck that was every
    # scale question, meaning "how did girls answer this scale?" had no answer
    # anywhere in the corpus even though the data was sitting right there.
    #
    # A scale's counts are keyed by INDEX, so they are resolved to the card's
    # own labels here — a segment reading "Somewhat: 41" and a whole-Verto
    # figure reading "step 3: 41" would be the same number wearing two names.
    #
    # prioritise stays out, for the reason it is special-cased everywhere else:
    # its counts are rank sums, and a segmented rank sum is even easier to
    # misread than a whole-Verto one. open_ended stays out because its "counts"
    # are themes from a model call, which is not something to run per segment.
    SEGMENTABLE_TYPES = (CorpusIndexer::COUNT_TYPES + %w[range nps rating tap_card]).freeze

    def countable(result, card)
      type = result[:type].to_s
      return {} unless SEGMENTABLE_TYPES.include?(type)
      # {statement => {response key => count}} — already nested per statement, so
      # only the keys need resolving to the words the respondent saw. Same reason
      # the scales resolve their indices below: a segment reading
      # "strongly_agree: 41" beside a whole-Verto figure reading
      # "Strongly agree: 41" is the same number wearing two names.
      if type == "tap_card"
        labels = TapScales.for_card(card).to_h { |r| [ r["key"], r["label"] ] }
        return result[:counts].transform_values { |v|
          next v unless v.is_a?(Hash)
          v.each_with_object({}) { |(key, n), out| out[labels[key.to_s] || key.to_s] = n.to_i }
        }
      end

      labels = Array(card["options"]).map(&:to_s)
      result[:counts].each_with_object({}) do |(key, value), out|
        # Scale counts are keyed by index; choice counts by the label itself.
        label = (type == "range" || type == "nps") ? labels[key.to_i] : key.to_s
        out[(label.presence || key.to_s)] = value.to_i if value.is_a?(Numeric)
      end
    end
  end
end
