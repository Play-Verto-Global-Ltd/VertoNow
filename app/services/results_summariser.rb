class ResultsSummariser
  include AnthropicHelpers
  include FormatsResultsDigest

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 1024

  SYSTEM = <<~PROMPT.freeze
    You are an expert survey analyst. You will be given aggregated results from a
    survey and you must produce a concise, actionable insights summary for the
    survey creator. Write in plain English — no markdown headers, no bullet-point
    lists, no asterisks. Use short paragraphs (2-3 sentences each). Be specific:
    reference actual percentages and standout answers where they're revealing.
    Keep the whole summary under 200 words. Tone: clear, professional, slightly
    warm — like a thoughtful colleague sharing a debrief.
  PROMPT
  SYSTEM_WITH_SAFETY = (SYSTEM + PromptSafety::INSTRUCTION).freeze

  # The same summary for a PARTNER — an organisation that sent the survey to
  # its own audience through its own link — read beside everyone else who
  # answered. Everyone else's figures arrive without their written answers
  # (results_digest texts: false); the model is told so, so it neither quotes
  # nor implies words it was never shown.
  PARTNER_SYSTEM = <<~PROMPT.freeze
    You are an expert survey analyst. You will be given aggregated results from a
    survey for the respondents who answered it through one partner
    organisation's own link and, when there are enough of them, for everyone
    else who answered the same survey. Produce a concise, actionable insights
    summary for that partner: what their own respondents said, and — where
    everyone else's figures are given — where the two groups differ most
    (quote both percentages) and where they broadly agree. Everyone else's
    figures are numbers only: never quote or imply you have read their written
    answers. Write in plain English — no markdown headers, no bullet-point
    lists, no asterisks. Use short paragraphs (2-3 sentences each). Keep the
    whole summary under 200 words. Tone: clear, professional, slightly warm —
    like a thoughtful colleague sharing a debrief.
  PROMPT
  PARTNER_SYSTEM_WITH_SAFETY = (PARTNER_SYSTEM + PromptSafety::INSTRUCTION).freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  def call(survey:, aggregated:, total:, &block)
    return yield "Not enough responses to summarise yet." if total.zero?

    stream_summary(SYSTEM_WITH_SAFETY, build_prompt(survey, aggregated, total), &block)
  end

  # `aggregated` is the partner's own respondents; `baseline` everyone else's,
  # or nil where there are too few of them to compare with (the partner
  # results page's small-cell line), in which case only the partner's are
  # described.
  def call_for_partner(survey:, aggregated:, total:, baseline:, baseline_total:, &block)
    return yield "Not enough responses to summarise yet." if total.zero?

    prompt = +"Respondents who answered through the partner's own link:\n\n"
    prompt << results_digest(survey, aggregated, total)
    if baseline
      prompt << "\n\nEveryone else who answered the same survey (figures only):\n\n"
      prompt << results_digest(survey, baseline, baseline_total, header: false, texts: false)
    else
      prompt << "\n\nToo few other people have answered to compare with — describe the partner's respondents only."
    end

    stream_summary(PARTNER_SYSTEM_WITH_SAFETY, prompt, &block)
  end

  private

  def stream_summary(system, prompt)
    stream = @client.messages.stream_raw(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     system,
      messages:   [ { role: "user", content: prompt } ]
    )

    # message_start carries input/cache token counts; the final output_tokens
    # arrives later on message_delta.
    usage = nil
    final_output = nil
    stream.each do |raw_event|
      type = raw_event.type if raw_event.respond_to?(:type)
      case type
      when :message_start
        usage = raw_event.message.usage
      when :message_delta
        final_output = raw_event.usage.output_tokens if raw_event.respond_to?(:usage) && raw_event.usage
      when :content_block_delta
        delta = raw_event.delta
        yield delta.text if delta.respond_to?(:type) && delta.type == :text_delta && delta.text
      end
    end
    log_usage("ResultsSummariser", usage, model: MODEL, output_tokens: final_output)
  end

  def build_prompt(survey, aggregated, total)
    results_digest(survey, aggregated, total)
  end
end
