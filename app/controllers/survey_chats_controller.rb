class SurveyChatsController < ApplicationController
  include ActionController::Live
  include AggregatesSurveyResults
  include LimitsConcurrentStreams
  include ThrottlesAiSpend

  limit_concurrent_streams only: :create

  # One Claude call per message sent. The slot pool below bounds how many run at
  # once; this bounds how many one user can start (P0-4). Generous, because a
  # real conversation is a run of messages in quick succession.
  throttle_ai to: 60, within: 1.hour, name: "ai-chat", respond: :plain, only: %i[ create ]

  def create
    survey    = Current.organisation.surveys.find(params[:survey_id])
    responses = survey.integrity_filtered(survey.responses.where(status: "completed")).order(created_at: :desc)
    total     = responses.count
    aggregated = aggregate_results(Array(survey.cards), responses)

    body     = JSON.parse(request.body.read)
    messages = Array(body["messages"]).last(20)

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    ResultsChat.new.call(
      survey:     survey,
      aggregated: aggregated,
      total:      total,
      messages:   messages
    ) do |chunk|
      response.stream.write(chunk)
    end
  rescue ActiveRecord::RecordNotFound
    raise # let Rails return a clean 404 before any stream is opened
  rescue => e
    ErrorReporting.report("SurveyChatsController", e)
    response.stream.write("Sorry, I couldn't answer that right now.") rescue nil
  ensure
    response.stream.close if response.committed?
  end
end
