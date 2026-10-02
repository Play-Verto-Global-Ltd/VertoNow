# The Verto Integrity Score in shadow mode: scores are computed and stored on
# every save but shown to nobody until ResponseIntegrity.visible?. These tasks
# are how the scores get looked at and tuned before then.
#
#   bin/rails integrity:report TOKEN=<publish token, slug or id>
#   bin/rails integrity:rescore TOKEN=...        # one Verto, now, inline
#   bin/rails integrity:rescore_all              # what the nightly job does
namespace :integrity do
  def integrity_survey!
    token = ENV["TOKEN"].to_s.strip
    abort "Set TOKEN to a Verto's publish token, slug or id." if token.empty?

    survey = Survey.find_by(publish_token: token) || Survey.find_by(slug: token) ||
             (token.match?(/\A\d+\z/) ? Survey.find_by(id: token.to_i) : nil)
    abort "No Verto found for #{token.inspect}." unless survey
    survey
  end

  desc "Band split, scores and the commonest reasons for one Verto (TOKEN=...)"
  task report: :environment do
    survey    = integrity_survey!
    answered  = survey.responses.where(answered: true)
    counts    = answered.reorder(nil).group(:integrity_band).count
    scored    = answered.where.not(integrity_score: nil)

    puts "#{survey.title.presence || survey.theme} (id #{survey.id}) — #{answered.count} answered response(s)"
    puts "Scores visible to creators: #{ResponseIntegrity.visible? ? 'yes' : 'no (shadow mode)'}"
    puts
    ResponseIntegrity::BANDS.each { |band| puts format("  %-11s %6d", band, counts[band].to_i) }
    judged = ResponseIntegrity::SCORED_BANDS.sum { |b| counts[b].to_i }
    if judged.positive?
      passing = counts["high"].to_i + counts["medium"].to_i
      puts format("\n  High or Medium: %.0f%% of %d scored", 100.0 * passing / judged, judged)
      puts format("  Mean score:     %.1f", scored.average(:integrity_score).to_f)
    end

    components = Hash.new { |h, k| h[k] = [] }
    reasons    = Hash.new(0)
    scored.reorder(nil).select(:id, :survey_id, :answers, :dwell_ms, :integrity, :created_at, :device_kind)
          .find_each(batch_size: 500) do |response|
      result = ResponseIntegrity.score(response, survey: survey)
      result.components.each { |k, v| components[k] << v }
      result.reasons.each { |r| reasons[r.split(":").first] += 1 }
    end

    if components.any?
      puts "\nComponent means (1.0 = no concern):"
      components.each { |k, vs| puts format("  %-15s %.2f over %d response(s)", k, vs.sum / vs.size, vs.size) }
      puts "\nResponses flagged, by reason:"
      reasons.sort_by { |_r, n| -n }.each { |r, n| puts format("  %-16s %d", r, n) }
    end

    baseline = survey.integrity_baseline.is_a?(Hash) ? survey.integrity_baseline["cards"] : nil
    if baseline.present?
      puts "\nCohort medians in the baseline (questions with #{ResponseIntegrity::COHORT_MIN_ANSWERS}+ timed answers):"
      baseline.sort_by { |k, _| k.to_i }.each do |idx, s|
        puts format("  card %-3s %6.1fs over %d", idx.to_i + 1, s["median_ms"].to_f / 1000, s["n"].to_i)
      end
    end
  end

  desc "Re-score one Verto now, inline (TOKEN=...)"
  task rescore: :environment do
    survey = integrity_survey!
    RescoreIntegrityJob.perform_now(survey.id)
    puts "Re-scored #{survey.title.presence || survey.theme} (id #{survey.id})."
  end

  desc "Enqueue a re-score for every Verto that collected anything in the last day"
  task rescore_all: :environment do
    RescoreIntegrityJob.refresh_all!
    puts "Enqueued."
  end
end
