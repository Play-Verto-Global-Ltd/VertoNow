require "test_helper"

# P1-7's other half. CardImageStore and the backfill task moved the EXISTING
# base64 out of the columns, but the door stayed open: sanitize_image_url still
# accepts a data-URL, so the editor's upload fallback, background and consent
# images, imports and duplicated decks could all put megabytes straight back.
# Cleaning up history without closing the door just means doing it again.
#
# Survey externalises inline images on save, so no write path can leave base64
# in a column.
class InlineImageExternalizationTest < ActiveSupport::TestCase
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze
  DATA_URL = "data:image/png;base64,#{Base64.strict_encode64(PNG)}".freeze
  STORED   = %r{\A/rails/active_storage/}

  def setup
    @org = Organisation.create!(name: "O", slug: "ext-#{SecureRandom.hex(3)}")
  end

  def survey(cards: [], **attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards, **attrs)
  end

  # ── The guarantee ─────────────────────────────────────────────────────────

  test "a card image written as base64 is stored as a blob path" do
    s = survey
    s.update!(cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                         "options" => %w[Yes No], "image" => DATA_URL } ])

    assert_match STORED, s.reload.cards.first["image"]
    assert_not_includes s.cards.to_json, "data:image/"
    assert_equal 1, s.card_images.attachments.size, "the bytes live in storage, attached to the Verto"
  end

  test "option images are externalised too" do
    s = survey
    s.update!(cards: [ { "type" => "tap_card", "cid" => "c_b", "text" => "T",
                         "options" => [ "S1", "S2" ],
                         "option_images" => [ DATA_URL, "https://images.pexels.com/photos/1/x.jpg" ] } ])

    images = s.reload.cards.first["option_images"]
    assert_match STORED, images[0]
    assert_equal "https://images.pexels.com/photos/1/x.jpg", images[1], "a remote URL is left alone"
  end

  # The editor persists an upload before applying it to either backdrop, so
  # base64 only lands here when that call failed — and then it has to go the
  # way every other inline picture goes, or a 3MB GIF rides in the column.
  test "a card's header backdrop and mobile background are externalised too" do
    s = survey
    s.update!(cards: [ { "type" => "range", "cid" => "c_r", "text" => "Q",
                         "options" => %w[a b c d e],
                         "media_bg"  => { "color" => "#123456", "image" => DATA_URL },
                         "mobile_bg" => { "image" => DATA_URL } } ])

    card = s.reload.cards.first
    assert_match STORED, card["media_bg"]["image"]
    assert_equal "#123456", card["media_bg"]["color"], "the rest of the backdrop is untouched"
    assert_match STORED, card["mobile_bg"]["image"]
    assert_not_includes s.cards.to_json, "data:image/"
  end

  test "the background and the consent image are externalised" do
    s = survey
    s.update!(background_image: DATA_URL, consent_image: DATA_URL)

    s.reload
    assert_match STORED, s.read_attribute(:background_image)
    assert_match STORED, s.read_attribute(:consent_image)
  end

  # The create path has no id to attach a blob to, so it converts immediately
  # after instead — base64 is in the column for one write, not indefinitely.
  test "a deck created with inline images is converted on create" do
    s = survey(cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                          "options" => %w[Yes No], "image" => DATA_URL } ])

    assert_match STORED, s.reload.cards.first["image"]
    assert_not_includes s.cards.to_json, "data:image/"
  end

  test "duplicating a deck that still holds base64 does not copy the base64 forward" do
    legacy = survey
    legacy.update_columns(cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                                     "options" => %w[Yes No], "image" => DATA_URL } ])

    copy = legacy.reload.duplicate!
    assert_match STORED, copy.reload.cards.first["image"]
  end

  # ── What it must NOT do ───────────────────────────────────────────────────

  test "already-stored paths and remote URLs are untouched" do
    s = survey
    s.update!(cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No],
                         "image" => "https://images.pexels.com/photos/1/x.jpg" } ])
    before = s.reload.cards.to_json

    s.update!(title: "Renamed")
    assert_equal before, s.reload.cards.to_json
    assert_equal 0, s.card_images.attachments.size, "nothing to store, nothing stored"
  end

  test "an undecodable image is left in place rather than blanked" do
    junk = "data:image/png;base64,!!!not-base64!!!"
    s = survey
    s.update!(cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                         "options" => %w[Yes No], "image" => junk } ])

    assert_equal junk, s.reload.cards.first["image"], "a broken image is worse than a fat one"
  end

  test "a save that doesn't touch images doesn't walk the deck" do
    s = survey(cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])

    called = false
    s.define_singleton_method(:externalized_cards) { called = true; nil }
    s.update!(title: "Just a rename")

    assert_not called, "only the attributes actually being written are inspected"
  end

  test "a published Verto's deck is not reshaped by the conversion" do
    s = survey
    s.update_columns(cards: [ { "type" => "range", "cid" => "c_r", "text" => "Q",
                                "options" => %w[Low Mid High], "image" => DATA_URL } ],
                     publish_token: SecureRandom.hex(8), published_at: Time.current)
    before_options = s.reload.cards.first["options"]

    s.update!(consent_image: DATA_URL)   # a save that is allowed on a live Verto

    assert_equal before_options, s.reload.cards.first["options"],
                 "range normalisation must not fire as a side effect"
  end

  # stub_method, not define_singleton_method + remove_method: attach is a real
  # `def self.attach`, so removing it deletes it outright and every later test in
  # the process loses it.
  test "a storage failure never blocks the save" do
    s = survey
    stub_method(Survey::CardImageStore, :attach, ->(*) { raise "storage down" }) do
      assert_nothing_raised do
        s.update!(cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                             "options" => %w[Yes No], "image" => DATA_URL } ])
      end
    end

    assert_equal DATA_URL, s.reload.cards.first["image"], "the image survives, unconverted"
  end
end
