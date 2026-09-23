require "application_system_test_case"

# The age card is a vertical range slider that lists its bands youngest FIRST,
# down the page — unlike every other vertical scale, which fills upward. Only
# the drawing flips: the answer is still the option's index, so "Under 16" is
# stored as 0 whichever end it is drawn at, and the age sync's band mapping is
# untouched.
#
# Also pinned here: the thumb parked on either end stop stays inside the
# slider. The end stops used to sit on the very ends of the track, so a thumb
# at the top or bottom hung half outside it and the card's clip cut it off.
class AgeSliderOrderTest < ApplicationSystemTestCase
  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "age-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "AgeOrder", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "welcome_card", "title" => "Welcome" } ] +
                                          [ DemographicQuestions.cards.first.merge("cid" => "c_age") ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active .slider-wrap[data-slider-top-down-value='true']"
  end

  def slider_state
    page.evaluate_script(<<~JS)
      (() => {
        const wrap   = document.querySelector(".preview-card.active .slider-wrap")
        const labels = [...wrap.querySelectorAll(".slider-label-text")]
        const box    = (el) => el.getBoundingClientRect()
        return {
          order:  labels.sort((a, b) => box(a).top - box(b).top).map(l => l.textContent.trim()),
          active: wrap.querySelector(".slider-label-text.is-active")?.textContent.trim(),
          thumb:  [ box(wrap.querySelector(".slider-thumb")).top, box(wrap.querySelector(".slider-thumb")).bottom ],
          wrap:   [ box(wrap).top, box(wrap).bottom ]
        }
      })()
    JS
  end

  test "the bands read youngest to oldest, top to bottom" do
    assert_equal DemographicQuestions::AGE_BAND_LABELS, slider_state["order"]
  end

  test "the arrow keys follow the thumb, and the ends stay inside the slider" do
    wrap = find(".preview-card.active .slider-wrap")
    6.times { wrap.send_keys(:up) }
    top = slider_state
    assert_equal "Under 16", top["active"], "ArrowUp moves toward the top of the list"
    assert_operator top["thumb"][0], :>=, top["wrap"][0] - 1, "the thumb on the first band must not overhang the slider"

    6.times { wrap.send_keys(:down) }
    bottom = slider_state
    assert_equal "65+", bottom["active"], "ArrowDown moves toward the bottom of the list"
    assert_operator bottom["thumb"][1], :<=, bottom["wrap"][1] + 1, "the thumb on the last band must not overhang the slider"
  end
end
