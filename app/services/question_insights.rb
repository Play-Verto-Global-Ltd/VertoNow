# One reading per question: what this question's answers actually say.
#
# The results page already had two AI surfaces and neither answered the
# question a creator asks while looking at a single chart. ResultsSummariser
# writes one blurb about the WHOLE Verto, and the AI report writes a document
# you generate, read once and export. Between them sits the thing people
# actually do — look at a bar chart and wonder what it means — and nothing was
# there.
#
# Two decisions worth the words:
#
# ONE CALL, NOT N. Twenty questions is twenty streams, twenty throttle slots
# and twenty chances to half-fail; and the interesting readings are the ones
# that see the OTHER questions ("the people who picked 'no one to go with'
# also rate their club lowest"), which a per-question call cannot make because
# it has only its own tallies. The whole digest goes in once and the model
# reads every question against the rest of the deck.
#
# BY INDEX, NOT BY PROSE. The tool returns {index, insight} pairs rather than
# a document to be split up, because a reading filed against the wrong chart
# is worse than no reading: it is confidently wrong, in the creator's own
# words, under their own question. An index outside the deck is dropped, the
# same discipline OpenTextThemer uses for quotes.
#
# THE FRAMEWORK GOES IN. Where a card carries the editor's Why tagging
# (competency / condition / outcome — Playverto's reading of the OECD "Acting
# in the world" sequence, see config/competencies.yml), it is put in the
# prompt with the tallies. A question tagged Agency asks a different thing of
# its numbers than one tagged Awareness, and the reading should know that —
# "agency is low here, and belonging looks like the reason" is the sentence
# the taxonomy exists to make possible. Untagged cards are read on their
# numbers alone, which is most decks: the tagging only exists on cards that
# came through the generator or were optimised.
class QuestionInsights
  include AnthropicHelpers
  include FormatsResultsDigest

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 4000

  # Below this, a "reading" is a description of three people. The results page
  # already withholds a segment under MIN_DEMOGRAPHIC_SAMPLE for the same
  # reason; this is the same judgement applied to prose.
  MIN_ANSWERS = 5

  SYSTEM = <<~PROMPT.freeze
    You are an expert survey analyst. You will be given the aggregated results
    of a survey, question by question, and you must write ONE short reading for
    each question: what this question's answers actually tell the person who
    asked it.

    For each question:
      - 1-3 sentences. Under 55 words. No markdown, no bullets, no headers.
      - Lead with what is true, not with what was asked. "Cost and distance
        split the field almost evenly" beats "This question asked about
        barriers".
      - Cite the real numbers. A reading with no percentage in it is a guess.
      - Say what is SURPRISING where something is, and say plainly when nothing
        is: "no clear front-runner" is a finding.
      - You may read one question against another where the deck supports it —
        that is often the most useful thing you can say.
      - Never recommend an action. The creator decides what to do; you say what
        the numbers show.

    Some questions carry a framework tag — Awareness, Intention or Agency, and
    sometimes an enabling condition such as Belonging or Wellbeing. Where a tag
    is given, read the numbers against what that tag is measuring. Where none
    is given, do not invent one and do not mention the framework at all.

    Skip any question whose answers are too few to read honestly. Returning
    nothing for a question is correct and expected; a padded reading is not.

    Output via the emit_insights tool.
  PROMPT
  SYSTEM_WITH_SAFETY = (SYSTEM + PromptSafety::INSTRUCTION).freeze

  TOOL = {
    name: "emit_insights",
    description: "Return one short reading per question, keyed by the question's index.",
    input_schema: {
      type: "object",
      properties: {
        insights: {
          type: "array",
          description: "One entry per question worth reading. Omit questions with too few answers.",
          items: {
            type: "object",
            properties: {
              index: { type: "integer",
                       description: "The question's index, exactly as given in the digest (Q1 is index 0)." },
              insight: { type: "string",
                         description: "1-3 sentences, under 55 words, citing real numbers." }
            },
            required: %w[index insight]
          }
        }
      },
      required: %w[insights]
    }
  }.freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # => { "8" => "Two thirds say cost…", "12" => "…" }
  #
  # String keys, because this is stored as JSON and read back as JSON; an
  # integer key would come back a string anyway and the two would drift.
  def call(survey:, aggregated:, total:)
    return {} if total.to_i < MIN_ANSWERS

    readable = aggregated.each_with_index.select { |r, _| readable?(r) }
    return {} if readable.empty?

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SYSTEM_WITH_SAFETY,
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "emit_insights" },
      messages:    [ { role: "user", content: build_prompt(survey, aggregated, total) } ]
    )
    log_usage("QuestionInsights", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    return {} unless block

    resolve(deep_stringify(input_of(block))["insights"], aggregated.size)
  end

  private

  # A question with nothing to read. contact_form is excluded for the reason
  # the digest already withholds it — the answers are identifying data and
  # never reach a prompt, so there is nothing for a reading to be about.
  def readable?(result)
    CardTypes.question?(result[:type]) &&
      result[:type] != "contact_form" &&
      result[:total].to_i >= MIN_ANSWERS
  end

  # An index outside the deck is dropped rather than clamped. Clamping would
  # file a reading against a question it was not written about, which is the
  # one failure this whole shape exists to prevent.
  def resolve(insights, card_count)
    Array(insights).each_with_object({}) do |entry, out|
      idx = entry["index"]
      next unless idx.is_a?(Integer) && idx >= 0 && idx < card_count

      text = entry["insight"].to_s.strip
      next if text.empty?

      out[idx.to_s] = text
    end
  end

  # The digest every other results AI reads, plus the framework tagging it does
  # not carry. Appended as its own block rather than folded into
  # FormatsResultsDigest: the summariser and the report write prose for a
  # reader who never sees a competency badge, and giving them the vocabulary
  # would invite them to use it.
  def build_prompt(survey, aggregated, total)
    [ results_digest(survey, aggregated, total), framework_block(aggregated) ].compact.join("\n")
  end

  def framework_block(aggregated)
    lines = aggregated.each_with_index.filter_map do |result, idx|
      card = result[:card]
      next unless card.is_a?(Hash) && CardTypes.question?(result[:type])

      parts = []
      parts << "competency: #{Framework.competency(card['competency'])['label']}" if Framework.competency?(card["competency"])
      parts << "condition: #{Framework.condition(card['condition'])['label']}"    if Framework.condition?(card["condition"])
      parts << "asked in order to learn: #{card['outcome']}"                      if card["outcome"].present?
      next if parts.empty?

      "Q#{idx + 1} — #{parts.join('; ')}"
    end
    return nil if lines.empty?

    ([ "", "Framework tagging (only for the questions listed):" ] + lines).join("\n")
  end
end
