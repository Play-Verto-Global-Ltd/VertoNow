require "application_system_test_case"

# The age card changes its animation per ANSWER: its slider has a stop per age
# band and its set (NpsHelper::AGE_BAND_THEME) a frame per stop, so band N
# plays frame N — online music for the youngest, a gramophone for the oldest.
# Every other range card keeps the five-frame reaction sets it always had.
# Both are pinned here on one deck, through the real slider and the real
# lottie-player: the frame it records (`data-lottie-player-current-value`) and
# an animation actually mounted for it.
class AgeBandAnimationTest < ApplicationSystemTestCase
  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "aba-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "AgeBands", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "welcome_card", "title" => "Welcome" },
                                            { "type" => "range", "cid" => "r1", "text" => "How often?",
                                              "options" => %w[Never Rarely Sometimes Often Always],
                                              "range_theme" => "koala" },
                                            DemographicQuestions.cards.first.merge("cid" => "c_age") ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
  end

  # The frame the mounted player is on, and that its animation loaded — a URL
  # the set lacks would leave the panel empty and marked broken.
  def assert_frame(n)
    assert_selector ".preview-card.active .nps-lottie[data-lottie-player-current-value='#{n}']", wait: 5
    assert_selector ".preview-card.active .nps-lottie-mount svg", visible: :all, wait: 10
    assert_no_selector ".preview-card.active .nps-lottie.is-broken"
  end

  def urls_mounted
    JSON.parse(find(".preview-card.active .nps-lottie")["data-lottie-player-urls-value"])
  end

  test "a five-stop range card still spreads its stops across five frames" do
    assert_selector ".preview-card.active .slider-wrap[data-slider-steps-value='5']"
    assert_equal 5, urls_mounted.size
    assert_frame 3

    # Tapping a stop's word jumps to it (slider#jump) — the player's own
    # answering gesture, and one that reaches the end stops in a single move.
    find(".preview-card.active .slider-label-text", text: "Always").click
    assert_frame 5
    find(".preview-card.active .slider-label-text", text: "Never").click
    assert_frame 1
  end

  test "the age card plays one frame per band, youngest to oldest" do
    click_button "Next"
    wrap = find(".preview-card.active .slider-wrap[data-slider-top-down-value='true']")
    assert_equal 7, urls_mounted.size, "the age card mounts the seven-frame set"
    assert_frame 4 # parked on the fourth band, "25–34"

    6.times { wrap.send_keys(:up) }
    assert_equal "Under 16", find(".preview-card.active .slider-label-text.is-active").text
    assert_frame 1

    6.times { wrap.send_keys(:down) }
    assert_equal "65+", find(".preview-card.active .slider-label-text.is-active").text
    assert_frame 7

    wrap.send_keys(:up)
    assert_frame 6
  end
end
