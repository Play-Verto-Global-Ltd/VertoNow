require "application_system_test_case"

# "Every answer type available in the Verto experience should have a clearly
# labelled and consistent Mobile Background control" — and "the Mobile
# Background and Mobile Header/Main Asset need to be treated as completely
# separate properties/assets. Changing one must never change the other."
#
# mobile_background_test.rb covers where the layer paints and what the player
# shows. This file covers the EDITOR's side of the contract, across the deck:
# the control is on every type, it lives outside the phone in the frame, and
# on a type with a header the two designs never reach each other.
class MobileBackgroundEveryTypeTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze
  HERO = "/assets/verto-library/left-panel/sports-people-desktop-2.jpg".freeze

  # One card of every pickable question type, plus the welcome card. Half of
  # them carry a header picture and half do not, so both branches of the
  # panel's CTA row are exercised.
  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "title" => "Hello" },
    { "type" => "range", "cid" => "range", "text" => "How much?",
      "options" => [ "None", "A bit", "Some", "Lots", "All" ] },
    { "type" => "rating", "cid" => "rating", "text" => "Rate it", "options" => [ "Poor", "Great" ],
      "image" => HERO },
    { "type" => "nps", "cid" => "nps", "text" => "How likely?", "image" => HERO },
    { "type" => "multiple_choice", "cid" => "multiple_choice", "text" => "Pick one", "options" => %w[A B] },
    { "type" => "select_many", "cid" => "select_many", "text" => "Pick some", "options" => %w[A B C],
      "image" => HERO },
    { "type" => "prioritise", "cid" => "prioritise", "text" => "Rank these", "options" => %w[A B C] },
    { "type" => "yes_no", "cid" => "yes_no", "text" => "Yes?", "options" => %w[Yes No], "image" => HERO },
    { "type" => "select_one_grid", "cid" => "select_one_grid", "text" => "Grid one", "options" => %w[A B C D] },
    { "type" => "select_many_grid", "cid" => "select_many_grid", "text" => "Grid many", "options" => %w[A B C D],
      "image" => HERO },
    { "type" => "tap_card", "cid" => "tap_card", "text" => "Tap it", "options" => [ "One", "Two" ],
      "image" => HERO },
    { "type" => "scenario", "cid" => "scenario", "text" => "Read this",
      "pages" => [ "Page one", "Page two" ], "options" => %w[A B] },
    { "type" => "open_ended", "cid" => "open_ended", "text" => "Tell us", "image" => HERO }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Every", slug: "mbe-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Ev", email_address: "mbe-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "Every type", theme: "football", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_editor(device: nil)
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Tell us"
    return unless device

    execute_script(%(document.querySelector(".device-toggle-btn[data-device='#{device}']").click()))
    assert_selector ".device-#{device}", wait: 5
  end

  def cids
    CARDS.map { |c| c["cid"] }
  end

  # ── The control is everywhere ───────────────────────────────────────────

  test "every card type carries a Mobile background control on the desktop editor" do
    open_editor

    cids.each do |cid|
      within("[data-card-cid='#{cid}']") do
        assert_selector ".card-bg-fab", text: "Mobile background", visible: true
      end
    end
  end

  test "every card type carries a Mobile background control in the phone frame, beside the phone" do
    open_editor(device: "mobile")

    cids.each do |cid|
      within("[data-card-cid='#{cid}']") do
        assert_selector ".dock-mobile-bg", text: "Mobile background", visible: true
      end
    end
  end

  # ── The CTAs are outside the phone ──────────────────────────────────────
  # "I want all CTAs for editing outside of the phone for the mobile editor —
  # this gives the user more space to see the mobile."
  %w[mobile tablet].each do |device|
    test "in the #{device} frame no design CTA sits over the screen" do
      open_editor(device: device)

      %w[range rating tap_card multiple_choice].each do |cid|
        geometry = evaluate_script(<<~JS)
          (() => {
            const wrap  = document.querySelector("[data-card-cid='#{cid}']")
            const frame = wrap.querySelector(".split-card").getBoundingClientRect()
            const dock  = wrap.querySelector(".card-media-dock")
            const shown = Array.from(dock.querySelectorAll(".dock-btn"))
              .filter(b => getComputedStyle(b).display !== "none")
              .map(b => {
                const r = b.getBoundingClientRect()
                return { label: b.textContent.trim(), outside: r.left >= frame.right - 1 || r.right <= frame.left + 1 }
              })
            const inFrame = Array.from(wrap.querySelectorAll(".split-left-cta-row, .split-left-design-prompt"))
              .filter(el => getComputedStyle(el).display !== "none").length
            return { shown, inFrame }
          })()
        JS

        assert_operator geometry["shown"].size, :>=, 2, "#{cid}: the dock offers #{geometry['shown'].inspect}"
        geometry["shown"].each do |b|
          assert b["outside"], "#{cid}: '#{b['label']}' is drawn over the #{device} screen"
        end
        assert_equal 0, geometry["inFrame"], "#{cid}: the panel's own pills are still floating over the screen"
      end
    end
  end

  test "the dock offers exactly the controls the panel would have" do
    open_editor(device: "mobile")

    shown = ->(cid) {
      evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[data-card-cid='#{cid}'] .dock-btn"))
          .filter(b => getComputedStyle(b).display !== "none").map(b => b.className.replace("dock-btn ", ""))
      JS
    }

    assert_equal %w[dock-animation dock-header-bg dock-mobile-bg], shown.call("range"),
                 "a range card has an animation and a backdrop behind it, and a mobile background"
    assert_equal %w[dock-media dock-reposition dock-mobile-bg], shown.call("rating"),
                 "a card with a picture can change it, move it, and design what sits below it"
    assert_equal %w[dock-design dock-header-bg dock-mobile-bg], shown.call("multiple_choice"),
                 "a bare card can add a picture, colour its header, and design what sits below it"
    assert_equal %w[dock-media dock-reposition dock-mobile-bg], shown.call("tap_card"),
                 "a full-screen type has no header on a phone, so no header backdrop"
  end

  # ── Header and mobile background never reach each other ─────────────────

  def set_colour(hex)
    assert_selector "[data-media-picker-target='animBgSection']", visible: true
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-media-picker-target='animBgColor']")
        el.value = "#{hex}"
        el.dispatchEvent(new Event("input", { bubbles: true }))
      })()
    JS
    find(".media-modal-close").click
    assert_no_selector ".media-modal-backdrop", visible: true
  end

  def range_state
    evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector("[data-card-cid='range']")
        const sl = wrap.querySelector(".split-left"), sr = wrap.querySelector(".split-right")
        return {
          header: wrap.dataset.cardMediaBg || null,
          mobile: wrap.dataset.cardMobileBg || null,
          image:  wrap.dataset.cardImage || "",
          headerPaint: getComputedStyle(sl).backgroundColor,
          panelPaint:  getComputedStyle(sr).backgroundColor,
          panelBelowHeader: Math.round(sr.getBoundingClientRect().top) >= Math.round(sl.getBoundingClientRect().bottom) - 24
        }
      })()
    JS
  end

  test "on a range card the mobile background paints below the header and neither control touches the other" do
    open_editor(device: "mobile")

    within("[data-card-cid='range']") { find(".dock-mobile-bg").click }
    assert_selector ".media-modal-title", text: "Mobile background"
    set_colour("#123456")

    s = range_state
    assert_equal({ "color" => "#123456", "ink" => "light" }, JSON.parse(s["mobile"]))
    assert_nil s["header"], "the mobile background wrote the header's backdrop"
    assert_equal "rgb(18, 52, 86)", s["panelPaint"], "the answer panel is not painting the mobile background"
    assert_not_equal "rgb(18, 52, 86)", s["headerPaint"], "the mobile background is painting the header"
    assert s["panelBelowHeader"], "the panel is not below the header"

    within("[data-card-cid='range']") { find(".dock-header-bg").click }
    assert_selector ".media-modal-title", text: "Header background"
    set_colour("#abcdef")

    s = range_state
    assert_equal({ "color" => "#abcdef" }, JSON.parse(s["header"]))
    assert_equal "rgb(171, 205, 239)", s["headerPaint"], "the header backdrop did not paint the header"
    assert_equal({ "color" => "#123456", "ink" => "light" }, JSON.parse(s["mobile"]),
                 "changing the header changed the mobile background")
    assert_equal "rgb(18, 52, 86)", s["panelPaint"]
    assert_equal "", s["image"], "a backdrop wrote the card's own picture"

    # Both survive the autosave, in their own fields.
    stored = nil
    assert wait_until {
      stored = @survey.reload.cards.find { |c| c["cid"] == "range" }
      stored["mobile_bg"]&.dig("color") == "#123456" && stored["media_bg"]&.dig("color") == "#abcdef"
    }, "the two backdrops did not both reach the server: #{stored.slice('media_bg', 'mobile_bg').inspect}"
  end

  test "changing a card's header picture leaves its mobile background alone" do
    open_editor(device: "mobile")

    within("[data-card-cid='rating']") { find(".dock-mobile-bg").click }
    set_colour("#654321")
    before = evaluate_script(%(document.querySelector("[data-card-cid='rating']").dataset.cardMobileBg))

    within("[data-card-cid='rating']") { find(".dock-media").click }
    assert_selector ".media-modal-title", text: "Add media"
    # A tile from the static Verto library, re-found just before the click:
    # the recommended strip beside it renders asynchronously and replaces its
    # nodes, which makes a handle taken earlier obsolete.
    picked = all("[data-media-picker-target='libraryItem'][data-url*='verto-library']")
               .map { |t| t[:"data-url"] }.find { |u| u.present? && u != HERO }
    assert picked, "the picker offered nothing to pick"
    find("[data-media-picker-target='libraryItem'][data-url='#{picked}']", match: :first).click
    assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
    find("[data-media-picker-target='applyBtn']").click
    assert_no_selector ".media-modal-backdrop", visible: true

    wrap = find("[data-card-cid='rating']")
    assert_equal picked, wrap["data-card-image"], "the header picture did not change"
    assert_equal before, wrap["data-card-mobile-bg"], "changing the header changed the mobile background"
  end

  # Removing is the third thing the control does, and it must be as narrow as
  # setting: the panel goes back to white, the header stays whatever it was.
  test "removing the mobile background restores the white panel and nothing else" do
    open_editor(device: "mobile")

    within("[data-card-cid='yes_no']") { find(".dock-mobile-bg").click }
    set_colour("#222222")
    within("[data-card-cid='yes_no']") { find(".dock-mobile-bg").click }
    assert_selector "[data-media-picker-target='animBgClear']", text: "Remove background", visible: true
    find("[data-media-picker-target='animBgClear']").click
    find(".media-modal-close").click

    wrap = find("[data-card-cid='yes_no']")
    assert_nil wrap["data-card-mobile-bg"]
    assert_equal HERO, wrap["data-card-image"]
    assert_equal "rgb(255, 255, 255)",
                 evaluate_script(%(getComputedStyle(document.querySelector("[data-card-cid='yes_no'] .split-right")).backgroundColor))
  end
end
