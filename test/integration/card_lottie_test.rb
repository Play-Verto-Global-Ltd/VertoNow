require "test_helper"

# The pasted-LottieFiles-URL feature end to end: the ingest endpoint's guards,
# and the animation actually rendering — in the editor (with its Change-media
# CTA intact) and for respondents on the player.
class CardLottieTest < ActionDispatch::IntegrationTest
  ANIMATION = { "v" => "5.7.4", "fr" => 30, "layers" => [ { "ty" => 4 } ] }.freeze

  def setup
    @org  = Organisation.create!(name: "Anim", slug: "anim-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "A", email_address: "an-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Anim", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "cid" => "c1", "text" => "Q", "options" => %w[a b] } ]
    )
  end

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  # Swap the HTTP GET for a canned body (see CardLottieStoreTest for why this
  # is hand-rolled rather than Minitest::Mock).
  def with_fetch(body)
    mod = Survey::CardLottieStore
    original = mod.method(:fetch)
    mod.define_singleton_method(:fetch) { |_url| body }
    yield
  ensure
    mod.singleton_class.remove_method(:fetch)
    mod.define_singleton_method(:fetch, original)
  end

  def post_lottie(url)
    post card_lottie_survey_path(@survey), params: { url: url }.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  test "a LottieFiles URL is stored and handed back as a same-origin PROXY path" do
    sign_in
    with_fetch(JSON.generate(ANIMATION)) { post_lottie("https://lottie.host/abc/anim.json") }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"], "expected the ingest to succeed, got: #{body['error']}"
    # The proxy route, not rails_blob_path's redirect. lottie-web reads the
    # JSON by XHR, and once uploads live in the bucket the redirect's 302
    # lands cross-origin with no CORS header — the browser refuses the body,
    # the player fires data_failed, and the creator sees the dashed "could not
    # load" outline for a paste the server accepted (2026-09-25, Riders).
    assert_match %r{\A/rails/active_storage/blobs/proxy/}, body["url"],
                 "the card must receive OUR proxy path, never a redirect and never the third-party URL"
    assert_equal body["url"], Survey.sanitize_lottie_url(body["url"]),
                 "what the endpoint returns must survive the cards sanitiser"
  end

  test "the stored animation is served same-origin as JSON in one hop" do
    sign_in
    with_fetch(JSON.generate(ANIMATION)) { post_lottie("https://lottie.host/abc/anim.json") }
    stored = JSON.parse(response.body)["url"]

    get stored
    assert_response :success, "a redirect here is the bucket 302 an XHR cannot follow"
    assert_equal "application/json", response.media_type
    assert_equal ANIMATION, JSON.parse(response.body)
  end

  # Every animation pasted before the proxy switch is stored in the redirect
  # form. Rewriting on render is what fixes those cards without a re-save, and
  # the editor's data attribute is what an autosave sends back — so it carries
  # the proxy form too, and the next save converges.
  test "an animation stored as a redirect path renders and autosaves as the proxy path" do
    sign_in
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(JSON.generate(ANIMATION)),
      filename: "card-lottie-legacy.json", content_type: "application/json"
    )
    @survey.card_images.attach(blob)
    redirect = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    proxy    = Rails.application.routes.url_helpers.rails_storage_proxy_path(blob, only_path: true)
    assert_match %r{/blobs/redirect/}, redirect, "sanity: the legacy form is the redirect one"

    cards = @survey.cards
    cards[0] = cards[0].merge("lottie" => redirect)
    @survey.update_columns(cards: cards) # past the sanitiser, as the old rows are

    get survey_path(@survey)
    assert_response :success
    assert_select ".card-lottie[data-lottie-player-urls-value=?]", [ proxy ].to_json
    assert_select "[data-card-lottie=?]", proxy

    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert_select ".card-lottie[data-lottie-player-urls-value=?]", [ proxy ].to_json
    assert_select "[data-lottie-player-urls-value*=?]", "/blobs/redirect/", count: 0
  end

  test "a non-LottieFiles URL is refused" do
    sign_in
    with_fetch(JSON.generate(ANIMATION)) { post_lottie("https://evil.example.com/anim.json") }

    assert_response :unprocessable_entity
    refute JSON.parse(response.body)["ok"]
  end

  test "a live Verto refuses the ingest like every other structural edit" do
    sign_in
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    with_fetch(JSON.generate(ANIMATION)) { post_lottie("https://lottie.host/abc/anim.json") }

    assert_response :locked
  end

  test "the endpoint is closed to signed-out visitors" do
    with_fetch(JSON.generate(ANIMATION)) { post_lottie("https://lottie.host/abc/anim.json") }
    assert_response :redirect
  end

  test "a card's animation renders for respondents and in the editor" do
    sign_in
    stored = nil
    with_fetch(JSON.generate(ANIMATION)) { post_lottie("https://lottie.host/abc/anim.json") }
    stored = JSON.parse(response.body)["url"]

    cards = @survey.cards
    cards[0] = cards[0].merge("lottie" => stored)
    @survey.update!(cards: cards)

    # Editor: the animation mounts, looping, and the Change-media CTA stays —
    # swapping back to a photo has to remain possible.
    get survey_path(@survey)
    assert_response :success
    assert_select ".card-lottie[data-controller='lottie-player'][data-lottie-player-loop-value='true']", 1
    assert_select ".card-lottie [data-lottie-player-target='mount']", 1
    assert_select ".split-left .add-media-fab", 1
    assert_select "[data-card-lottie=?]", stored

    # Player: same partial, so respondents get the same mount.
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert_select ".card-lottie[data-lottie-player-loop-value='true']", 1
    assert_select ".card-lottie [data-lottie-player-target='mount']", 1
  end

  test "an autosave carrying an animation drops the card's photo" do
    sign_in
    with_fetch(JSON.generate(ANIMATION)) { post_lottie("https://lottie.host/abc/anim.json") }
    stored = JSON.parse(response.body)["url"]

    patch survey_path(@survey),
          params: { cards: [ { "type" => "multiple_choice", "cid" => "c1", "text" => "Q",
                               "options" => %w[a b], "lottie" => stored,
                               "image" => "/assets/verto-library/backgrounds/nature.jpg" } ] }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :success
    card = @survey.reload.cards.first
    assert_equal stored, card["lottie"]
    refute card.key?("image"), "an animation replaces the photo, as the editor shows it"
  end
end
