require "test_helper"

class SurveyDuplicateTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like it?", "options" => [ "Yes", "No" ] }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "dup-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "dup-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "duplicating a draft creates another draft with (Copy) appended" do
    draft = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))

    assert_difference -> { @org.surveys.count }, 1 do
      post duplicate_survey_path(draft)
    end

    copy = @org.surveys.order(:id).last
    assert_redirected_to survey_path(copy)
    assert_not copy.published?
    assert_equal "T (Copy)", copy.title
    # The theme is what respondents see (tab title, link preview, the tile's
    # big line), so it carries no "(Copy)" — the title above is the creator's
    # marker, and the dashboard shows it under the theme when they differ.
    assert_equal "Theme", copy.theme
    # Card content is copied verbatim; only the stable cids are freshly minted.
    assert_equal CARDS, copy.cards.map { |c| c.except("cid") }
    assert(copy.cards.all? { |c| c["cid"].to_s.start_with?("c_") })
  end

  # The reported bug. A copy's theme used to carry "(Copy)" into everything a
  # respondent sees — the tab title, the link preview — and nothing could take
  # it off, so a creator who copied a Verto and sent its test link out was
  # sending "(Copy)" with it.
  test "a copy's test link carries no (Copy): the theme is the name respondents see" do
    original = @org.surveys.create!(title: "Sports check", theme: "Sports", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))
    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last
    assert_equal "Sports check (Copy)", copy.title, "the creator's own name still says which tile is the copy"

    post test_link_survey_path(copy)
    token = copy.reload.test_token
    assert token.present?, "minting must store a token"
    delete session_path

    get test_survey_path(token)
    assert_response :success
    assert_select "head title", "Sports · Playverto"
    assert_select "meta[property='og:title'][content=?]", "Sports · Playverto"
    assert_select "meta[property='og:image:alt'][content=?]", "Sports · Playverto"
  end

  test "duplicating regenerates cids and remaps branching routes to the copy's cards" do
    cards = [
      { "type" => "multiple_choice", "cid" => "c_src_a", "text" => "Hub?", "options" => %w[UK US],
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_src_b" } }
        ], "default" => { "card" => "c_src_b" } } },
      { "type" => "open_ended", "cid" => "c_src_b", "text" => "UK page" }
    ]
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], logic: true, cards: cards)

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    assert copy.logic?
    src_cids  = original.cards.map { |c| c["cid"] }
    copy_cids = copy.cards.map { |c| c["cid"] }
    assert_empty(copy_cids & src_cids, "copy must not reuse any source cid")

    # The route now points at the COPY's second card, not the original's.
    route_target = copy.cards.first.dig("logic", "routes", 0, "to", "card")
    assert_equal copy.cards.second["cid"], route_target
    assert_equal copy.cards.second["cid"], copy.cards.first.dig("logic", "default", "card")
  end

  test "duplicating copies flows and remaps a flow's card exit to the copy's cids" do
    cards = [
      { "type" => "multiple_choice", "cid" => "c_hub", "text" => "Region?", "options" => %w[UK Other],
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_uk1" } }
        ] } },
      { "type" => "open_ended", "cid" => "c_uk1", "text" => "UK Q", "flow_id" => "f_uk", "next" => { "card" => "c_tail" } },
      { "type" => "open_ended", "cid" => "c_tail", "text" => "Tail" }
    ]
    flows = [ { "id" => "f_uk", "name" => "UK", "color" => "#8B85FF", "exit" => { "card" => "c_tail" } } ]
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], logic: true,
                                     cards: cards, flows: flows)

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    assert_equal 1, copy.flows_list.size
    flow = copy.flows_list.first
    assert_equal %w[f_uk UK], [ flow["id"], flow["name"] ], "flow identity copies verbatim (survey-scoped ids)"
    assert_equal "f_uk", copy.cards.second["flow_id"], "membership copies verbatim"
    # The exit points at the COPY's tail card, which has a fresh cid.
    assert_equal copy.cards.third["cid"], flow.dig("exit", "card")
    refute_equal "c_tail", flow.dig("exit", "card")
  end

  test "duplicating a live Verto lands the copy in Drafts" do
    live = @org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                 publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post duplicate_survey_path(live)
    copy = @org.surveys.order(:id).last

    assert copy.id != live.id
    assert_nil copy.publish_token
    assert_nil copy.published_at
    assert_nil copy.slug
    assert_not copy.published?
  end

  test "the copy's cards are independent of the source's" do
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    copy.cards.first["title"] = "mutated"
    original.reload
    assert_equal "hi", original.cards.first["title"]
  end

  test "the leaderboard settings are copied" do
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                     tokenisation_enabled: true,
                                     token_types: [ { "id" => "gold", "name" => "Gold", "icon" => "🪙" } ],
                                     leaderboard_enabled: true, leaderboard_retake_policy: "no_redo",
                                     leaderboard_rank_by: "gold",
                                     no_going_back: true, no_retests: true)

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    assert copy.leaderboard_enabled?, "duplicate! must carry the new columns or Duplicate silently drops them"
    assert_equal "no_redo", copy.leaderboard_retake_policy
    assert_equal "gold", copy.leaderboard_rank_by
    assert copy.no_going_back?, "a play rule is part of the instrument's design"
    assert copy.no_retests?
  end

  # ── Languages a copy claims ────────────────────────────────────────────────

  # The reported bug, from a live study. The Verto was a copy of a copy, its
  # locales said English and Spanish, and the language switcher duly offered
  # Spanish and turned every button and platform message Spanish — while every
  # question stayed in English, because no card had ever been given a Spanish
  # entry and duplicating enqueued nothing to give it one.
  test "a copy is translated into the languages it claims but has no words for" do
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: %w[en es fr], cards: CARDS.map(&:dup))

    assert_enqueued_jobs 2, only: TranslateLocalesJob do
      post duplicate_survey_path(original)
    end

    copy = @org.surveys.order(:id).last
    assert_equal %w[es fr], copy.locales_awaiting_translation,
                 "the copy offers both and can serve neither, so both are asked for"
    # A row per language, so the Language check rail says what is happening
    # rather than showing a bare 0/2 nobody can interpret.
    assert_equal %w[es fr], SurveyTranslation.where(survey: copy).order(:locale).pluck(:locale)
  end

  # The common case, and the one that must stay free: the deck is copied
  # verbatim with its i18n intact, so there is nothing to ask for and no Claude
  # call to pay for.
  test "a copy of an already translated Verto asks for nothing" do
    translated = CARDS.map do |c|
      c.merge("i18n" => { "es" => { "text" => "es:#{c['text']}", "title" => "es:#{c['title']}" }.compact })
    end
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: %w[en es], cards: translated)

    assert_no_enqueued_jobs only: TranslateLocalesJob do
      post duplicate_survey_path(original)
    end

    copy = @org.surveys.order(:id).last
    assert_empty copy.locales_awaiting_translation
    assert_equal "es:Like it?", copy.cards.last.dig("i18n", "es", "text"),
                 "the copy carries the original's Spanish rather than re-earning it"
  end

  # Half-landed is still missing. A run that translated some cards and stopped
  # leaves the rest reading in English, and a copy of that deck has to finish
  # the job rather than inherit the gap.
  test "a partly translated deck is finished off in the copy" do
    half = CARDS.map(&:dup)
    half[0] = half[0].merge("i18n" => { "es" => { "title" => "es:hi" } })
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: %w[en es], cards: half)

    assert_enqueued_jobs 1, only: TranslateLocalesJob do
      post duplicate_survey_path(original)
    end
    assert_equal [ "es" ], @org.surveys.order(:id).last.locales_awaiting_translation
  end

  test "a single-language copy asks for nothing" do
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))

    assert_no_enqueued_jobs only: TranslateLocalesJob do
      post duplicate_survey_path(original)
    end
  end

  test "results-report columns are not copied" do
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                     results_summary: "some summary", results_summary_response_count: 5,
                                     results_report: "some report", results_report_response_count: 5,
                                     results_report_brief: '{"goal":"x"}')

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    assert_nil copy.results_summary
    assert_nil copy.results_summary_response_count
    assert_nil copy.results_report
    assert_nil copy.results_report_response_count
    assert_nil copy.results_report_brief
  end

  test "another org's survey is not reachable" do
    other = Organisation.create!(name: "X", slug: "dup2-#{SecureRandom.hex(2)}")
    s2 = other.surveys.create!(title: "S2", theme: "t", audience_age: "all",
                                key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
    post duplicate_survey_path(s2)
    assert_response :not_found
  end

  test "dashboard renders a Duplicate button for both drafts and live Vertos" do
    draft = @org.surveys.create!(title: "D", theme: "D", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])
    live  = @org.surveys.create!(title: "L", theme: "L", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [],
                                  publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get root_path
    assert_response :success
    assert_match duplicate_survey_path(draft), response.body
    assert_match duplicate_survey_path(live), response.body
  end
end
