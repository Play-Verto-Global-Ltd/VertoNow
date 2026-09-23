require "test_helper"

class PlayerAssetUrlsTest < ActiveSupport::TestCase
  setup do
    # What ActiveStorage::SetCurrent provides inside a request: the Disk
    # service (the suite's storage) needs it to build a blob's own URL.
    ActiveStorage::Current.url_options = { host: "www.example.com" }
    @blob          = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("png"), filename: "card.png", content_type: "image/png")
    @redirect_path = Rails.application.routes.url_helpers.rails_blob_path(@blob, only_path: true)
    @proxy_path    = Rails.application.routes.url_helpers.rails_storage_proxy_path(@blob, only_path: true)
  end

  def on_bucket(&block)
    stub_method(ObjectStorage, :bucket_active?, true, &block)
  end

  # On the suite's Disk service a blob's own URL is the disk route — distinct
  # from the redirect/proxy routes, which is all these tests need to see.
  OWN_URL = %r{\Ahttp://www\.example\.com/rails/active_storage/disk/}

  test "on the local disk nothing is rewritten" do
    card = { "type" => "multiple_choice", "image" => @redirect_path }
    assert_same card, PlayerAssetUrls.direct_card(card)
    assert_equal @redirect_path, PlayerAssetUrls.direct(@redirect_path)
  end

  test "on the bucket a redirect or proxy blob path becomes the blob's own URL" do
    on_bucket do
      assert_match OWN_URL, PlayerAssetUrls.direct(@redirect_path)
      assert_match OWN_URL, PlayerAssetUrls.direct(@proxy_path)
    end
  end

  test "rewrites every image-bearing key on a copy of the card and leaves the rest alone" do
    lottie = "/rails/active_storage/blobs/redirect/#{@blob.signed_id}/anim.json"
    card = { "type" => "range", "text" => "hi", "image" => @redirect_path, "video_poster" => @proxy_path,
             "images" => [ @redirect_path, "https://images.pexels.com/x.jpg", nil ],
             "media_bg" => { "color" => "#fff", "image" => @redirect_path },
             "mobile_bg" => { "image" => @proxy_path, "ink" => "dark" }, "lottie" => lottie }

    on_bucket do
      out = PlayerAssetUrls.direct_card(card)

      refute_same card, out
      assert_match OWN_URL, out["image"]
      assert_match OWN_URL, out["video_poster"]
      assert_match OWN_URL, out["images"][0]
      assert_equal "https://images.pexels.com/x.jpg", out["images"][1]
      assert_nil out["images"][2]
      assert_match OWN_URL, out["media_bg"]["image"]
      assert_equal "#fff", out["media_bg"]["color"]
      assert_match OWN_URL, out["mobile_bg"]["image"], "the mobile background is a picture the phone fetches too"
      assert_equal "dark", out["mobile_bg"]["ink"]
      assert_equal lottie, out["lottie"], "lottie JSON stays same-origin — a cross-origin fetch() would need CORS"
      assert_equal "hi", out["text"]
      assert_equal @redirect_path, card["image"], "the model's own hash is untouched"
    end
  end

  test "an unknown signed id, a foreign URL, a data URL and a blob whose record is gone all pass through" do
    on_bucket do
      bogus = "/rails/active_storage/blobs/redirect/not-a-signature/x.png"
      assert_equal bogus, PlayerAssetUrls.direct(bogus)
      assert_equal "https://images.pexels.com/a.jpg", PlayerAssetUrls.direct("https://images.pexels.com/a.jpg")
      assert_equal "data:image/png;base64,AAAA", PlayerAssetUrls.direct("data:image/png;base64,AAAA")
      assert_nil PlayerAssetUrls.direct(nil)

      ActiveStorage::Blob.where(id: @blob.id).delete_all # the row, not the file (Blob#delete removes the file)
      assert_equal @redirect_path, PlayerAssetUrls.direct(@redirect_path)
    end
  end

  test "a URL that cannot be built falls back to the same-origin path instead of failing the page" do
    ActiveStorage::Current.url_options = nil # the Disk service raises without it
    on_bucket { assert_equal @redirect_path, PlayerAssetUrls.direct(@redirect_path) }
  end

  test "the asset TTL outlives the cached play page" do
    assert_operator PlayerAssetUrls::TTL, :>=, PlayerController::PLAYER_PAGE_TTL * 2
  end

  test "the logo is presigned only on the bucket" do
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(3)}")
    org.logo.attach(io: StringIO.new("png"), filename: "logo.png", content_type: "image/png")

    assert_equal "/proxy/logo", PlayerAssetUrls.attachment_url(org.logo, proxy_path: "/proxy/logo")
    on_bucket { assert_match OWN_URL, PlayerAssetUrls.attachment_url(org.logo, proxy_path: "/proxy/logo") }
    on_bucket { assert_equal "/proxy/logo", PlayerAssetUrls.attachment_url(nil, proxy_path: "/proxy/logo") }
  end
end
