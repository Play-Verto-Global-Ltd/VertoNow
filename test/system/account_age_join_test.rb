require "application_system_test_case"

# The end-of-Verto account ask, as a respondent of each age meets it (Privacy
# Notice §15: no account under 16). The 13-year-old never sees the card; a
# 22-year-old sees it as it always was; someone whose age the Verto never
# asked is asked to say they are 16 or over before either way in.
#
# Reported 2026-10-02 as "I went through as a 13 year old and as a 22 year old
# and saw the same ending" — which, before this, was true by construction.
class AccountAgeJoinSystemTest < ApplicationSystemTestCase
  def make_survey(cards)
    org = Organisation.create!(name: "Age Co", slug: "age-#{SecureRandom.hex(3)}")
    s = org.surveys.create!(
      title: "Age", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: cards,
      thankyou_title: "Thanks!", join_prompt_enabled: true
    )
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s
  end

  def start(s)
    visit "/play/#{s.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
  end

  def answer_age(label)
    assert_selector ".preview-card.active .slider-wrap", wait: 5
    find(".preview-card.active .slider-label, .preview-card.active [data-action='click->slider#jump']",
         text: label, match: :first).click
    find("[data-player-target='finishBtn']").click
    assert_selector ".preview-thankyou.active", wait: 8
  end

  AGE_ONLY = [ DemographicQuestions.core_card("age") ].freeze

  test "under 16, the end screen carries no account ask" do
    start(make_survey(AGE_ONLY))
    answer_age("Under 16")
    # The card is in the page from the start, hidden; the thank-you screen is
    # up, so _renderJoinState has run and chosen not to reveal it.
    assert_no_selector ".join-card", visible: true
  end

  test "at 18-24 the ask is there, with no age box to tick" do
    start(make_survey(AGE_ONLY))
    answer_age("18–24")
    find("[data-player-target='joinReveal'] .join-btn", wait: 5).click
    assert_selector "[data-player-target='joinEmail']", visible: true
    assert_no_selector "[data-player-target='joinAge']", visible: true
  end

  test "with no age asked, the ask needs the person to say they are 16 or over" do
    start(make_survey([ { "type" => "welcome_card", "title" => "Welcome" },
                        { "type" => "open_ended", "cid" => "c1", "text" => "Anything else?" } ]))
    click_button "Next"
    assert_selector ".preview-card.active .freeform-wrap", wait: 5
    find("[data-player-target='finishBtn']").click
    assert_selector ".preview-thankyou.active", wait: 8

    find("[data-player-target='joinReveal'] .join-btn", wait: 5).click
    assert_selector "[data-player-target='joinAge']", text: "I'm 16 or older", visible: true
    find("[data-player-target='joinEmail']").fill_in with: "age-#{SecureRandom.hex(3)}@test.com"
    find("[data-player-target='joinPassword']").fill_in with: "correct-horse-battery"

    find("[data-player-target='joinBtn']").click
    assert_selector "[data-player-target='joinError']", text: "aged 16 and over", visible: true
    assert_equal 0, Player.count

    find("[data-player-target='joinAgeBox']").check
    find("[data-player-target='joinBtn']").click
    wait_until { Player.count == 1 }
  end
end
