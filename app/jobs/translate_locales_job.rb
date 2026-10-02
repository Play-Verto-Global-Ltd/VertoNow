# Fills in the i18n entries for languages ADDED to an existing Verto — from the
# editor's Language settings, or from the Language check screen's rail. The
# after-the-fact twin of the translation pass BuildVertoJob runs at creation.
#
# ONE LOCALE PER JOB, and the deck is written as soon as that locale is done.
#
# It used to take every added locale in a single job and write the whole deck
# once at the end. That was survivable while the only way to add a language was
# the editor's checkbox list, one or two at a time. The Language check rail
# invites a creator to tick six at once, which turned a 40-second run into a
# 4-6 minute one — and every failure mode in that window was all-or-nothing:
#
#   * the digest guard compares against a fingerprint taken BEFORE the first
#     call, so any deck change in those minutes (an autosave from an open
#     editor tab, another session, FinishVertoSetupJob) dropped every language
#     in the run, including the five that had already succeeded;
#   * jobs run as threads inside Puma on a 512MB instance with a memory
#     watchdog that re-execs the process at 90% (config/puma.rb, render.yaml),
#     so a restart mid-run lost the lot;
#   * discard_on StandardError meant any error outside the per-locale rescue
#     ended the run with no retry and nothing written.
#
# Splitting by locale makes each unit ~40 seconds and independently durable:
# Turkish failing cannot cost you Spanish, and a restart loses at most the
# language that was in flight. SurveyTranslation records what happened, so the
# screen can say "failed, retry" instead of showing "Translating…" for ever.
class TranslateLocalesJob < ApplicationJob
  queue_as :default

  # Retry rather than discard. A Claude call fails for transient reasons far
  # more often than permanent ones, and the old discard turned a blip into a
  # language that silently never arrived.
  retry_on StandardError, wait: :polynomially_longer,
           attempts: SurveyTranslation::MAX_ATTEMPTS do |job, error|
    survey_id, locales = job.arguments
    ErrorReporting.report("TranslateLocalesJob", error, survey_id: survey_id)
    Array(locales).each do |loc|
      SurveyTranslation.find_by(survey_id: survey_id, locale: loc)
                       &.failed!(error.message, retryable: false)
    end
  end

  # `locales` stays an Array for the callers (and the jobs already enqueued
  # against the old signature) that pass several. Each becomes its own job, so
  # a six-language request is six independent units of work.
  #
  # `cids` re-translates those cards whether or not they already have words in
  # the language — the Language check screen's Re-translate, for lines whose
  # original has been rewritten since. Without it, only cards with no entry at
  # all are asked for, which can never repair a stale one.
  def self.enqueue_for(survey, locales, cids: nil)
    Array(locales).each do |locale|
      SurveyTranslation.enqueue!(survey, locale)
      cids.nil? ? perform_later(survey.id, [ locale ]) : perform_later(survey.id, [ locale ], Array(cids).map(&:to_s))
    end
  end

  # Every exit from here leaves each locale's row saying something TRUE.
  #
  # The first cut of this returned early — no survey, or the locale no longer
  # on the Verto — and left the row it had just created sitting at "queued".
  # The rail reads that as "Translating…", so a language that was never going
  # to be translated advertised itself as in progress indefinitely: the exact
  # symptom this rewrite existed to remove, reintroduced one layer up. A row
  # nobody will ever come back for has to be closed by whoever walks away
  # from it.
  def perform(survey_id, locales, cids = nil)
    asked  = SupportedLocales.sanitize_list(locales, fallback: [])
    survey = Survey.find_by(id: survey_id)

    unless survey
      # Nothing to translate into and nothing to translate — close the rows so
      # they cannot outlive the Verto they describe.
      SurveyTranslation.where(survey_id: survey_id, locale: asked)
                       .find_each { |r| r.failed!("this Verto no longer exists", retryable: false) }
      return
    end

    wanted  = asked & survey.secondary_locales
    dropped = asked - wanted
    dropped.each do |locale|
      SurveyTranslation.find_by(survey_id: survey.id, locale: locale)
                       &.failed!("this Verto is no longer offered in that language", retryable: false)
    end

    wanted.each { |locale| translate_one(survey, locale, cids) }
  end

  private

  # One language, written the moment it is ready.
  #
  # The digest is taken immediately before the write rather than at the top of
  # the run, so the window in which a concurrent save can cost this language is
  # the length of its own Claude call and nothing more. A deck that did move is
  # still not overwritten — that guarantee is the point of the guard — but now
  # only the language in flight is lost, and its row says so.
  def translate_one(survey, locale, cids = nil)
    row = SurveyTranslation.find_or_initialize_by(survey_id: survey.id, locale: locale)
    row.save! if row.new_record?
    row.running!

    survey.reload
    cards = Array(survey.cards)
    # Per CARD, not per locale. The old all-or-nothing skip meant a run that
    # half-landed could never be repaired: every card had *an* entry, so
    # re-ticking the language skipped it for ever. Asking only for the cards
    # that are actually missing one makes a retry finish the job.
    missing = if cids
      wanted = cids.map(&:to_s)
      cards.each_index.select { |i| cards[i].is_a?(Hash) && wanted.include?(cards[i]["cid"].to_s) }
    else
      # Missing, or holding only the original's words — what a translation
      # call that ran out of room used to store. See LanguageCheckLines.
      cards.each_index.select { |i| LanguageCheckLines.needs_translation?(cards[i], locale, survey.default_locale) }
    end
    if missing.empty?
      return row.done!
    end

    subset     = missing.map { |i| cards[i] }
    translated = SurveyTranslator.new.call(cards: subset, target_locale: locale,
                                           source_locale: survey.default_locale,
                                           notes: LanguageCheck.translator_notes_for(survey),
                                           fresh: !cids.nil?)
    merged = Survey.merge_card_translations(subset, locale, translated)

    filled = cards.dup
    missing.each_with_index { |card_index, j| filled[card_index] = merged[j] }

    digest = VertoGeneration.cards_digest(survey)
    if VertoGeneration.write_cards_if_unchanged!(survey, filled, digest, bump_translations: true)
      # Revision-stamped, so an editor tab open since before this run carries
      # these lines forward instead of autosaving them away — that is how a
      # Try again could appear to work and then quietly undo itself.
      LanguageCheck.record_translated!(
        survey.id, LanguageCheckLines.translated_pairs(missing.map { |i| filled[i] }, [ locale ]),
        revision: survey.translations_revision
      )
      row.done!
    else
      # The deck moved under this language. Not an error — the guard did its
      # job — but it is not done either, so it goes back in the queue.
      row.failed!("the deck changed while this language was being translated", retryable: true)
      raise ActiveRecord::StaleObjectError.new(survey, "translate")
    end
  rescue ActiveRecord::StaleObjectError
    raise
  rescue => e
    ErrorReporting.report("TranslateLocalesJob locale", e, locale: locale, survey_id: survey.id)
    row&.failed!(e.message, retryable: true)
    raise
  end
end
