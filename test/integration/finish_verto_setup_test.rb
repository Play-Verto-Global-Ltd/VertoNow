require "test_helper"

# An import's slow tail — translation, then imagery — used to run inline on a
# request thread at the end of create_imported_survey!. It's a job now.
#
# Unlike the wizard, an import's creator is NOT held on a wait screen: they land
# in the editor while this is still running, so the deck can be saved from under
# the job. The digest guard is what stops it writing a stale deck over that save.
class FinishVertoSetupTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "O", slug: "fvs-#{SecureRandom.hex(3)}")
  end

  def survey(locales: %w[en es])
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: locales,
                         cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Original?", "options" => %w[Yes No] } ])
  end

  # Translates by prefixing, so a merge is visible in the stored cards.
  def with_translator
    fake = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:, **|
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => Array(c["options"]) } }
    end
    SurveyTranslator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SurveyTranslator.singleton_class.remove_method(:new)
  end

  # Both writes, because the job takes the merged one and the wizard takes the
  # positional one — a stub that knows only about `populate!` would let the job
  # raise NoMethodError into auto_populate_assets!'s rescue and look like it had
  # simply chosen not to populate.
  def with_no_assets
    AssetPopulator.define_singleton_method(:new) do |*, **|
      Object.new.tap do |o|
        o.define_singleton_method(:populate!) { nil }
        o.define_singleton_method(:populate_merged!) { nil }
      end
    end
    yield
  ensure
    AssetPopulator.singleton_class.remove_method(:new)
  end

  # Records how AssetPopulator was constructed and which write was asked for.
  def recording_populator
    seen = {}
    AssetPopulator.define_singleton_method(:new) do |_survey, **kwargs|
      seen[:fill_only] = kwargs[:fill_only]
      Object.new.tap do |o|
        o.define_singleton_method(:populate!)        { seen[:write] = :positional }
        o.define_singleton_method(:populate_merged!) { seen[:write] = :merged }
      end
    end
    yield seen
  ensure
    AssetPopulator.singleton_class.remove_method(:new)
  end

  test "it translates a deck nobody has touched" do
    s = survey
    digest = VertoGeneration.cards_digest(s)

    with_translator do
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, digest) }
    end

    assert_equal "es:Original?", s.reload.cards.first.dig("i18n", "es", "text")
  end

  # The race the guard exists for: the creator saved an edit while the
  # translation calls were in flight. Writing back would undo it.
  #
  # The digest is taken by the job at the moment it starts translating, not at
  # the moment it was enqueued, so this is the only window it has to cover — and
  # it is the one that matters, because translation is the slow half (one Claude
  # call per secondary locale) while imagery is seconds.
  test "it declines to overwrite a deck edited while it was running" do
    s = survey

    # The edit lands DURING the translation call, which is the shape the guard
    # is for. Everything before that point the job now translates rather than
    # discards — see the test below.
    fake = Object.new
    fake.define_singleton_method(:call) do |cards:, target_locale:, source_locale:, **|
      s.update!(cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Creator's edit", "options" => %w[Yes No] } ])
      Array(cards).map { |c| { "text" => "#{target_locale}:#{c['text']}", "options" => Array(c["options"]) } }
    end
    SurveyTranslator.define_singleton_method(:new) { |*| fake }
    begin
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, VertoGeneration.cards_digest(s)) }
    ensure
      SurveyTranslator.singleton_class.remove_method(:new)
    end

    s.reload
    assert_equal "Creator's edit", s.cards.first["text"], "the creator's edit must survive"
    assert_nil s.cards.first.dig("i18n", "es"), "the translation is the thing dropped, not the edit"
  end

  # An edit made before the job reaches its translation step is no longer a
  # reason to throw the translation away. The job recomputes the digest against
  # the deck as it finds it, so the creator's own words get translated instead
  # of the stale ones being translated and then refused — which lost the
  # translation and gained nothing.
  test "an edit made before translation starts is translated, not discarded" do
    s = survey
    enqueued_digest = VertoGeneration.cards_digest(s)
    s.update!(cards: [ { "type" => "yes_no", "cid" => "c_1", "text" => "Creator's edit", "options" => %w[Yes No] } ])

    with_translator do
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, enqueued_digest) }
    end

    s.reload
    assert_equal "Creator's edit", s.cards.first["text"]
    assert_equal "es:Creator's edit", s.cards.first.dig("i18n", "es", "text"),
                 "the translation must be of what the deck says NOW"
  end

  test "with no digest it writes unconditionally, which is what the wizard needs" do
    s = survey
    with_translator do
      with_no_assets { VertoGeneration.translate_survey!(s) }
    end
    assert_equal "es:Original?", s.reload.cards.first.dig("i18n", "es", "text")
  end

  test "a single-locale deck needs no translation and no guard" do
    s = survey(locales: [ "en" ])
    before = s.cards
    with_translator do
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, VertoGeneration.cards_digest(s)) }
    end
    assert_equal before, s.reload.cards
  end

  test "a deleted survey is a no-op rather than a crash" do
    s = survey
    id = s.id
    digest = VertoGeneration.cards_digest(s)
    s.destroy!
    assert_nothing_raised { FinishVertoSetupJob.perform_now(id, digest) }
  end

  test "the digest changes with the deck and not with anything else" do
    s = survey
    before = VertoGeneration.cards_digest(s)

    s.update!(title: "Renamed")
    assert_equal before, VertoGeneration.cards_digest(s.reload), "a rename is not a deck change"

    s.update!(cards: s.cards + [ { "type" => "open_ended", "cid" => "c_2", "text" => "New" } ])
    assert_not_equal before, VertoGeneration.cards_digest(s.reload)
  end

  test "the import path populates fill-only, and merges rather than overwriting" do
    s = survey
    recording_populator do |seen|
      with_translator { FinishVertoSetupJob.perform_now(s.id, VertoGeneration.cards_digest(s)) }
      assert_equal true,    seen[:fill_only], "auto-population must never overwrite a creator's own imagery"
      assert_equal :merged, seen[:write],     "the creator is in the editor — a whole-deck write would undo their save"
    end
  end

  # This is the bug the reordering is for. The rescue inside translate_survey!
  # covers the SurveyTranslator call only; the update! after it is unguarded, so
  # a raise there used to propagate to discard_on and take the asset population
  # that had not run yet with it. Imagery goes first now, and each step has its
  # own rescue, so neither can cost the other.
  test "imagery survives a translation that raises" do
    s = survey

    boom = Object.new
    boom.define_singleton_method(:call) { |**| raise "translator down" }
    SurveyTranslator.define_singleton_method(:new) { |*| boom }
    begin
      recording_populator do |seen|
        assert_nothing_raised { FinishVertoSetupJob.perform_now(s.id, VertoGeneration.cards_digest(s)) }
        assert_equal :merged, seen[:write], "imagery must run whatever translation does"
      end
    ensure
      SurveyTranslator.singleton_class.remove_method(:new)
    end
  end

  # The flag is what keeps the editor polling and what keeps
  # SurveysController#update carrying imagery the client can't see yet. A job
  # that finished without clearing it would strand both until it went stale.
  test "the setup flag is cleared on the way out, however the job ends" do
    s = survey
    s.update!(setup_pending_since: Time.current)
    assert s.setup_pending?

    with_translator { with_no_assets { FinishVertoSetupJob.perform_now(s.id, VertoGeneration.cards_digest(s)) } }
    assert_nil s.reload.setup_pending_since

    s.update!(setup_pending_since: Time.current)
    boom = Object.new
    boom.define_singleton_method(:call) { |**| raise "translator down" }
    SurveyTranslator.define_singleton_method(:new) { |*| boom }
    begin
      with_no_assets { FinishVertoSetupJob.perform_now(s.id, VertoGeneration.cards_digest(s)) }
    ensure
      SurveyTranslator.singleton_class.remove_method(:new)
    end
    assert_nil s.reload.setup_pending_since, "a failing step must still close the window"
  end

  # A stale flag is not a permanent one: if the process dies before `ensure`
  # runs, the window closes on its own rather than leaving the editor polling
  # and #update merging forever.
  test "the setup window expires on its own" do
    s = survey
    s.update!(setup_pending_since: Survey::SETUP_STALE_AFTER.ago - 1.minute)
    assert_not s.setup_pending?
  end
