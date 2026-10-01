# Be sure to restart your server when you modify this file.

# Content Security Policy — pragmatic, enforcing.
#
# script-src deliberately keeps 'unsafe_inline' because the dashboard/editor use
# many inline event handlers (onclick/onmouseover/onchange across ~12 views) and
# a few inline <script> blocks; a nonce-based policy would require refactoring
# every one of those first. Even so, this still meaningfully hardens the app:
# only same-origin scripts may load (no third-party script host is allowlisted
# — Microsoft Clarity, the one there was, left the platform 2026-10-01), no
# plugins, no foreign framing, and forms/connections are restricted.
#
# Path to a stronger policy: refactor inline on*= handlers to Stimulus/CSS, then
# switch script_src to :self + a nonce (config.content_security_policy_nonce_*).
# The Active Storage bucket, once configured (STORAGE_BUCKET set — see
# config/storage.yml). Redirect-mode blob URLs (rails_blob_path: every card
# image) answer with a 302 to a presigned URL on the bucket's host, and the
# browser checks img-src / connect-src against that redirect TARGET as well
# as the original request, so the bucket's origin has to be allowed wherever
# an attachment may load. Empty on local disk. lib/ + an explicit require,
# because reloadable app/ constants can't be referenced at boot.
require Rails.root.join("lib/object_storage_origins")

Rails.application.configure do
  config.content_security_policy do |policy|
    bucket_origins = ObjectStorageOrigins.allowed

    policy.default_src      :self
    policy.base_uri         :self
    policy.object_src       :none
    # accounts.google.com: the Google sign-in button POSTs same-origin to
    # /auth/google_oauth2, but Chrome also enforces form-action against the
    # redirect that same-origin response issues (to Google's consent screen),
    # not just the initial submission target — without this the browser
    # silently aborts the redirect and the button appears to do nothing.
    policy.form_action      :self, "https://accounts.google.com"
    policy.frame_ancestors  :self # matches the existing X-Frame-Options: SAMEORIGIN

    # Inline scripts/handlers stay allowed; no external script host is. Adding
    # a tracker here means adding the consent it needs first — see
    # docs/TOOLING_AND_VENDORS.md §6. 'unsafe_eval' is added in development
    # only, for web-console's REPL.
    script_src = [ :self, :unsafe_inline ]
    script_src << :unsafe_eval if Rails.env.development?
    policy.script_src(*script_src)

    # Inline styles are used throughout the app. Webfonts (ABeeZee, Alata) are
    # self-hosted under public/fonts/ (see app/assets/tailwind/application.css)
    # rather than loaded from Google's CDN, so no external font host is needed.
    policy.style_src  :self, :unsafe_inline
    policy.font_src   :self, :data

    # App assets + Active Storage logos (self), survey background data: URLs,
    # and Pexels stock photos (editor media picker + auto-populated Verto
    # imagery, served from the Pexels image CDN).
    #
    # blob: — media_picker_controller.js decodes every upload (downscale +
    # the 2.10 crop stage) by pointing an Image() at URL.createObjectURL(file).
    # Without this, the browser blocks that fetch under img-src (confirmed via
    # a captured securitypolicyviolation event, directive "img-src", blocked
    # "blob"), img.onload silently never fires, and decode falls through to
    # onerror's raw-file fallback — meaning every upload was storing the
    # original, undownscaled file as a data URL instead of the compressed
    # MAX_EDGE-capped re-encode the comment two blocks up says this exists to
    # produce. That fallback exists for genuinely exotic formats a canvas
    # can't decode, not as the path every ordinary JPEG/PNG silently took.
    policy.img_src    :self, :data, :blob, "https://images.pexels.com", *bucket_origins

    # Pexels stock videos stream from the Pexels video CDN (autoplaying card
    # art). Without this the browser blocks the <video>, like img_src did for
    # photos. If clips ever come from another host, add it here.
    policy.media_src  :self, "https://videos.pexels.com", *bucket_origins

    # XHR/fetch: same-origin app endpoints and the Pexels CDNs.
    #
    # Pexels belongs here as well as in img_src/media_src because the service
    # worker refetches card art through the Fetch API, and a fetch() is governed
    # by connect-src no matter what it's fetching. Without it the worker's own
    # request was refused before it left the browser ("Fetch API cannot load
    # https://images.pexels.com/… Refused to connect"), imageCache rejected, and
    # every Pexels-backed card panel rendered empty — the Verto's brand colour
    # showing through where the photo should be. img_src alone only covers the
    # <img>/CSS load the worker had already intercepted.
    policy.connect_src :self, "https://images.pexels.com", "https://videos.pexels.com", *bucket_origins

    policy.worker_src   :self
    policy.manifest_src :self
  end
end
