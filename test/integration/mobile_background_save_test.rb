require "test_helper"

# The server half of the mobile background: a phone-only layer behind the
# question and answers, on EVERY type, stored as card.mobile_bg and surviving
# an editor autosave on a card that is ALSO carrying a header picture.
#
# That combination is the whole feature. The header (card.image / video /
# lottie, and the header backdrop card.media_bg behind an animation) is one
# design; what sits below it on a phone is another; and "the Mobile Background
# and Mobile Header/Main Asset need to be treated as completely separate
# properties/assets" means each survives whatever happens to the other.
#
# It used to be allowed only on the three full-screen types, and stored in
# media_bg. That was the working implementation — this generalises it, so a
# deck saved then is folded into the new field on its next save and read from
# the old one until then.
#
# mobile_background_test.rb drives the browser for where it may paint;
# range_card_backdrop_test covers the header backdrop's half of the rule.
class MobileBackgroundSaveTest < ActionDispatch::IntegrationTest
  HERO = "/assets/verto-library/left-panel/sports-people-desktop-2.jpg".freeze
  BG   = "/assets/verto-library/mobile-backgrounds/sports-people-mobile-3.jpg".freeze

  def setup
    @user = User.create!(name: "U", email_address: "mbg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "mbg-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Football", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "w", "text" => "Kick off" },
        { "type" => "tap_card", "cid" => "t1", "text" => "Your call?",
          "options" => [ "Ticket prices", "Kick-off times" ], "image" => HERO },
        { "type" => "nps", "cid" => "n1", "text" => "How likely?", "image" => HERO },
        { "type" => "prioritise", "cid" => "p1", "text" => "In order?",
          "options" => [ "Cheaper", "Closer" ], "image" => HERO },
        { "type" => "open_ended", "cid" => "o1", "text" => "More?", "image" => HERO },
        { "type" => "range", "cid" => "r1", "text" => "How much?",
          "options" => [ "None", "A bit", "Some", "Lots", "All" ] }
      ]
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def patch_cards(cards)
    patch survey_path(@survey), params: { cards: cards }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def card(cid)
    @survey.reload.cards.find { |c| c["cid"] == cid }
  end

  # Every card in the deck gains the same mobile background; which of them
  # KEEP it is the rule under test — and the answer is all of them.
  def patch_all_with_background
    patch_cards(@survey.cards.map { |c| c["cid"] == "w" ? c : c.merge("mobile_bg" => { "image" => BG }) })
    assert_response :success
    @survey.reload.cards.index_by { |c| c["cid"] }
  end

  test "every type keeps a mobile background alongside its header picture" do
    cards = patch_all_with_background

    %w[t1 n1 p1 o1 r1].each do |cid|
      assert_equal BG, cards[cid].dig("mobile_bg", "image"),
                   "#{cid} lost its mobile background. It sits BELOW the header, so a picture in " \
                   "the header says nothing about it."
    end
    %w[t1 n1 p1 o1].each do |cid|
      assert_equal HERO, cards[cid]["image"],
                   "#{cid}'s own picture was dropped for the background — they are separate " \
                   "designs for separate layers and both have to survive"
    end
  end

  # The card the old rule refused: an ordinary type showing its picture as a
  # phone header. The mobile background is below that header, not behind it.
  test "an ordinary card carrying a picture keeps one too, because it paints below the header" do
    cards = patch_all_with_background

    assert_equal BG, cards["o1"].dig("mobile_bg", "image"),
                 "a mobile background was refused on a card with a header picture. The two are " \
                 "different elements of the phone card — the header is above, this is behind " \
                 "the question and answers — so there is nothing for one to hide the other."
  end

  test "the background survives the autosave that just re-sends the deck" do
    patch_all_with_background

    # What the editor posts on the next keystroke: the same deck, rebuilt from
    # the DOM. The round trip is where a background with no home gets lost.
    patch_cards(@survey.reload.cards)
    assert_response :success

    assert_equal BG, card("t1").dig("mobile_bg", "image")
    assert_equal BG, card("o1").dig("mobile_bg", "image")
  end

  # ── The two fields never touch each other ─────────────────────────────

  test "a range card's header backdrop and its mobile background are stored apart" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[5].merge("media_bg"  => { "color" => "#2e3564" },
                                         "mobile_bg" => { "color" => "#f4f4f4" }) ])
    assert_response :success

    r1 = card("r1")
    assert_equal "#2e3564", r1.dig("media_bg", "color"), "the header backdrop was lost"
    assert_equal "#f4f4f4", r1.dig("mobile_bg", "color"), "the mobile background was lost"
    assert_nil r1["media_bg"]["ink"], "the header backdrop carries no ink — no words are drawn on it"
    assert_equal "dark", r1["mobile_bg"]["ink"]
  end

  test "changing the mobile background leaves the header alone" do
    patch_cards([ @survey.cards[0], @survey.cards[5].merge("media_bg" => { "color" => "#2e3564" }) ])
    assert_response :success

    patch_cards([ @survey.cards[0], card("r1").merge("mobile_bg" => { "image" => BG }) ])
    assert_response :success

    r1 = card("r1")
    assert_equal "#2e3564", r1.dig("media_bg", "color"),
                 "setting the mobile background changed the header backdrop"
    assert_equal BG, r1.dig("mobile_bg", "image")
  end

  test "changing the header leaves the mobile background alone" do
    patch_cards([ @survey.cards[0], @survey.cards[4].merge("mobile_bg" => { "image" => BG }) ])
    assert_response :success

    patch_cards([ @survey.cards[0], card("o1").merge("image" => "/assets/verto-library/backgrounds/nature.jpg") ])
    assert_response :success

    o1 = card("o1")
    assert_equal "/assets/verto-library/backgrounds/nature.jpg", o1["image"]
    assert_equal BG, o1.dig("mobile_bg", "image"),
                 "swapping the header picture took the mobile background with it"
  end

  # ── Colour, ink ───────────────────────────────────────────────────────

  test "a colour is a background too, and needs no picture behind it" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[1].merge("mobile_bg" => { "color" => "#2e3564" }) ])
    assert_response :success

    # …with its ink decided for it, which is the next test's subject.
    assert_equal({ "color" => "#2e3564", "ink" => "light" }, card("t1")["mobile_bg"])
  end

  # "The text colour goes white regardless of the background — we need it to
  # react to the colour of the background."
  test "the ink the editor measured survives the save" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[1].merge("mobile_bg" => { "image" => BG, "ink" => "dark" }) ])
    assert_response :success

    assert_equal "dark", card("t1").dig("mobile_bg", "ink"),
                 "the measurement the editor took is gone, so the card renders white words on " \
                 "whatever the picture turns out to be"
  end

  test "a colour with no picture is measured by the server, which needs no editor" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[4].merge("mobile_bg" => { "color" => "#f4f4f4" }) ])
    assert_response :success
    assert_equal "dark", card("o1").dig("mobile_bg", "ink"),
                 "a near-white background kept light ink — an import or a seed never goes near " \
                 "the picker, so the server has to decide for itself"

    # The first patch replaced the deck with those two cards; edit the one
    # that is there now.
    patch_cards([ @survey.cards[0],
                  card("o1").merge("mobile_bg" => { "color" => "#101425" }) ])
    assert_response :success
    assert_equal "light", card("o1").dig("mobile_bg", "ink")
  end

  test "an ink with nothing behind it is not a background" do
    patch_cards([ @survey.cards[0], @survey.cards[1].merge("mobile_bg" => { "ink" => "dark" }) ])
    assert_response :success

    assert_nil card("t1")["mobile_bg"],
               "a text colour with no colour and no picture behind it was stored as a background"
  end

  # ── A GIF is an image ─────────────────────────────────────────────────
  # The picker keeps a GIF's bytes rather than re-encoding it through a canvas
  # (which would keep one frame), and the server stores it as a GIF: the
  # animation reaches the phone.
  GIF_B64 = "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==".freeze

  test "an uploaded GIF is kept as the mobile background, as a GIF" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[4].merge("mobile_bg" => { "image" => "data:image/gif;base64,#{GIF_B64}" }) ])
    assert_response :success

    stored = card("o1").dig("mobile_bg", "image")
    assert stored.present?, "the GIF was dropped"
    # Externalised on save into a blob, like every other inline upload — and
    # the blob is the GIF, not a still of it.
    assert_match %r{/rails/active_storage/}, stored
    blob = @survey.card_images.last.blob
    assert_equal "image/gif", blob.content_type
    assert_match(/\.gif\z/, blob.filename.to_s)
  end

  # ── What was saved before this field existed ──────────────────────────
  # The three full-screen types kept their mobile background in media_bg.
  # A deck saved then has to keep rendering (ApplicationHelper#card_mobile_bg
  # reads it from there) and to end up in the right field on its next save,
  # without the creator doing anything.
  test "a full-screen card's legacy media_bg is moved into mobile_bg on save" do
    @survey.update_columns(cards: @survey.cards.map { |c|
      c["cid"] == "t1" ? c.merge("media_bg" => { "image" => BG, "ink" => "dark" }) : c
    })

    patch_cards(@survey.reload.cards)
    assert_response :success

    t1 = card("t1")
    assert_equal({ "image" => BG, "ink" => "dark" }, t1["mobile_bg"],
                 "the legacy mobile background did not reach its own field")
    assert_nil t1["media_bg"],
               "a full-screen type keeps no header backdrop: the phone draws it no header"
  end

  test "a legacy media_bg never overwrites a mobile_bg the creator has set since" do
    @survey.update_columns(cards: @survey.cards.map { |c|
      c["cid"] == "t1" ? c.merge("media_bg" => { "color" => "#111111" }, "mobile_bg" => { "color" => "#eeeeee" }) : c
    })

    patch_cards(@survey.reload.cards)
    assert_response :success

    assert_equal "#eeeeee", card("t1").dig("mobile_bg", "color")
    assert_nil card("t1")["media_bg"]
  end

  # ── Reporting ─────────────────────────────────────────────────────────

  test "a background the server refuses is still reported rather than dropped in silence" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[1].merge("mobile_bg" => { "image" => "https://evil.example/x.png" }) ])
    assert_response :success

    body = JSON.parse(response.body)
    assert_includes body["warnings"], "mobile_bg",
                    "the editor's 'an image didn't stick' pill is driven off this, and a " \
                    "newly-allowed type must not be a newly-silent one"
    assert_equal "t1", body["warning_details"].find { |d| d["code"] == "mobile_bg" }["cid"]
  end
end