end

# The cold-cache report generation is a Claude call on a request thread, and it
# was the one AI path with no bound at all — the streaming report has a slot pool,
# these two callers didn't. They share that pool now, but only on the cold branch.
class ReportGenerationBulkheadTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "rpt-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "rpt-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])
  end

  def drain_pool
    held = []
    held << true while LimitsConcurrentStreams::POOL.acquire
    held.size
  end

  def release_pool(n)
    n.times { LimitsConcurrentStreams::POOL.release }
  end

  test "a cold cache is refused rather than queued when no slot is free" do
    generated = false
    stub_method(ResultsReportGenerator, :call, ->(**) { generated = true; "# Report" }) do
      n = drain_pool
      begin
        get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
      ensure
        release_pool(n)
      end
    end

    assert_response :service_unavailable
    assert_not JSON.parse(response.body)["ok"]
    assert_not generated, "it must not start a Claude call it has no thread budget for"
  end

  # The reason the guard is on the branch and not the action: a cached report is
  # one column read, and must never wait behind someone else's generation.
  test "a warm cache is served even with every slot taken" do
    @survey.update_columns(results_report: "# Cached report", results_report_response_count: 0)

    n = drain_pool
    begin
      get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
    ensure
      release_pool(n)
    end

    assert_response :success
    assert_match "Cached report", JSON.parse(response.body)["body_html"]
  end

  test "the slot is released after a successful generation" do
    stub_method(ResultsReportGenerator, :call, ->(**) { "# Fresh" }) do
      get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
      assert_response :success
    end
    # Nothing leaked: the pool is whole again.
    n = drain_pool
    release_pool(n)
    assert_operator n, :>=, 1, "the slot came back"
  end

  test "the slot is released when generation raises" do
    stub_method(ResultsReportGenerator, :call, ->(**) { raise "boom" }) do
      get survey_results_report_path(@survey), headers: { "Accept" => "application/json" }
      assert_response :unprocessable_entity
    end
    n = drain_pool
    release_pool(n)
    assert_operator n, :>=, 1, "an exception must not leak the slot"
  end
end
