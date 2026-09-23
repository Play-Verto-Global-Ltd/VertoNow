require "application_system_test_case"

# The one part of combining segments only a browser can see: each pill is a
# link to a whole page, and a navigation closes every <details> on it, so
# building "Austria · Male" would mean opening the picker again for every
# part. segment_picker_controller reopens it after a pill click — and leaves
# it shut after the reset, because a panel over the numbers you just asked
# for is in the way. The server side (what the URL means, what the pills
# link to) is results_combinations_test.rb.
class ResultsSegmentPickerTest < ApplicationSystemTestCase
  MIN = Response::MIN_REGION_SAMPLE_SIZE

  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "sp-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "sp-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Picker", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] } ]
    )
    seed(MIN + 1, "AT", "Male")
    seed(MIN + 1, "AT", "Female")
    seed(MIN + 1, "DE", "Male")
  end

  def seed(n, country, gender)
    n.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                                region_country: country, demographic_gender: gender,
                                answers: { "0" => { "value" => "A" } })
    end
  end

  # 1280, deliberately: under 1290 the header's segment filter is the single
  # compact picker this file is about, and over it the Overall chip beside it
  # carries the reset instead. Stated rather than inherited from the driver's
  # default, because which control exists here depends on it.
  NARROW = 1280

  def open_results(**params)
    page.driver.browser.resize(width: NARROW, height: 900)
    sign_in_as(@user)
    visit survey_results_path(@survey, **params)
    dismiss_cookie_banner
    assert_selector ".rh-segments", wait: 5
  end

  def picker_open?
    evaluate_script("document.querySelector('.rh-segments').open")
  end

  def click_pill(text)
    find(".rh-segments-panel a.rh-seg", text: text).click
  end

  test "a combination is built pill by pill without reopening the picker" do
    open_results
    refute picker_open?

    find(".rh-segments summary").click
    assert picker_open?
    click_pill "Austria"

    # The page is a new one — Austria in force — and the panel is open on it.
    assert_current_path survey_results_path(@survey, segment: "region_AT"), wait: 5
    assert_selector ".rh-segments-panel a.rh-seg[aria-current='true']", text: "Austria", wait: 5
    assert picker_open?, "the picker closed on the visit, so the second part costs a reopen"

    click_pill "Male"
    assert_current_path survey_results_path(@survey, segment: "region_AT,gender_male"), wait: 5
    assert_selector ".rh-segments summary .rh-picker-active", text: "🌍 Austria · 👤 Male", wait: 5
    assert_selector ".rh-count-num", text: (MIN + 1).to_s
    assert picker_open?
  end

  test "the reset leaves the picker shut, and a fresh visit never opens it" do
    open_results(segment: "region_AT,gender_male")
    refute picker_open?, "a shared or bookmarked combination link opens with the panel shut"

    find(".rh-segments summary").click
    find(".rh-segments-panel .rh-group--reset a").click

    assert_current_path survey_results_path(@survey), wait: 5
    assert_selector ".rh-segments summary .rh-picker-active", text: "Overall", wait: 5
    refute picker_open?, "Overall is 'I am done' — the panel would sit over the numbers just asked for"
  end
end
