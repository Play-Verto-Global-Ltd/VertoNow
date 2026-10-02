require "test_helper"

# The job that fills in a language's i18n entries after the Verto exists.
#
# Every test here is about DURABILITY rather than translation quality: what
# survives when one language fails, when the deck moves underneath, when the
# process dies mid-run, and whether a half-finished language can ever be
# repaired. Those are the ways a creator ends up staring at "Translating…"
# for ever, which is what this job was rewritten to stop.
class TranslateLocalesJobTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "T", slug: "t-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: %w[en es fr de],
      cards: [
        { "type" => "multiple_choice", "cid" => "c1", "text" => "Colour?", "options" => %w[Blue Green] },
        { "type" => "open_ended", "cid" => "c2", "text" => "Why?" }
      ]
    )
  end

  # Stand in for Claude: returns a plausible translation for every card it is
  # handed, or raises for locales named in `failing`.
  # stub_method treats a callable value as the REPLACEMENT IMPLEMENTATION, so a
  # translator double (which answers #call) has to be handed back from a lambda
  # rather than passed directly — otherwise SurveyTranslator.new invokes the
  # double instead of returning it.
  def translator_double(failing: [])
    fake = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:, **|
      raise "boom" if failing.include?(target_locale.to_s)
      Array(cards).map do |c|
        { "text" => "#{target_locale}:#{c['text']}",
          "options" => Array(c["options"]).map { |o| "#{target_locale}:#{o}" } }
      end
    end
    fake
  end

  def with_translator(failing: [], &block)
    fake = translator_double(failing: failing)
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { fake }, &block)
  end

  def entry(cid, locale)
    @survey.reload.cards.find { |c| c["cid"] == cid }&.dig("i18n", locale)
  end

  test "each language is written as soon as it is done, not at the end of the run" do
    # The heart of the fix. One job per locale, each persisting on its own.
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, %w[es fr de]) }
    end

    %w[es fr de].each do |loc|
      assert_equal "#{loc}:Colour?", entry("c1", loc)["text"], "#{loc} should have landed"
      assert_equal "done", SurveyTranslation.find_by(survey: @survey, locale: loc).status
    end
  end

  test "one language failing does not cost the languages that succeeded" do
    # The old job wrote once at the end, so anything that killed the run threw
    # away every language in it. This is the regression guard for that.
    with_translator(failing: [ "fr" ]) do
      perform_enqueued_jobs(except: ->(_) { false }) do
        TranslateLocalesJob.enqueue_for(@survey, %w[es fr de])
      end
    rescue StandardError
      # The French job exhausts its retries and re-raises; the others are
      # separate jobs and are unaffected.
    end

    assert_equal "es:Colour?", entry("c1", "es")["text"], "Spanish must survive a French failure"
    assert_equal "de:Colour?", entry("c1", "de")["text"], "German must survive a French failure"
    assert_nil entry("c1", "fr")
  end

  test "a failed language is recorded as failed, not left looking like it is still coming" do
    with_translator(failing: [ "fr" ]) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "fr" ]) } rescue StandardError
    end

    row = SurveyTranslation.find_by(survey: @survey, locale: "fr")
    assert_equal "failed", row.status,
                 "a creator is owed an answer, not an indefinite 'Translating…'"
    assert row.last_error.present?
  end

  test "a half-finished language is repaired by running it again" do
    # The old skip was all-or-nothing per locale: once every card had SOME
    # entry the language was skipped for ever, so a partial run could never be
    # completed. Now the job asks only for the cards that are missing one.
    cards = @survey.cards
    cards[0] = cards[0].merge("i18n" => { "es" => { "text" => "ya traducido", "options" => %w[Azul Verde] } })
    @survey.update!(cards: cards)

    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    assert_equal "ya traducido", entry("c1", "es")["text"], "an existing translation is left alone"
    assert_equal "es:Why?", entry("c2", "es")["text"], "the missing card is filled in"
  end

  test "a language already complete costs nothing and is marked done" do
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end
    before = @survey.reload.cards

    calls = 0
    counting = Object.new
    counting.define_singleton_method(:call) { |**| calls += 1; [] }
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { counting }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    assert_equal 0, calls, "re-translating a finished language would overwrite hand-edited wording"
    assert_equal before, @survey.reload.cards
    assert_equal "done", SurveyTranslation.find_by(survey: @survey, locale: "es").status
  end

  test "a deck that moved mid-translation loses only the language in flight" do
    # The guard still refuses to overwrite a concurrent save — that is the
    # point of it — but the blast radius is now one language, and its row says
    # what happened so it can be retried.
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end
    assert_equal "done", SurveyTranslation.find_by(survey: @survey, locale: "es").status

    moving = Object.new
    survey = @survey
    moving.define_singleton_method(:call) do |cards:, target_locale:, source_locale:, **|
      # Somebody saves the deck while Claude is working.
      survey.class.find(survey.id).update!(cards: survey.reload.cards + [
        { "type" => "open_ended", "cid" => "c3", "text" => "Late addition" }
      ])
      Array(cards).map { |c| { "text" => "fr:#{c['text']}", "options" => [] } }
    end

    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { moving }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "fr" ]) } rescue StandardError
    end

    assert_equal "es:Colour?", entry("c1", "es")["text"], "the finished language is untouched"
    assert_equal "Late addition", @survey.reload.cards.last["text"], "the concurrent save survives"
  end

  test "a deck that moves during a six-language run does not throw away the finished ones" do
    # THE regression this rewrite exists for. The old job took every locale in
    # one unit of work and wrote the deck once at the end, against a digest
    # taken before the first Claude call. Ticking several languages from the
    # rail made that window minutes long, so a single autosave anywhere in it
    # discarded every language in the run — including the ones that had already
    # come back. Now each language is its own job and persists on its own, so
    # the save costs at most the one in flight.
    survey = @survey
    seen = []
    shifty = Object.new
    shifty.define_singleton_method(:call) do |cards:, target_locale:, source_locale:, **|
      seen << target_locale.to_s
      if seen.size == 2
        # Somebody saves the deck while the SECOND language is being translated.
        Survey.find(survey.id).update!(cards: Survey.find(survey.id).cards + [
          { "type" => "open_ended", "cid" => "c_late", "text" => "Late addition" }
        ])
      end
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => [] } }
    end

    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { shifty }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, %w[es fr de]) }
    rescue StandardError
      nil
    end

    assert_equal "es:Colour?", entry("c1", "es")&.dig("text"),
                 "the language that finished BEFORE the save must survive it"
    assert_equal "Late addition", @survey.reload.cards.last["text"],
                 "and the concurrent save itself is never overwritten"
  end

  test "a locale the Verto does not carry is ignored" do
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "ja" ]) }
    end
    assert_nil entry("c1", "ja")
  end

  # ── Nothing is left claiming to be in progress ─────────────────────────────
  #
  # Every one of these leaves a row at "queued", which the rail renders as
  # "Translating…" — so each is a language that advertises itself as coming
  # and never arrives. That is the exact symptom this job was rewritten to
  # remove, and the first cut of the rewrite reintroduced it in perform's
  # early returns.

  test "a language the Verto no longer offers is closed, not left queued" do
    SurveyTranslation.enqueue!(@survey, "fr")
    @survey.update!(locales: %w[en es])   # French dropped before the job ran

    with_translator { perform_enqueued_jobs { TranslateLocalesJob.perform_later(@survey.id, [ "fr" ]) } }

    row = SurveyTranslation.find_by(survey: @survey, locale: "fr")
    assert_equal "failed", row.status, "a row nobody will come back for has to be closed by whoever walks away"
    assert_match(/no longer offered/, row.last_error)
  end

  test "a destroyed Verto takes its translation rows with it" do
    # The stronger guarantee, and the reason the job's own missing-survey guard
    # is belt to this braces: a foreign key means the rows cannot outlive the
    # Verto in the first place, so there is nothing left to report "Translating…"
    # about a Verto that no longer exists.
    SurveyTranslation.enqueue!(@survey, "es")
    id = @survey.id
    assert_equal 1, SurveyTranslation.where(survey_id: id).count

    @survey.destroy!
    assert_equal 0, SurveyTranslation.where(survey_id: id).count
  end

  test "a job for a Verto that is already gone exits without raising" do
    # Reachable only if the rows were removed out from under it — a raw delete,
    # a future schema change. It must not crash the worker.
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.perform_later(-1, [ "es" ]) }
    end
  end

  test "a language never asked for is not reported as in progress" do
    assert_nil SurveyTranslation.find_by(survey: @survey, locale: "de")
  end

  # ── The clock is the last honest reading ───────────────────────────────────

  test "a run abandoned by a dead process reads as failed once it goes stale" do
    # Nothing CLOSES this row: the process was re-execed mid-call, or the queue
    # entry was lost. No code path is left to write anything, so the only thing
    # that can tell the truth is how long it has been sitting there.
    row = SurveyTranslation.create!(survey: @survey, locale: "fr", status: "running",
                                     attempts: 1, started_at: 2.hours.ago)
    assert row.stale?
    assert_equal "failed", row.display_status, "the rail must stop believing it"
    assert_match(/longer than expected/, row.stalled_reason)
  end

  test "a run that is merely slow is still believed" do
    row = SurveyTranslation.create!(survey: @survey, locale: "fr", status: "running",
                                     attempts: 1, started_at: 30.seconds.ago)
    assert_not row.stale?
    assert_equal "running", row.display_status
    assert_nil row.stalled_reason
  end

  test "a queued row that no worker ever picked up eventually stops claiming to be coming" do
    row = SurveyTranslation.create!(survey: @survey, locale: "fr", status: "queued",
                                     attempts: 0, started_at: nil,
                                     created_at: 3.hours.ago, updated_at: 3.hours.ago)
    assert row.stale?, "started_at is nil when a job never ran — fall back to the row's own age"
    assert_equal "failed", row.display_status
  end

  test "a finished run never goes stale however old it is" do
    row = SurveyTranslation.create!(survey: @survey, locale: "fr", status: "done",
                                     finished_at: 1.year.ago, started_at: 1.year.ago)
    assert_not row.stale?
    assert_equal "done", row.display_status
  end

  test "asking again after a failure starts a fresh run rather than one already spent" do
    row = SurveyTranslation.create!(survey: @survey, locale: "fr", status: "failed",
                                     attempts: SurveyTranslation::MAX_ATTEMPTS,
                                     last_error: "boom")
    SurveyTranslation.enqueue!(@survey, "fr")
    row.reload
    assert_equal "queued", row.status
    assert_equal 0, row.attempts
    assert_nil row.last_error
  end

  # ── Re-translating, and remembering what from ──────────────────────────────

  test "a translation records the original it was made from" do
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    card   = @survey.reload.cards.first
    source = LanguageCheckLines.digest(LanguageCheckLines.canonical_content(card))
    row    = LanguageCheck.find_by(survey: @survey, cid: "c1", locale: "es")
    assert_equal source, row.translated_from_digest
    assert_equal "pending", row.status, "recording provenance is not a review decision"
  end

  test "named cards are translated again even though they already have words" do
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    seen = []
    fresh_flags = []
    again = Object.new
    again.define_singleton_method(:call) do |cards:, fresh: false, **|
      seen.concat(cards.map { |c| c["cid"] })
      fresh_flags << fresh
      cards.map { |c| { "text" => "again:#{c['text']}", "options" => Array(c["options"]) } }
    end
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { again }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ], cids: [ "c2" ]) }
    end

    assert_equal [ "c2" ], seen, "only the card asked for"
    assert_equal [ true ], fresh_flags, "a re-translate must not be answered with the line it replaces"
    assert_equal "again:Why?", entry("c2", "es")["text"]
    assert_equal "es:Colour?", entry("c1", "es")["text"]
    assert_equal "done", SurveyTranslation.find_by(survey: @survey, locale: "es").status
  end

  test "the author's notes go to the translator" do
    LanguageCheck.create!(survey: @survey, cid: "c2", locale: "en", translator_note: "why as in reason")
    notes_seen = nil
    noting = Object.new
    noting.define_singleton_method(:call) do |cards:, notes: {}, **|
      notes_seen = notes
      cards.map { |c| { "text" => "x", "options" => Array(c["options"]) } }
    end
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { noting }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    assert_equal({ "c2" => "why as in reason" }, notes_seen)
  end

  test "a language stored as the original's words is repaired by asking again" do
    @survey.update!(cards: @survey.cards.map do |c|
      c.merge("i18n" => { "es" => { "text" => c["text"], "options" => Array(c["options"]) } })
    end)

    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    assert_equal "es:Colour?", entry("c1", "es")["text"]
    assert_equal "es:Why?", entry("c2", "es")["text"]
  end

  # The shape of the third report: a Try again landed while an editor tab was
  # open on the same Verto, and the tab's next autosave — rebuilt from what it
  # loaded, which had no Spanish on those cards — deleted what the job wrote.
  test "a translation the job writes survives an autosave from an editor opened before it" do
    rendered_at = @survey.reload.translations_revision
    with_translator do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end
    assert_operator @survey.reload.translations_revision, :>, rendered_at

    stale_tab = @survey.cards.map { |c| c.except("i18n") }
    kept = Survey.keep_reviewed_translations(
      @survey.cards, stale_tab,
      LanguageCheck.where(survey: @survey).where("edit_revision > ?", rendered_at).pluck(:cid, :locale),
      primary: "en"
    )
    assert_equal "es:Colour?", kept.find { |c| c["cid"] == "c1" }.dig("i18n", "es", "text")
  end

  test "a card left with one field in English is asked for again" do
    @survey.update!(cards: @survey.cards.map do |c|
      c["cid"] == "c1" ? c.merge("i18n" => { "es" => { "text" => "¿Color?", "options" => [ "", "" ] } }) : c
    end)

    seen = []
    again = Object.new
    again.define_singleton_method(:call) do |cards:, **|
      seen.concat(cards.map { |c| c["cid"] })
      cards.map { |c| { "text" => "es:#{c['text']}", "options" => Array(c["options"]).map { |o| "es:#{o}" } } }
    end
    stub_method(SurveyTranslator, :new, ->(*_a, **_k) { again }) do
      perform_enqueued_jobs { TranslateLocalesJob.enqueue_for(@survey, [ "es" ]) }
    end

    assert_includes seen, "c1", "its options were never translated"
    assert_equal %w[es:Blue es:Green], entry("c1", "es")["options"]
  end
end
