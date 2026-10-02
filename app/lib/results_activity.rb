# Pushes a live response tally to anyone watching a Verto's results.
#
# Deliberately small. The obvious implementation — re-render the whole
# results-feed frame on each response — would re-run the full aggregation over
# every response for every viewer on every submission, which is a self-inflicted
# load problem on a Verto that's actually being answered. It would also reshuffle
# the charts under someone mid-read.
#
# So the broadcast carries two grouped COUNT queries and nothing else. The
# numbers move live; the breakdown refreshes when the creator asks for it.
module ResultsActivity
  module_function

  # The stream a results page subscribes to. Turbo signs this name into the
  # page, so a subscriber needs a rendered results page to get it — which is
  # already org-scoped.
  def stream_for(survey)
    [ survey, :results_activity ]
  end

  # Through Survey#integrity_filtered, so the live tally counts what the
  # cards under it count.
  def counts_for(survey)
    responses = survey.integrity_filtered(survey.responses)
    {
      responders: responses.where(answered: true).count,
      completed:  responses.where(answered: true, status: "completed").count
    }
  end

  def broadcast(survey)
    counts = counts_for(survey)

    Turbo::StreamsChannel.broadcast_replace_to(
      *stream_for(survey),
      target:  "results-live",
      partial: "surveys/results_live",
      locals:  { survey: survey, **counts, live: true }
    )
  end
end
