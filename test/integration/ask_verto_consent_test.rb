require "test_helper"

# The consent gate, walked end to end through the real HTTP surfaces.
#
# CorpusEntryTest proves the rule at the model. This proves the routes, the
# controllers and the staff constraint actually enforce it — that a creator can
# offer and withdraw, that VertoNow can approve and decline, and that the two
# halves never accidentally become one.
class AskVertoConsentTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @user = User.create!(name: "Creator", email_address: "avc-#{SecureRandom.hex(3)}@test.com",
                         password: PASSWORD)
    @org  = Organisation.create!(name: "Anglo American Foundation", slug: "avc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Valparaíso Youth Pulse", theme: "Climate Action", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "c_w",
                 "text" => "How worried are you about climate change?",
                 "options" => [ "Very worried", "Not worried" ] } ]
    )
    40.times do |i|
      @survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                                answers: { "0" => { "value" => i < 30 ? "Very worried" : "Not worried" } })
    end
  end

  def sign_in(user = @user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  def entry = CorpusEntry.find_by(survey_id: @survey.id)

  # ── The happy path, one step at a time ────────────────────────────────────
  test "offer, approve, index, cite — then withdraw and it stops answering" do
    sign_in

    # Nothing is enrolled by existing.
    assert_nil entry
    assert_equal 0, CorpusTools.new.coverage[:vertos]

    # 1. The creator offers it.
    post survey_corpus_entry_path(@survey)
    assert_response :redirect
    assert entry.opted_in?
    assert_equal "pending", entry.review_status

    # Offered is not citable. This is the step it would be easiest to get wrong.
    assert_not entry.citable?
    assert_equal 0, CorpusTools.new.coverage[:vertos]

    # 2. VertoNow approves, which enqueues the index.
    with_staff do
      assert_enqueued_with(job: IndexCorpusEntryJob) do
        patch corpus_review_path(entry, decision: "approve")
      end
    end
    assert entry.reload.citable?

    # 3. Indexed, and now findable.
    perform_enqueued_jobs do
      IndexCorpusEntryJob.perform_now(entry.id)
    end
    assert_operator entry.reload.corpus_questions.count, :>, 0
    assert_equal 1, CorpusTools.new.coverage[:vertos]
    assert_equal 1, CorpusTools.new.call("search_corpus", { "query" => "climate" })[:questions].size

    # 4. The creator withdraws. It stops answering immediately — the index rows
    #    are still on disk, and that must not matter.
    delete survey_corpus_entry_path(@survey)
    assert entry.reload.withdrawn?
    assert_operator entry.corpus_questions.count, :>, 0, "the rows are still there…"
    assert_equal 0, CorpusTools.new.coverage[:vertos], "…and they must still not answer"
    assert_empty CorpusTools.new.call("search_corpus", { "query" => "climate" })[:questions]
  end

  test "a Verto under the sample floor is declined with a reason the creator can act on" do
    # The floor defaults to 10, the Privacy Notice's minimum group; this sets
    # 30 because what is being proved is that the review queue surfaces a
    # blocking check as a decline reason whatever floor a deployment sets, and
    # the fixture's 40 responses clear 10.
    CorpusEntry.min_sample_size = 30
    @survey.responses.limit(35).destroy_all
    sign_in
    post survey_corpus_entry_path(@survey)

    with_staff do
      get corpus_reviews_path
      assert_response :success
      # The blocking check is pre-filled as the decline reason, so the reviewer
      # doesn't have to write "no" in their own words.
      assert_match(/Fewer than #{CorpusEntry.min_sample_size} responses with answers/, response.body)

      patch corpus_review_path(entry, decision: "decline",
                               review_note: "Fewer than 30 completed responses.")
    end

    assert_equal "declined", entry.reload.review_status
    assert_equal "Fewer than 30 completed responses.", entry.review_note
    # The creator's yes survives our no.
    assert entry.opted_in?
  ensure
    CorpusEntry.min_sample_size = nil
    assert_equal :declined, entry.creator_state
  end

  test "answered-but-unfinished respondents count on the consent surfaces" do
    CorpusEntry.min_sample_size = 30
    # Everyone answered something; nobody reached the last card. The indexer
    # counts these (answered: true), so the queue's check must too — or the
    # queue shows a red FAIL for a Verto enrolment would index happily.
    @survey.responses.update_all(status: "started")
    sign_in
    post survey_corpus_entry_path(@survey)

    with_staff do
      get corpus_reviews_path
      assert_response :success
      assert_match(/Sample size · 40 responses with answers/, response.body)
    end
  ensure
    CorpusEntry.min_sample_size = nil
  end

  test "declining removes any rows the Verto already had" do
    sign_in
    post survey_corpus_entry_path(@survey)
    with_staff { patch corpus_review_path(entry, decision: "approve") }
    IndexCorpusEntryJob.perform_now(entry.id)
    assert_operator entry.reload.corpus_questions.count, :>, 0

    with_staff { patch corpus_review_path(entry, decision: "decline", review_note: "Not a fit.") }

    assert_equal 0, entry.reload.corpus_questions.count,
      "we said no — holding an index of it is holding data we decided not to use"
  end

  test "re-offering after a withdrawal goes back to the queue, not straight back in" do
    sign_in
    post survey_corpus_entry_path(@survey)
    with_staff { patch corpus_review_path(entry, decision: "approve") }
    delete survey_corpus_entry_path(@survey)

    post survey_corpus_entry_path(@survey)

    assert_equal "pending", entry.reload.review_status
    assert_not entry.citable?
  end

  test "the indexing job re-checks consent, so a withdrawal between approve and run wins" do
    sign_in
    post survey_corpus_entry_path(@survey)
    with_staff { patch corpus_review_path(entry, decision: "approve") }

    delete survey_corpus_entry_path(@survey)
    IndexCorpusEntryJob.perform_now(entry.id)

    assert_equal 0, entry.reload.corpus_questions.count
  end

  # ── The staff surface ─────────────────────────────────────────────────────
  test "a non-staff user gets a 404 from the review queue, not a 403" do
    sign_in

    get "/ask/review"
    assert_response :not_found,
      "the existence of an internal surface over other customers' data is itself not for customers"

    patch "/ask/review/1", params: { decision: "approve" }
    assert_response :not_found
  end

  test "a signed-out visitor gets a 404 from the review queue too" do
    get "/ask/review"
    assert_response :not_found
  end

  # ── The creator surface ───────────────────────────────────────────────────
  test "a member who is not an admin cannot offer the organisation's data" do
    member = User.create!(name: "M", email_address: "avm-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD)
    @org.memberships.create!(user: member, role: "member")
    sign_in(member)

    post survey_corpus_entry_path(@survey)

    assert_response :redirect
    assert_nil entry, "offering another org's researchers access to your respondents is an admin decision"
  end

  test "a creator cannot offer a Verto belonging to another organisation" do
    other_org = Organisation.create!(name: "Other", slug: "avo-#{SecureRandom.hex(3)}")
    other = other_org.surveys.create!(title: "Theirs", theme: "T", audience_age: "all",
                                      key_insight: "x", default_locale: "en", locales: [ "en" ], cards: [])
    sign_in

    post survey_corpus_entry_path(other)

    assert_response :not_found
    assert_nil CorpusEntry.find_by(survey_id: other.id)
  end

  test "withdrawing something never offered is a no-op, not an error" do
    sign_in
    delete survey_corpus_entry_path(@survey)
    assert_response :redirect
    assert_nil entry
  end

  # ── The product page ──────────────────────────────────────────────────────
  test "any signed-in account can open Ask Verto" do
    sign_in
    get ask_path
    assert_response :success
  end

  test "Ask Verto shows an empty corpus honestly rather than pretending" do
    sign_in
    get ask_path
    assert_response :success
    assert_match I18n.t("js.ask.empty_corpus")[0, 30], response.body
  end

  test "an org cannot query its own un-approved Verto through Ask Verto" do
    sign_in
    post survey_corpus_entry_path(@survey)   # offered, not approved

    assert_equal 0, CorpusTools.new.coverage[:vertos],
      "there is one corpus and one rule — owning the data does not widen it"
  end

  private

  # Staff are the BLAZER_STAFF_EMAILS allowlist, the same list that gates
  # /blazer. Nothing else distinguishes them.
  def with_staff
    original = ENV["BLAZER_STAFF_EMAILS"]
    ENV["BLAZER_STAFF_EMAILS"] = @user.email_address
    yield
  ensure
    ENV["BLAZER_STAFF_EMAILS"] = original
  end
end
