# Refreshes one Verto's response-integrity baseline and re-scores its responses
# against it (ResponseIntegrity).
#
# Every save scores its own response straight away, against the baseline the
# Verto held at that moment. The baseline — each question's median time to
# answer, once it has enough timed answers to mean anything — moves as answers
# arrive, so the stored scores of earlier respondents drift from what they would
# be today. This brings them back. Nightly for every Verto that collected
# anything in the last day (refresh_all!), and on demand from
# `bin/rails integrity:rescore`.
#
# One job per Verto, batched reads, columns written only where they changed:
# Solid Queue rides inside Puma on a small instance, and a pass over a large
# Verto must not hold its whole response set at once.
class RescoreIntegrityJob < ApplicationJob
  queue_as :default

  BATCH = 500

  # Derived data: the next night's run repeats the work, so a failure is
  # reported and dropped rather than retried into the same fault.
  discard_on StandardError do |job, error|
    ErrorReporting.report("RescoreIntegrityJob", error, survey_id: job.arguments.first)
  end

  def self.refresh_all!(since: 26.hours.ago)
    # Only an integer column is DISTINCTed, which Postgres allows — never a
    # row carrying a json column (CLAUDE.md).
    Response.where(updated_at: since..).distinct.pluck(:survey_id).each { |id| perform_later(id) }
  end

  def perform(survey_id)
    survey = Survey.find_by(id: survey_id)
    return unless survey

    refresh_baseline!(survey)
    band_stampless!(survey)
    rescore_stamped!(survey)
  end

  private

  # Each question's median time to answer, over the respondents who answered
  # it, kept only where a question has ResponseIntegrity::COHORT_MIN_ANSWERS of
  # them. DwellTimes already reads only rows that carry any timing.
  def refresh_baseline!(survey)
    stats = DwellTimes.for(Array(survey.cards), survey.responses.where(answered: true))
    cards = stats.select { |_idx, s| s[:n] >= ResponseIntegrity::COHORT_MIN_ANSWERS }
                 .to_h { |idx, s| [ idx.to_s, { "n" => s[:n], "median_ms" => s[:median_ms] } ] }
    baseline = { "v" => ResponseIntegrity::VERSION, "cards" => cards }
    survey.update_columns(integrity_baseline: baseline) unless survey.integrity_baseline == baseline
  end

  # Responses that carry no signals are banded by SQL alone: there is nothing
  # in them to score, and reading every imported row's answers to learn that
  # would be the whole cost of the job for no result. The text comparison is
  # the cross-engine way to ask "is this json empty" (see DwellTimes).
  def band_stampless!(survey)
    empty = survey.responses.where("CAST(responses.integrity AS TEXT) = '{}'")
    from_player_since = empty.where.not(device_kind: nil).where(created_at: ResponseIntegrity::SIGNALS_SINCE..)
    from_player_since.where.not(integrity_band: "unverified")
                     .update_all(integrity_band: "unverified", integrity_score: nil, integrity_version: ResponseIntegrity::VERSION)
    empty.where.not(id: from_player_since.select(:id)).where.not(integrity_band: "unscored")
         .update_all(integrity_band: "unscored", integrity_score: nil, integrity_version: ResponseIntegrity::VERSION)
  end

  def rescore_stamped!(survey)
    survey.responses.where("CAST(responses.integrity AS TEXT) <> '{}'").reorder(nil)
          .select(:id, :survey_id, :answers, :dwell_ms, :integrity, :created_at, :device_kind,
                  :integrity_score, :integrity_band, :integrity_version)
          .find_each(batch_size: BATCH) { |response| ResponseIntegrity.apply!(response, survey: survey) }
  end
end
