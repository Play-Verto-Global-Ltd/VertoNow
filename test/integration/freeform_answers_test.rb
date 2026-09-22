require "test_helper"

# Every answer to a freeform (open_ended) question, on the results page.
#
# The result card used to stop at twenty answers cut to 200 characters and a
# "+ N more" that led nowhere. Now the card previews the newest ten in full
# and offers "View all answers", whose panel pages through every one of them
# from SurveyTextAnswersController — newest first, within the segment and
# date range the page is showing, searchable. These cover the endpoint's
# contract and the two pages' halves of it; the panel itself is driven in
# test/system/freeform_answers_modal_test.rb.
class FreeformAnswersTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "open_ended",      "text" => "Why did you come?" },
    { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] },
    { "type" => "open_ended",      "text" => "Where do you live?", "demographic" => "location" },
    # Shaped like the real tail — `input` is what the answer sync and
    # DemographicQuestions.key_for actually read.
    { "type" => "open_ended", "text" => "Where do you really live?",
      "input" => "location", "demographic" => true },
    { "type" => "open_ended", "text" => "When were you born?",
      "input" => "month", "demographic" => true }
  ].freeze

  def setup
    @org   = Organisation.create!(name: "O", slug: "ff-#{SecureRandom.hex(3)}")
    @admin = make_user("admin")
    @org.memberships.create!(user: @admin, role: "admin")
    @survey = @org.surveys.create!(
      title: "FF", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      publish_token: SecureRandom.hex(8), published_at: Time.current
    )
    @link = @survey.survey_links.create!(name: "Newsletter", slug: "news-#{SecureRandom.hex(2)}")

    # 130 answers, one a minute, oldest first — so "newest first" is checkable
    # and the page size (100) is crossed. Every tenth one arrived through the
    # named link; the first three are blank, which is not an answer.
    130.times do |i|
      value = i < 3 ? "  " : "Answer #{i} — #{i.even? ? 'loved it' : 'fine'}"
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
        created_at: (200 - i).minutes.ago,
        survey_link: (i % 10).zero? ? @link : nil,
        answers: { "0" => { "type" => "open_ended", "value" => value },
                   "1" => { "type" => "multiple_choice", "value" => "Blue" } }
      )
    end
    # And one from long before the date-range presets reach.
    @survey.responses.create!(
      session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
      created_at: 40.days.ago,
      answers: { "0" => { "type" => "open_ended", "value" => "An old answer" } }
    )
  end

  def make_user(tag)
    User.create!(name: tag.capitalize, email_address: "#{tag}-#{SecureRandom.hex(3)}@test.com",
                 password: "verylongpassword")
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def answers(**params)
    get survey_results_answers_path(@survey, card_index: 0, **params), as: :json
    assert_response :success
    JSON.parse(response.body)
  end

  # ── The endpoint ─────────────────────────────────────────────────────────

  test "pages every answer newest first, blank ones left out" do
    sign_in @admin
    page1 = answers

    assert page1["ok"]
    assert_equal "Why did you come?", page1["question"]
    assert_equal 128, page1["total"], "127 non-blank recent answers plus the old one"
    assert_equal 128, page1["matched"]
    assert_equal 100, page1["answers"].size
    assert_equal 1, page1["page"]
    assert page1["has_more"]
    assert_equal "Answer 129 — fine", page1["answers"].first["text"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, page1["answers"].first["at"])
    ats = page1["answers"].map { |a| a["at"] }
    assert_equal ats.sort.reverse, ats, "not newest first"

    page2 = answers(page: 2)
    assert_equal 28, page2["answers"].size
    refute page2["has_more"]
    assert_equal "An old answer", page2["answers"].last["text"]
    assert_empty page1["answers"].map { |a| a["text"] } & page2["answers"].map { |a| a["text"] }

    assert_empty answers(page: 9)["answers"]
  end

  test "search narrows to matching answers, case-insensitively, and says how many" do
    sign_in @admin
    data = answers(q: "LOVED")

    assert_equal 128, data["total"]
    assert_equal 63, data["matched"], "the even-numbered answers 4..128"
    assert_equal 63, data["answers"].size
    refute data["has_more"]
    assert data["answers"].all? { |a| a["text"].include?("loved it") }

    assert_equal 0, answers(q: "nothing like this")["matched"]
  end

  test "honours the page's segment and date range" do
    sign_in @admin

    via_link = answers(segment: "link_#{@link.id}")
    assert_equal 12, via_link["total"], "every tenth response came through the link, the blank first one aside"
    assert via_link["answers"].all? { |a| a["text"] =~ /Answer \d*0 /o }

    recent = answers(range: "7d")
    assert_equal 127, recent["total"], "the 40-day-old answer is outside the window"
    refute recent["answers"].any? { |a| a["text"] == "An old answer" }

    assert_equal 128, answers(segment: "no-such-segment")["total"], "an unknown segment falls back to Overall"
  end

  test "refuses a card that isn't a freeform question" do
    sign_in @admin

    get survey_results_answers_path(@survey, card_index: 1), as: :json
    assert_response :unprocessable_entity
    refute JSON.parse(response.body)["ok"]

    get survey_results_answers_path(@survey, card_index: 40), as: :json
    assert_response :unprocessable_entity

    # -1 would be the last card, which is open_ended in shape — refused all the same.
    get survey_results_answers_path(@survey, card_index: -1), as: :json
    assert_response :unprocessable_entity
  end

  # ── "Other" on a closed question ──────────────────────────────────────────
  # A closed card lets a respondent write an "Other" in instead of picking;
  # the card listed twenty of them cut to 200 characters and a "+ N more"
  # that led nowhere. The same panel serves them now — kind=other.

  # Twenty-five write-ins on the Colour card, one a minute, the first blank
  # (which is not an answer), every even one through the named link.
  def seed_others
    25.times do |i|
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
        created_at: (60 - i).minutes.ago,
        survey_link: i.even? ? @link : nil,
        answers: { "0" => { "type" => "open_ended", "value" => "Came for the colours" },
                   "1" => { "type" => "multiple_choice", "value" => "Other", "other" => i.zero? ? "  " : "Shade #{i}" } }
      )
    end
  end

  def others(**params)
    get survey_results_answers_path(@survey, card_index: 1, kind: "other", **params), as: :json
    assert_response :success
    JSON.parse(response.body)
  end

  test "kind=other pages a closed question's write-ins, newest first, blank ones left out" do
    seed_others
    sign_in @admin
    data = others

    assert data["ok"]
    assert_equal "Colour?", data["question"]
    assert_equal 24, data["total"], "the blank write-in is not an answer, as the card's own count says"
    assert_equal "Shade 24", data["answers"].first["text"]
    ats = data["answers"].map { |a| a["at"] }
    assert_equal ats.sort.reverse, ats, "not newest first"
    refute data["has_more"]
  end

  test "kind=other searches on the server and follows the page's segment" do
    seed_others
    sign_in @admin

    assert_equal 6, others(q: "SHADE 2")["matched"], "Shade 2 and Shade 20..24, case-insensitively"
    assert_equal 12, others(segment: "link_#{@link.id}")["total"], "the even write-ins, the blank one aside"
  end

  test "kind=other on a question nobody wrote in for is empty, and a card that isn't there is refused" do
    sign_in @admin
    assert_equal 0, others["total"]

    get survey_results_answers_path(@survey, card_index: 40, kind: "other"), as: :json
    assert_response :unprocessable_entity
    get survey_results_answers_path(@survey, card_index: -1, kind: "other"), as: :json
    assert_response :unprocessable_entity
  end

  test "the closed card previews the newest ten write-ins in full and offers every one of them" do
    seed_others
    long = "Long " * 80 # 400 characters — used to be cut to 200 in this section
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                              answers: { "0" => { "type" => "open_ended", "value" => "x" },
                                         "1" => { "type" => "multiple_choice", "value" => "Other", "other" => long } })
    sign_in @admin

    get survey_results_path(@survey)
    assert_response :success
    assert_select ".rc-section .rc-quote", 10
    assert_select ".rc-section .rc-quote", text: /Shade 24/, count: 1
    assert_select ".rc-section .rc-quote", text: /\A\s*#{Regexp.escape(long.strip)}\s*\z/, count: 1
    refute_match "+ 5 more", response.body, "the dead '+ N more' line is gone from write-ins too"

    get survey_results_path(@survey, segment: "link_#{@link.id}", range: "30d")
    buttons = css_select("button.freeform-view-all").select { |b| b["data-freeform-answers-url-param"].include?("kind=other") }
    assert_equal 1, buttons.size
    button = buttons.first
    assert_match "View all answers (12)", button.text
    url = button["data-freeform-answers-url-param"]
    assert_match "card_index=1", url
    assert_match "segment=link_#{@link.id}", url, "the panel must follow the page's segment"
    assert_match "range=30d", url, "the panel must follow the page's date range"
    assert_equal "Colour?", button["data-freeform-answers-question-param"]
    assert_equal "Other: written-in answers", button["data-freeform-answers-eyebrow-param"]
  end

  test "counts what the card counted: false is not an answer, 0 is" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                              answers: { "0" => { "type" => "open_ended", "value" => false } })
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                              answers: { "0" => { "type" => "open_ended", "value" => 0 } })
    sign_in @admin

    data = answers
    assert_equal 129, data["total"]
    assert_equal "0", data["answers"].first["text"]
    refute data["answers"].any? { |a| a["text"] == "false" }

    get survey_results_path(@survey)
    assert_select "button.freeform-view-all", text: /\(129\)/
  end

  test "is scoped to the signed-in organisation and needs a session" do
    other_org  = Organisation.create!(name: "Other", slug: "ff-other-#{SecureRandom.hex(3)}")
    other_user = make_user("other")
    other_org.memberships.create!(user: other_user, role: "admin")

    sign_in other_user
    get survey_results_answers_path(@survey, card_index: 0), as: :json
    assert_response :not_found

    delete session_path
    get survey_results_answers_path(@survey, card_index: 0)
    assert_redirected_to new_session_path
  end

  test "a viewer can read the answers — seeing results is what the role is for" do
    viewer = make_user("viewer")
    @org.memberships.create!(user: viewer, role: "viewer")
    sign_in viewer
    assert_equal 128, answers["total"]
  end

  # ── The pages ────────────────────────────────────────────────────────────

  test "the result card previews the newest ten in full and offers every answer" do
    sign_in @admin
    get survey_results_path(@survey, segment: "link_#{@link.id}", range: "30d")
    assert_response :success

    assert_select ".freeform-preview-item", 10
    assert_select ".freeform-preview-item", text: /Answer 120 — loved it/, count: 1
    refute_match "+ 3 more", response.body, "the dead '+ N more' line is gone"
    assert_select "button.freeform-view-all", count: 1 do |buttons|
      button = buttons.first
      assert_match "View all answers (12)", button.text
      url = button["data-freeform-answers-url-param"]
      assert_match %r{/surveys/#{@survey.id}/results/answers\?}, url
      assert_match "card_index=0", url
      assert_match "segment=link_#{@link.id}", url, "the panel must follow the page's segment"
      assert_match "range=30d", url, "the panel must follow the page's date range"
      assert_equal "Why did you come?", button["data-freeform-answers-question-param"]
    end
    assert_select "[data-freeform-answers-target='modal']", 1
  end

  test "a long answer is no longer cut to 200 characters in the preview" do
    long = "Long " * 80 # 400 characters
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
                              answers: { "0" => { "type" => "open_ended", "value" => long } })
    sign_in @admin
    get survey_results_path(@survey)
    assert_select ".freeform-preview-item__text", text: /\A\s*#{Regexp.escape(long.strip)}\s*\z/, count: 1
  end

  # ── The demographic tail ─────────────────────────────────────────────────
  #
  # Birth month and location are open_ended cards whose answers are written by
  # the player's own widgets, so they are stored structured: "1977-09" and
  # "CC|Region". They were refused this endpoint on the grounds that those are
  # picks rather than answers — which left a creator with 292 birth months and
  # a view of the newest ten.
  #
  # They are served now, and rendered as words on the way. Both halves matter:
  # opening a panel onto 122 rows of "DE|" would answer the ask and help
  # nobody.

  # Two per card, far enough apart in time to be orderable, plus the shapes
  # that have to survive: a country with no region, and a postcode segment.
  def seed_demographics
    [ [ "ES|Catalunya", "1977-09" ], [ "DE|", "1992-10" ],
      [ "GB|Greater London, England|SW1A 1AA", "2001-01" ] ].each_with_index do |(place, born), i|
      @survey.responses.create!(
        session_token: SecureRandom.uuid, status: "completed", locale: "en", answered: true,
        created_at: (10 - i).minutes.ago,
        answers: { "3" => { "type" => "open_ended", "value" => place },
                   "4" => { "type" => "open_ended", "value" => born } }
      )
    end
  end

  def demographic_answers(index, **params)
    get survey_results_answers_path(@survey, card_index: index, **params), as: :json
    assert_response :success
    JSON.parse(response.body)
  end

  test "the demographic tail is served, as words rather than as storage" do
    seed_demographics
    sign_in @admin

    place = demographic_answers(3)
    assert place["ok"]
    assert_equal 3, place["total"]
    assert_equal [ "Greater London, England, United Kingdom · SW1A 1AA", "Germany", "Catalunya, Spain" ],
                 place["answers"].map { |a| a["text"] },
                 "newest first, and none of them reading as a storage format"

    born = demographic_answers(4)
    assert_equal [ "January 2001", "October 1992", "September 1977" ], born["answers"].map { |a| a["text"] }
  end

  # The search box filters what the panel DISPLAYS. Typing "Spain" into a list
  # showing "Catalunya, Spain" and getting nothing would be broken, however
  # defensible "ES|Catalunya doesn't contain Spain" is.
  test "the search matches the words shown, not the stored code" do
    seed_demographics
    sign_in @admin

    assert_equal 1, demographic_answers(3, q: "Spain")["matched"]
    assert_equal 1, demographic_answers(3, q: "germany")["matched"], "and case-insensitively, like every other card"
    assert_equal 1, demographic_answers(4, q: "September")["matched"]
  end

  test "the result card offers the panel on a demographic question too" do
    seed_demographics
    sign_in @admin
    get survey_results_path(@survey)
    assert_response :success

    buttons = css_select("button.freeform-view-all")
    urls    = buttons.map { |b| b["data-freeform-answers-url-param"] }
    assert urls.any? { |u| u.include?("card_index=3") },
      "the location card previews ten answers and offers no way to the other 112"
    assert urls.any? { |u| u.include?("card_index=4") }

    # …and its preview reads as words as well, not just the panel behind it.
    assert_select ".freeform-preview-item__text", text: /Catalunya, Spain/
    assert_select ".freeform-preview-item__text", text: /September 1977/
    refute_match "ES|Catalunya", response.body
  end

  test "the public shared-results page keeps freeform answers hidden and has no panel" do
    seed_others
    @survey.update!(results_share_token: SecureRandom.urlsafe_base64(18), results_share_active: true)
    get shared_results_path(@survey.results_share_token)
    assert_response :success

    refute_match "freeform-view-all", response.body
    refute_match "Answer 129", response.body
    refute_match "Shade 24", response.body, "a write-in is free text, hidden on the shared page like the rest"
    assert_select "[data-freeform-answers-target='modal']", 0
  end
end
