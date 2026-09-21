# Everything the platform holds about one respondent, for a GDPR subject access
# request (Article 15 / 20), plus the erasure that answers Article 17.
#
# Deliberately NOT built on ResultsExport. That produces the creator's analysis
# view — one row per respondent, one column per question, question columns only.
# A subject access request has to be *complete*: the demographics, the consent
# record, the derived region, the device and language, the timings and the quiz
# and token scoring all count as data held about that person, and none of them
# appear in the results export.
#
# Respondents are found by session token or, where the creator enabled
# respondent codes, by the code itself — which is matched against its HMAC
# digest, since the plaintext is never stored. A respondent who has neither
# cannot be identified: the session token lives in sessionStorage and is gone
# once the tab closes. That limit is real and documented in
# docs/DATA_RETENTION.md rather than papered over.
class RespondentDataExport
  class << self
    # Responses belonging to one respondent of `survey`. A respondent code can
    # match SEVERAL rows — that's the point of the feature, it links a person
    # across waves — so this always returns a relation.
    def lookup(survey:, session_token: nil, respondent_code: nil, email_address: nil)
      if respondent_code.present?
        digest = survey.respondent_code_digest(respondent_code)
        return survey.responses.none if digest.blank?

        survey.responses.where(respondent_code_digest: digest)
      elsif session_token.present?
        survey.responses.where(session_token: session_token.to_s.strip)
      elsif email_address.present?
        # The third axis, and the only one that starts from a name rather than
        # from something the respondent has to still be holding: a Player who
        # kept this Verto at the end of it. Scoped to THIS survey's claims —
        # the creator is the data controller for their own Verto, not for the
        # others in that person's account.
        player = Player.find_by(email_address: email_address.to_s.strip.downcase)
        return survey.responses.none if player.nil?

        # An id subquery rather than a join, because CI runs this suite on
        # Postgres too and DISTINCT over rows carrying a json column is a 500
        # there (see CLAUDE.md).
        survey.responses.where(id: player.player_claims.where(survey_id: survey.id).select(:response_id))
      else
        survey.responses.none
      end
    end

    def call(survey:, responses:)
      new(survey: survey, responses: responses).call
    end
  end

  def initialize(survey:, responses:)
    @survey    = survey
    @responses = responses
  end

  def call
    {
      "verto"      => { "title" => @survey.title.presence || @survey.theme.presence, "id" => @survey.id },
      "exported_at" => Time.current.utc.iso8601,
      "notes"      => [
        "This file contains every field stored about this respondent.",
        "Answers are keyed by the question they were given, in the order shown.",
        "A respondent code is stored only as a one-way hash and cannot be reversed.",
        "An account section appears only where this respondent kept this Verto to a " \
        "Playverto account. Erasure here removes this Verto from that account; the " \
        "other Vertos in it belong to their own creators, and the account holder " \
        "deletes the account itself from /you."
      ],
      "responses"  => @responses.map { |r| response_hash(r) },
      # The contact register entry for the same identity, when the Verto
      # collects one. Article 15 asks for EVERYTHING held about the person —
      # the contact row lives apart from the responses precisely so answers
      # stay pseudonymous, but it is still their data and belongs in their
      # export. Reached the same way the leaderboard alias is: through the
      # responses' player_key_digest.
      "contact_details" => contact_hashes.presence,
      # The respondent account that kept this Verto, where there is one. Their
      # address is data we hold about them and Article 15 asks for everything —
      # and unlike every other field here it is a name rather than a digest, so
      # it is also the thing an access request is most likely to be ABOUT.
      "account" => account_hash
    }.compact
  end

  def account_hash
    claims = PlayerClaim.where(survey_id: @survey.id, response_id: @responses.map(&:id))
                        .includes(:player)
    return nil if claims.empty?

    player = claims.first.player
    {
      "email_address"    => player&.email_address,
      "email_verified"   => player&.email_verified?,
      "kept_this_verto"  => claims.map { |c| c.claimed_at&.utc&.iso8601 }.compact,
      "vertos_in_account" => player&.player_claims&.count
    }.compact
  end

  def contact_hashes
    digests = @responses.map(&:player_key_digest).compact.uniq
    return [] if digests.empty?

    @survey.contact_details.where(key_digest: digests).map do |c|
      ContactDetail::FIELDS.index_with { |f| c[f] }.compact
        .merge("added_at" => c.created_at.utc.iso8601)
    end
  end

  private

  def response_hash(response)
    {
      "response_id"    => response.id,
      "session_token"  => response.session_token,
      "status"         => response.status,
      "started_at"     => response.started_at&.utc&.iso8601,
      "completed_at"   => response.completed_at&.utc&.iso8601,
      "created_at"     => response.created_at.utc.iso8601,
      "duration_seconds" => response.duration_seconds,
      "language"       => response.locale,
      "device"         => response.device_kind,
      "demographics"   => {
        "birth_year" => response.demographic_birth_year,
        # The band, as the words the person actually picked rather than the
        # key they are stored under — this is the export someone reads about
        # themselves, and "16_17" is storage, not an answer.
        "age_band"   => DemographicQuestions.age_band_label(response.demographic_age_band),
        "gender"     => response.demographic_gender,
        "region"     => response.region_label,
        "country"    => response.region_country,
        "heritage"   => response.demographic_heritage,
        # Unpacked from the pipe-wrapped storage for the human reading their
        # own subject-access export.
        "neurodiversity" => response.demographic_neurodiversity&.split("|")&.reject(&:empty?)
      }.compact,
      "consent"        => {
        "agreed_at"   => response.consent_agreed_at&.utc&.iso8601,
        "declined_at" => response.consent_declined_at&.utc&.iso8601,
        "agreed_to"   => response.consent_text_snapshot
      }.compact,
      "respondent_code" => respondent_code_note(response),
      "scoring"        => scoring(response),
      "answers"        => answers(response),
      "held_answers"   => held_answers(response).presence
    }.compact
  end

  # Free text of theirs that moderation is holding, or has removed: it is
  # still their personal data while the platform holds a copy, so a subject
  # access export includes it, with where it stands. Rows whose text has been
  # blanked by the sweep are omitted — there is nothing left to give.
  def held_answers(response)
    response.held_texts.where.not(text: nil).order(:id).map do |held|
      { "question" => held.question,
        "text"     => held.text,
        "status"   => held.status,
        "held_at"  => held.created_at.utc.iso8601 }.compact
    end
  end

  def respondent_code_note(response)
    return nil if response.respondent_code_digest.blank?

    { "linked" => true,
      "note"   => "Stored as a one-way hash so the code itself is not held. " \
                  "It links this person's responses to this Verto only." }
  end

  def scoring(response)
    data = {}
    data["quiz_score"]   = response.score     if response.score.present?
    data["quiz_max"]     = response.quiz_max  if response.quiz_max.present?
    data["token_totals"] = response.token_totals if response.token_totals.present?
    data.presence
  end

  # Answers are stored keyed by CARD INDEX, so they're only meaningful next to
  # the deck. Emitted with the question text so the file makes sense to the
  # person receiving it rather than being a bag of numbered values.
  def answers(response)
    stored = response.answers
    return [] unless stored.is_a?(Hash)

    Array(@survey.cards).each_with_index.filter_map do |card, index|
      next unless card.is_a?(Hash)

      answer = stored[index.to_s]
      next unless answer.is_a?(Hash)

      value = answer["value"]
      next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      { "question" => card["text"].to_s,
        "type"     => card["type"].to_s,
        "answer"   => value,
        "other"    => answer["other"].presence }.compact
    end
  end
end
