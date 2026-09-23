# Direct bucket URLs for the attachments the public player draws.
#
# Cards store their imagery as same-origin Active Storage paths
# (/rails/active_storage/blobs/redirect/<signed_id>/<filename> — what the
# editor's upload returns) and the play page draws the organisation logo through
# the proxy route. Both cost a Rails request per image per respondent: the
# redirect route answers a 302 to a presigned bucket URL, the proxy route
# streams the bytes. Run 22 (docs/SCALE_AND_COST_PLAN.md §2b) measured that at
# 80 arrivals/s a six-image deck turned those into ~670 requests/s — 60% of all
# traffic on the web tier — for work the bucket can do by itself.
#
# When uploads live in the bucket (ObjectStorage.bucket_active?), the player
# render swaps each such path for the presigned URL the redirect would have
# issued, so the browser fetches the bytes straight from the bucket and Rails
# never sees the image request. Everything else — Pexels URLs, data: URLs, a
# path that doesn't resolve — passes through untouched, and on the local disk
# nothing changes at all. Any failure to build a URL also passes the original
# through: a broken presign must degrade to the old same-origin path, never
# take the play page down.
#
# Only the player does this. Editor, preview and dashboard keep the same-origin
# paths: they are not cached, and the proxy keeps their images inside 'self'.
module PlayerAssetUrls
  module_function

  # The rendered play page is cached for PlayerController::PLAYER_PAGE_TTL and
  # may be served up to race_condition_ttl beyond that, so a URL baked into it
  # has to outlive the page. Twice the page TTL leaves a clear margin
  # (test/lib/player_asset_urls_test.rb pins the relationship).
  TTL = 2.hours

  BLOB_PATH = %r{\A/rails/active_storage/blobs/(?:redirect|proxy)/([^/?]+)/}

  # Card keys holding a single image URL the player paints (shared/_split_left).
  # "lottie" is deliberately absent: it is JSON the player fetch()es, and a
  # cross-origin fetch would need CORS on the bucket, so it stays same-origin.
  IMAGE_KEYS = %w[image video_poster].freeze

  def active?
    ObjectStorage.bucket_active?
  end

  # A copy of the card with its image URLs made direct — `image`, `video_poster`,
  # the per-option `images` array, the header backdrop `media_bg.image` and the
  # mobile background `mobile_bg.image`. Returns the card itself when there is
  # nothing to do.
  BACKDROP_KEYS = %w[media_bg mobile_bg].freeze

  def direct_card(card)
    return card unless active? && card.is_a?(Hash)

    out = card.dup
    IMAGE_KEYS.each { |key| out[key] = direct(out[key]) if out[key].is_a?(String) }
    if out["images"].is_a?(Array)
      out["images"] = out["images"].map { |url| url.is_a?(String) ? direct(url) : url }
    end
    BACKDROP_KEYS.each do |key|
      next unless out[key].is_a?(Hash) && out[key]["image"].is_a?(String)
      out[key] = out[key].merge("image" => direct(out[key]["image"]))
    end
    out
  end

  # A same-origin blob path → the blob's own (presigned) URL; anything else,
  # and anything that cannot be resolved or signed, → itself.
  def direct(url)
    return url unless active?

    signed_id = BLOB_PATH.match(url.to_s)&.captures&.first or return url
    blob = ActiveStorage::Blob.find_signed(signed_id) or return url
    blob.url(expires_in: TTL)
  rescue StandardError => e
    Rails.logger.warn("[PlayerAssetUrls] keeping same-origin path for #{url.to_s[0, 80]}: #{e.class}: #{e.message}")
    url
  end

  # The URL to draw an attachment (the organisation logo) from: its own
  # presigned URL on the bucket, the given same-origin proxy path otherwise.
  def attachment_url(attachment, proxy_path:)
    return proxy_path unless active? && attachment&.attached?

    attachment.blob.url(expires_in: TTL)
  rescue StandardError => e
    Rails.logger.warn("[PlayerAssetUrls] keeping proxy path for #{proxy_path}: #{e.class}: #{e.message}")
    proxy_path
  end
end
