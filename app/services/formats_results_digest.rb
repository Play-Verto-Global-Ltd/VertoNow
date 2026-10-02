# Renders aggregated survey results as a plain-text digest for Claude prompts —
# shared by the short insights summary (ResultsSummariser) and the full AI
# report (ResultsReportGenerator), so both describe the underlying data
# identically.
#
# `header: false` leaves out the survey's own lines, for a second group of
# respondents to the same survey described after the first. `texts: false`
# leaves out every written answer, keeping only their count — for a group
# whose numbers may be shown to someone but whose words may not (a partner's
# summary describes everyone else's answers; it never quotes them).
module FormatsResultsDigest
  private

  def results_digest(survey, aggregated, total, header: true, texts: true)
    lines = []
    if header
      lines << "Survey: \"#{survey.title}\""
      lines << "Theme: #{survey.theme}"
      lines << "Key insight goal: #{survey.key_insight}"
    end
    lines << "Total responses: #{total}"
    lines << ""
    lines << "Per-question results:"
    lines << ""

    aggregated.each_with_index do |result, idx|
      type = result[:type]
      card = result[:card]
      next unless CardTypes.question?(type)

      lines << "Q#{idx + 1} [#{type}]: #{card["text"]}"

      case type
      when "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid"
        counts = result[:counts]
        grand  = counts.values.sum.to_f
        grand  = 1.0 if grand.zero?
        counts.sort_by { |_, v| -v }.each do |label, count|
          pct = ((count / grand) * 100).round
          lines << "  #{label}: #{count} (#{pct}%)"
        end

      when "tap_card"
        responses = TapScales.for_card(result[:card])
        result[:counts].each do |label, tallies|
          tallies = {} unless tallies.is_a?(Hash)
          tot = [ responses.sum { |r| tallies[r["key"]].to_i }.to_f, 1.0 ].max
          parts = responses.map do |r|
            n = tallies[r["key"]].to_i
            "#{r['label']} #{n} (#{((n / tot) * 100).round}%)"
          end
          lines << "  \"#{label}\" → #{parts.join(', ')}"
        end

      when "range"
        labels = Array(card["options"])
        grand  = result[:counts].values.sum.to_f
        grand  = 1.0 if grand.zero?
        result[:counts].sort.each do |step, count|
          label = labels[step] || "Step #{step + 1}"
          pct   = ((count / grand) * 100).round
          lines << "  #{label}: #{count} (#{pct}%)"
        end

      when "prioritise"
        # counts[label] = sum of ranks; mean position = sum / total. Lower mean
        # = higher priority, so list the ranked order for the AI summariser.
        total = [ result[:total].to_i, 1 ].max
        lines << "  Ranked by priority (#{result[:total]} responses, lower avg = higher):"
        result[:counts].map { |label, sum| [ label, sum.to_f / total ] }
                       .sort_by { |_l, mean| mean }
                       .each_with_index { |(label, mean), i| lines << "  #{i + 1}. #{label} (avg #{mean.round(2)})" }

      when "rating"
        lines << "  Average: #{result[:avg]} / 5 (#{result[:total]} responses)"
        result[:counts].sort.each do |star, count|
          lines << "  #{star} star#{"s" if star != 1}: #{count}"
        end

      when "open_ended"
        if texts
          sample = result[:texts].first(5)
          lines << "  Sample responses (#{result[:total]} total):"
          sample.each { |t| lines << "    - #{PromptSafety.quote(t, limit: 120)}" }
        else
          lines << "  #{result[:total]} written answers (withheld)"
        end

      when "contact_form"
        # Names/companies/emails are identifying data — deliberately NOT put
        # in an AI prompt. The count is the only thing worth summarising.
        lines << "  #{result[:total]} contact-detail submissions (identifying data, withheld from AI)"
      end

      lines << ""
    end

    lines.join("\n")
  end
end
