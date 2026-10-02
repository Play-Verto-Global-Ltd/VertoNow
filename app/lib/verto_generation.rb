# The build steps that turn a wizard submission into a finished Verto, in one
# place so the controller and BuildVertoJob run identical work.
#
# These used to be private methods on SurveysController, executed inline on a
# Puma request thread. They are the slow part of creation — a translation pass
# is one Claude call per secondary language, and asset population talks to
# Pexels — which is exactly why they moved to a job (P0-3).
module VertoGeneration
  module_function

  # Fill in every secondary language's i18n entries. Each locale is independent:
  # one failing translation leaves that language on the source text rather than
  # losing the whole deck, which is why the rescue is inside the loop.
  # `if_unchanged:` guards the write for callers that run AFTER the creator can
  # already be editing (FinishVertoSetupJob — an import's creator is in the editor
  # while this runs). Translation takes tens of seconds, so the deck can be saved
  # from under us in between; writing the pre-translation cards back would
  # silently undo that save. When the digest no longer matches we drop the
  # translations instead, which is the recoverable direction to fail in.
  #
  # BuildVertoJob passes nothing, because the wizard holds its creator on the wait
  # screen until the job finishes — there is nobody to race.
  def translate_survey!(survey, if_unchanged: nil)
    return unless survey.secondary_locales.any?

    cards  = Array(survey.cards)
    source = survey.default_locale
    survey.secondary_locales.each do |loc|
      translated = SurveyTranslator.new.call(cards: cards, target_locale: loc, source_locale: source)
      cards = Survey.merge_card_translations(cards, loc, translated)
    rescue => e
      ErrorReporting.report("SurveyTranslator", e, locale: loc)
    end

    written =
      if if_unchanged.nil?
        survey.update!(cards: cards, translations_revision: survey.translations_revision + 1)
      else
        write_cards_if_unchanged!(survey, cards, if_unchanged, bump_translations: true)
      end
    if written
      # What these translations were made FROM, and the revision they landed
      # at — the second is what stops an editor tab opened before them (an
      # import's creator is in the editor while this runs) autosaving them
      # away. See SurveysController#keep_reviewed_translations.
      LanguageCheck.record_translated!(
        survey.id, LanguageCheckLines.translated_pairs(survey.cards, survey.secondary_locales),
        revision: survey.translations_revision
      )
    end
    follow_up_untranslated!(survey.reload)
    written
  end

  # Whatever this pass did not finish — a language whose call failed, cards a
  # reply left out, or the whole deck when a save landed first and the guard
  # dropped everything — goes to TranslateLocalesJob, which asks only for the
  # cards still missing words and records its run. These used to end in an
  # error report nobody read and a language the creator had to notice was
  # English.
  def follow_up_untranslated!(survey)
    deck = Array(survey.cards)
    pending = survey.secondary_locales.select do |loc|
      deck.any? { |card| LanguageCheckLines.needs_translation?(card, loc, survey.default_locale) }
    end
    TranslateLocalesJob.enqueue_for(survey, pending) if pending.any?
  end

  # A stable fingerprint of a deck, for the guard above.
  def cards_digest(survey)
    Digest::SHA256.hexdigest(Array(survey.cards).to_json)
  end

  # Row-locked so the check and the write are one step — otherwise the creator's
  # autosave could land between them and be lost anyway.
  #
  # `bump_translations:` moves translations_revision in the same write, so an
  # editor tab rendered before it carries these translations forward instead
  # of writing its older copy back over them.
  def write_cards_if_unchanged!(survey, cards, expected_digest, bump_translations: false)
    survey.with_lock do
      survey.reload
      if cards_digest(survey) != expected_digest
        ErrorReporting.report("VertoGeneration.translate_survey! skipped",
                              StandardError.new("deck changed while translating"),
                              survey_id: survey.id)
        return false
      end
      attrs = { cards: cards }
      attrs[:translations_revision] = survey.translations_revision + 1 if bump_translations
      survey.update!(attrs)
    end
    true
  end

  # Translate a LOOSE array of cards (not yet attached to the survey) — what the
  # flow generator produces before the client splices it in. Same one-call-per-
  # locale shape as translate_survey!, and the same per-locale rescue, but it
  # returns the cards instead of saving them.
  #
  # Lives here rather than on SurveysController because GenerateFlowJob needs it
  # too, and a job reaching into controller privates is how the two drift apart.
  def translate_cards!(cards, survey)
    return cards unless survey.secondary_locales.any?

    survey.secondary_locales.each do |loc|
      translated = SurveyTranslator.new.call(cards: cards, target_locale: loc,
                                             source_locale: survey.default_locale)
      cards = Survey.merge_card_translations(cards, loc, translated)
    rescue => e
      ErrorReporting.report("SurveyTranslator cards", e, locale: loc)
    end
    cards
  end

  # Every new Verto opens with imagery rather than a blank editor. Best-effort:
  # a Pexels outage must not fail the creation, it just means an unillustrated
  # deck the creator can fill in themselves.
  #
  # Two shapes, because the two creation paths differ in one way that matters:
  # whether anyone else is writing to the deck at the same time.
  #
  #   wizard  — BuildVertoJob runs while its creator is held on the wait screen.
  #             Nobody else can write. Positional save, overwrite allowed.
  #   import  — FinishVertoSetupJob runs while its creator is already IN the
  #             editor. Both `merge:` (write by cid onto the live deck) and
  #             `fill_only:` (never overwrite imagery they have since chosen).
  def auto_populate_assets!(survey, fill_only: false, merge: false)
    extract_card_subjects!(survey)
    populator = AssetPopulator.new(survey, fill_only: fill_only)
    merge ? populator.populate_merged! : populator.populate!
  rescue => e
    ErrorReporting.report("AssetPopulator", e)
  end

  # Reaction animations for a LOOSE array of cards — a generated flow's, before
  # the client splices them in. See AssetPopulator#animate_cards! for why a
  # range card with no animation is not an unillustrated card but a repeated
  # one. Best-effort like every other pass here: cards back unchanged on any
  # failure, because a flow that generated is worth more than its animations.
  def animate_cards!(cards, survey)
    AssetPopulator.new(survey).animate_cards!(cards)
  rescue => e
    ErrorReporting.report("AssetPopulator flow", e)
    cards
  end

  # Names each question card's photographable subject (card["subject"]) BEFORE
  # populate! runs, so AssetPopulator#card_query can read it on this very
  # first pass — see CardSubjectExtractor for what it does and why a failure
  # here is invisible rather than fatal. Mutates survey.cards in memory only;
  # populate! (immediately after) is what actually saves, so the subject
  # stamps and the image picks land in the same write instead of two.
  #
  # Under `merge:` the in-memory stamp is still not what saves — the subjects
  # ride the computed picks and are carried onto the live deck by cid, because
  # `subject` is one of Survey::MEDIA_KEYS. Without that a later Shuffle would
  # have lost the anchor this pass paid Claude for.
  # Independently best-effort from populate! itself — one Pexels/Claude
  # outage must never take out the other.
  def extract_card_subjects!(survey)
    return unless CardSubjectExtractor.configured?
    survey.cards = CardSubjectExtractor.new.call(cards: survey.cards)
  rescue => e
    ErrorReporting.report("CardSubjectExtractor", e)
  end

  # Creator-facing failure text: the API's own message when Claude returned one
  # (rate limit, overloaded, bad key — all things the creator can act on), and
  # otherwise a bounded version of the exception.
  def friendly_error(e)
    api_msg = anthropic_api_message(e)
    return api_msg if api_msg.present?

    msg = e.message.to_s.strip
    msg = msg.first(200) + "…" if msg.length > 200
    msg.presence || "#{e.class.name.split('::').last}. Check the server logs."
  end

  def anthropic_api_message(e)
    return nil unless defined?(Anthropic::Errors::APIError) && e.is_a?(Anthropic::Errors::APIError)

    body = e.respond_to?(:body) ? e.body : nil
    return nil unless body.is_a?(Hash)

    # Both key shapes: the SDK hands back symbol keys, a re-parsed body strings.
    body.dig(:error, :message) || body.dig("error", "message")
  end
end
