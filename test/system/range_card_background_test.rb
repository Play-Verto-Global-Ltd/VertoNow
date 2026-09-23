require "application_system_test_case"

# Animation background (2.10-ish: card["media_bg"]) already applied to a
# range card once _syncAnimationBg ran — _cardTakesBackground checks
# `card.dataset.cardType === "range"` — but nothing on a range card's panel
# ever called media-picker#open to get there: the range branch of
# _split_left.html.erb only rendered the reactive Lottie plus a
# "Change animation" CTA wired to the separate animation-picker modal. This
# suite exercises the new second CTA that opens the ordinary media picker for
# just the per-card settings.
class RangeCardBackgroundTest < ApplicationSystemTestCase
  def setup
    super
    @user = User.create!(name: "U", email_address: "range-bg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "O", slug: "range-bg-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Range BG", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "range", "cid" => "r1", "text" => "How likely?", "options" => %w[0 1 2 3 4 5 6 7 8 9 10] },
        # A range card that is STILL CARRYING A PHOTO. Switch a photo card to
        # Range in the Answer Type panel and this is what you get: the panel
        # draws the reaction set instead of the picture, and nothing clears the
        # picture — so the creator cannot see that the card is holding one.
        # It is the state the reported bug lived in.
        { "type" => "range", "cid" => "r2", "text" => "Would you use it?",
          "options" => [ "Wouldn't matter", "Not for me", "I might", "Probably", "Definitely" ],
          "image" => "/assets/verto-library/backgrounds/nature.jpg" },
        { "type" => "open_ended", "cid" => "o1", "text" => "When were you born?",
          "lottie" => "/verto_library/anim/example.json" }
      ]
    )
  end

  def lottie_card
    find(".survey-card-wrap[data-card-cid='o1']")
  end

  def range_card(cid = "r1")
    find(".survey-card-wrap[data-card-cid='#{cid}']")
  end

  def stored_bg(cid)
    30.times do
      card = @survey.reload.cards.find { |c| c["cid"] == cid }
      bg = card["media_bg"]
      return bg if yield(bg)
      sleep 0.5
    end
    @survey.reload.cards.find { |c| c["cid"] == cid }["media_bg"]
  end

  def set_backdrop_colour(cid, hex)
    within(range_card(cid)) { find(".header-bg-fab").click }
    assert_selector "[data-media-picker-target='animBgSection']", visible: true
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-media-picker-target='animBgColor']")
        el.value = "#{hex}"
        el.dispatchEvent(new Event("input", { bubbles: true }))
      })()
    JS
    find(".media-modal-close").click
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How likely?"
  end

  def open_range_background_settings
    open_editor
    within(range_card) { find(".header-bg-fab").click }
  end

  # ── The reported bug ───────────────────────────────────────────────────
  # "The background image I add to a range question, that sits behind the
  # animated assets, doesn't save. I have to re-add every time I load the
  # editor."
  #
  # Everything visible worked: the modal opened, the panel repainted, the card
  # row's dataset was written. What did not was survey-editor#serialize, which
  # rebuilds every card from the DOM on each autosave and dropped media_bg for
  # any card carrying an `image` — with no range exception, unlike the three
  # other places that state the same rule. Nothing was dropped server-side, so
  # there was no warning either. Only a save-and-reload can see it, which is
  # why the suite that owned this feature never did.

  test "a backdrop on a range card still holding a photo survives a reload" do
    open_editor
    set_backdrop_colour("r2", "#2255ff")

    assert_equal "#2255ff", stored_bg("r2") { |bg| bg&.dig("color") == "#2255ff" }&.dig("color"),
                 "the backdrop never reached the server — serialize() dropped it on the way out"

    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Would you use it?"
    assert_equal "#2255ff", evaluate_script(<<~JS)
      JSON.parse(document.querySelector(".survey-card-wrap[data-card-cid='r2']").dataset.cardMediaBg).color
    JS
  end

  # The same card, saved a second time by an edit that has nothing to do with
  # the backdrop: this is the autosave that used to take it away again.
  test "an unrelated edit does not take the backdrop back off" do
    open_editor
    set_backdrop_colour("r2", "#2255ff")
    stored_bg("r2") { |bg| bg&.dig("color") == "#2255ff" }

    title = find("[data-card-cid='r2'] .q-title")
    page.execute_script("arguments[0].focus()", title)
    press_keys("?")

    assert_equal "#2255ff", stored_bg("r2") { |bg| bg&.dig("color") == "#2255ff" }&.dig("color"),
                 "the next autosave dropped the backdrop the one before it had stored"
  end

  test "the range card's panel offers a Change animation, a Header background and a Mobile background CTA" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How likely?"

    within(range_card) do
      assert_selector ".add-animation-fab", text: "Change animation"
      assert_selector ".header-bg-fab", text: "Header background"
      # …and the other design every card has: what sits below the header.
      assert_selector ".card-bg-fab", text: "Mobile background"
    end
  end

  test "Background opens the media picker showing only the Animation background settings" do
    open_range_background_settings

    assert_selector ".media-modal-backdrop", visible: true
    assert_selector "[data-media-picker-target='animBgSection']", visible: true
    # No card-level photo/video slot to swap on a range card — the source
    # tabs/panes and "Remove current media" have nothing to act on.
    assert_no_selector ".media-modal-tabs", visible: true
    assert_no_selector "[data-media-picker-target='pane']", visible: true
    assert_no_selector "[data-media-picker-target='clearBtn']", visible: true
    # animate_asset is explicitly excluded for range cards (its own reaction
    # set already animates) — the toggle must stay hidden here too.
    assert_no_selector "[data-media-picker-target='animateAssetSection']", visible: true
    # Colour/asset settings here all save live — a permanently-disabled Apply
    # with nothing to ever enable it read as "did my change not stick?" (a
    # real report from actually using this). Hidden until there is something
    # to apply, i.e. after "Use an image" is picked.
    assert_no_selector "[data-media-picker-target='applyBtn']", visible: true
  end

  test "setting a background colour on a range card saves it live, no Apply needed" do
    open_range_background_settings

    # <input type="color"> isn't reliably typeable via Capybara's set — drive
    # it directly and dispatch the same "input" event setAnimBgColor listens
    # for, exactly like this suite's live-apply (no Apply button) is meant to
    # exercise.
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-media-picker-target='animBgColor']")
        el.value = "#ff00aa"
        el.dispatchEvent(new Event("input", { bubbles: true }))
      })()
    JS

    assert_equal "#ff00aa", evaluate_script(<<~JS)
      JSON.parse(document.querySelector(".survey-card-wrap[data-card-type='range']").dataset.cardMediaBg).color
    JS
  end

  test "Use an image on a range card's background brings the source tabs back" do
    open_range_background_settings
    find("[data-media-picker-target='animBgSection'] button", text: "Use an image").click

    assert_selector ".media-modal-tabs", visible: true
    assert_selector "[data-media-picker-target='pane'][data-pane='library']", visible: true
    # Now there's something a pick could apply to — Apply comes back.
    assert_selector "[data-media-picker-target='applyBtn']", visible: true
  end
  # A Lottie is the one medium that can be TRANSPARENT, so what sits behind it
  # is a real design decision — and this panel offered no way to make it ("I
  # need the Change Background option here for when we upload transparent
  # lottie files"). Only the ENTRY POINT was missing: media-picker's
  # _cardTakesBackground already returns true for any card carrying a lottie, not just
  # for range, so the Animation background section has been in that modal all
  # along with nothing on this panel calling it.
  test "a lottie card offers Background alongside Change media" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "When were you born?"

    within(lottie_card) do
      assert_selector ".add-media-fab", text: "Change media"
      assert_selector ".header-bg-fab", text: "Header background"
      assert_selector ".card-bg-fab",   text: "Mobile background"
    end
  end

  test "a lottie card's Background CTA opens the animation background settings" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "When were you born?"
    within(lottie_card) { find(".header-bg-fab").click }

    assert_selector ".media-modal-backdrop", visible: true
    assert_selector "[data-media-picker-target='animBgSection']", visible: true
  end

  # Scoped to lotties on purpose: a photo or a video is opaque, so a HEADER
  # background behind one is a control that does nothing. The MOBILE background
  # is another matter — it is below the header — and is offered regardless.
  test "a plain image card is not given a Header background CTA, but keeps Mobile background" do
    @survey.update_columns(cards: @survey.cards + [
      { "type" => "rating", "cid" => "img1", "text" => "Rate it", "image" => "/nope.jpg",
        "options" => [ "Poor", "Great" ] }
    ])
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Rate it"

    within(find(".survey-card-wrap[data-card-cid='img1']")) do
      assert_selector ".add-media-fab"
      # By its label, the way this file's own lottie test identifies it — the
      # .add-bg-fab CLASS is shared styling that "Adjust crop" (a control a
      # photo card is SUPPOSED to have) borrows too.
      assert_no_selector ".header-bg-fab"
      assert_no_selector ".add-bg-fab", text: "Header background"
      assert_selector ".card-bg-fab", text: "Mobile background"
    end
  end

  # Both FABs are `position: absolute` with a left:50% translate of their own —
  # correct while each is its panel's only control, wrong the moment they share
  # a row. Unreset, the second lands on top of the first and the row renders as
  # one button with another hidden underneath it.
  test "the two CTAs sit side by side rather than stacked" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "When were you born?"

    boxes = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector(".survey-card-wrap[data-card-cid='o1'] .split-left-cta-row")
        if (!row) return null
        return Array.from(row.children).map(el => {
          const r = el.getBoundingClientRect()
          return { left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width) }
        })
      })()
    JS

    assert_equal 3, boxes&.size, "expected three CTAs in the row, got #{boxes.inspect}"
    boxes.each_cons(2) do |a, b|
      assert_operator a["right"], :<=, b["left"] + 1,
                      "the CTAs overlap (#{boxes.inspect}) — one is still absolutely positioned " \
                      "inside the row, so it is painted on top of the other."
    end
  end

  # ── A card with NO media ──────────────────────────────────────────────────
  # The third case, and the one that had no control at all. A range or Lottie
  # card wants a backdrop because its animation is transparent; a bare card IS
  # its backdrop — the panel is nothing but a colour — and until a creator asked
  # to be able to design the phone view of an ordinary card, the only way to
  # change it was the Verto-wide brand panel.
  def bare_card
    find(".survey-card-wrap[data-card-cid='bare']")
  end

  def add_bare_card
    @survey.update_columns(cards: @survey.cards + [
      { "type" => "multiple_choice", "cid" => "bare", "text" => "Pick a lane",
        "options" => %w[Left Right] }
    ])
  end

  def open_bare_editor
    add_bare_card
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Pick a lane"
  end

  test "a card with no media offers Header background alongside Add design" do
    open_bare_editor

    within(bare_card) do
      assert_selector ".split-left-design-prompt"
      assert_selector ".header-bg-fab", text: "Header background"
      assert_selector ".card-bg-fab", text: "Mobile background"
    end
  end

  test "the bare card's Background CTA opens the card background settings" do
    open_bare_editor
    within(bare_card) { find(".header-bg-fab").click }

    assert_selector ".media-modal-backdrop", visible: true
    assert_selector "[data-media-picker-target='animBgSection']", visible: true
  end

  # The point of the control, and the reason it exists: on a phone a media-less
  # card has no hero strip at all — .split-left is display: contents — so a
  # backdrop with nothing to paint on would be a control that silently did
  # nothing on the one screen it was asked for. Setting one has to earn the card
  # its strip back, in the editor's phone frame as on the phone.
  test "a background gives a bare card a hero strip in the phone frame" do
    open_bare_editor
    find(".device-toggle-btn[data-device='mobile']").click
    assert_selector ".device-mobile", wait: 5

    before = evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".survey-card-wrap[data-card-cid='bare'] .split-left")).display
    JS
    assert_equal "contents", before,
                 "a bare card already has a hero strip in the phone frame — the live player " \
                 "gives it none, so this preview is wrong before the backdrop is even set"

    # In the phone frame the panel's pills live in the dock beside the phone.
    within(bare_card) { find(".dock-header-bg").click }
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-media-picker-target='animBgColor']")
        el.value = "#2255ff"
        el.dispatchEvent(new Event("input", { bubbles: true }))
      })()
    JS
    find(".media-modal-close").click

    after = evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector(".survey-card-wrap[data-card-cid='bare']")
        const left = wrap.querySelector(".split-left")
        const card = wrap.querySelector(".split-card")
        return {
          display: getComputedStyle(left).display,
          klass:   left.className,
          share:   left.getBoundingClientRect().height / card.getBoundingClientRect().height
        }
      })()
    JS

    assert_includes after["klass"], "has-media-bg",
                    "the panel was painted but never marked, so nothing gives it a strip"
    assert_equal "block", after["display"],
                 "the backdrop is set and the phone frame still shows no strip to paint it on"
    assert_in_delta 0.45, after["share"], 0.03,
                    "the earned strip is #{(after['share'] * 100).round(1)}% of the card rather " \
                    "than the player's 45%"
  end
end
