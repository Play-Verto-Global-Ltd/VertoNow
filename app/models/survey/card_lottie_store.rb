# Turns a pasted LottieFiles URL into an Active Storage blob attached to a
# Verto, scrubbed and served same-origin — through the blob PROXY route, not
# the redirect one (Survey.lottie_proxy_path says why: the redirect's 302
# lands on the bucket, and an XHR cannot read a cross-origin response there).
#
# Hotlinking the JSON was rejected deliberately: lottie-web loads `path:` URLs
# with XHR, which the CSP's connect_src (rightly) confines to our own origin —
# and a respondent's player would depend on a third party staying up and
# keeping the file. Fetching once at paste time sidesteps all of it, and gives
# us exactly one place to scrub the animation before anything renders it.
#
# The scrub matters: the vendored lottie-web is the FULL build, expressions
# enabled — Lottie JSON can carry JS-like expression strings ("x" properties)
# that the player evaluates. Third-party animation data is executable-ish
# content until those are gone. Embedded remote asset URLs are dropped for the
# same reason the JSON itself isn't hotlinked.
class Survey
  module CardLottieStore
    # Direct animation links from the LottieFiles family of hosts only — the
    # same host-allowlist posture sanitize_image_url takes with Pexels. Both
    # extensions the family serves are accepted: plain `.json`, and `.lottie`
    # (dotLottie — a ZIP wrapping the same JSON plus its images). A dotLottie is
    # unpacked to plain JSON at paste time (see unpack_dotlottie), so everything
    # downstream — the shape check, scrub!, the blob's .json filename,
    # ACTIVE_STORAGE_LOTTIE_URL and lottie-web itself — only ever sees JSON and
    # needed no changes. lottie-web cannot decode a ZIP, so converting on the
    # way in is what makes the format work at all.
    SOURCE_URL = %r{\Ahttps://(?:lottie\.host|assets(?:-v\d+|\d*)\.lottiefiles\.com)/[\w\-./%]+\.(?:json|lottie)(?:\?[\w%\-=&.]*)?\z}i

    MAX_BYTES        = 2.megabytes
    FETCH_TIMEOUT    = 10 # seconds, per phase (open/read)
    CONTENT_TYPE     = "application/json"

    # dotLottie archives are small by nature (one animation + its images). The
    # caps are zip-bomb guards, not format limits: a 2 MB download is allowed to
    # inflate to at most MAX_BYTES in total, across at most this many entries.
    # Both are checked BEFORE reading an entry, so a crafted archive is refused
    # rather than expanded.
    DOTLOTTIE_MAX_ENTRIES = 64

    # Image types a dotLottie may inline into the animation. Anything else in
    # the archive is ignored — the animation still renders, minus that asset.
    DOTLOTTIE_IMAGE_TYPES = {
      ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
      ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml"
    }.freeze

    def self.source_url?(value)
      value.to_s.strip.match?(SOURCE_URL)
    end

    # Fetch → validate → scrub → attach. Returns the blob, or nil for any
    # failure — like CardImageStore, the reason isn't actionable to a creator
    # beyond "that link didn't work", so callers get one fallback path.
    def self.fetch_and_attach(survey, url)
      v = url.to_s.strip
      return nil unless source_url?(v)

      body = fetch(v)
      return nil if body.nil? || body.bytesize > MAX_BYTES

      # A .lottie is a ZIP; unpack it to the plain JSON the rest of this method
      # (and everything downstream) already handles. Nil here means a malformed
      # or oversized archive, which fails exactly like a bad URL.
      if dotlottie_url?(v)
        body = unpack_dotlottie(body)
        return nil if body.nil?
      end

      json = begin
        JSON.parse(body)
      rescue JSON::ParserError
        return nil
      end
      # Minimal Lottie shape: a version and a layer list. Anything else is not
      # an animation, whatever the URL claimed.
      return nil unless json.is_a?(Hash) && json.key?("v") && json["layers"].is_a?(Array)

      scrub!(json)

      blob = ActiveStorage::Blob.create_and_upload!(
        io:           StringIO.new(JSON.generate(json)),
        # The .json extension matters: Survey::ACTIVE_STORAGE_LOTTIE_URL only
        # accepts blob paths ending in .json, so a name without it would be
        # sanitized straight back out of the card.
        filename:     "card-lottie-#{SecureRandom.hex(8)}.json",
        content_type: CONTENT_TYPE
      )
      survey.card_images.attach(blob)
      blob
    end

    def self.dotlottie_url?(value)
      URI.parse(value.to_s).path.to_s.downcase.end_with?(".lottie")
    rescue URI::InvalidURIError
      false
    end

    # A dotLottie is a ZIP holding `manifest.json`, one or more
    # `animations/<id>.json`, and optionally the images those animations
    # reference under `images/`. Returns the first animation as a JSON string
    # with its images inlined as data: URIs, or nil if the archive is malformed,
    # over the caps, or holds no animation.
    #
    # Inlining matters: the animation references its images by RELATIVE path
    # inside the archive, and once the JSON is stored on its own those paths
    # resolve to nothing. scrub! only blanks REMOTE asset URLs, so without this
    # a dotLottie with images would render with holes rather than being caught.
    def self.unpack_dotlottie(body)
      # NB the block's value is NOT the return value here — Zip::File.open_buffer
      # hands back the buffer it was given — so the result is carried out in a
      # local rather than falling off the end of the block.
      out = nil
      Zip::File.open_buffer(StringIO.new(body)) do |zip|
        next if zip.size > DOTLOTTIE_MAX_ENTRIES

        # Budget the INFLATED bytes across every entry we read, checking each
        # declared size before extracting it. A zip bomb is refused rather than
        # expanded into memory.
        budget = MAX_BYTES
        read   = lambda do |entry|
          return nil if entry.nil? || entry.size > budget
          budget -= entry.size
          entry.get_input_stream.read
        end

        animation = zip.find { |e| e.file? && e.name.match?(%r{\Aanimations/.+\.json\z}i) }
        raw       = read.call(animation)
        next if raw.nil?

        json = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end
        next unless json.is_a?(Hash)

        inline_dotlottie_images!(json, zip, read)
        out = JSON.generate(json)
      end
      out
    rescue StandardError
      # Not a readable ZIP (or it blew up mid-extract) — same "that link didn't
      # work" path every other failure here takes.
      nil
    end

    # Rewrite each asset that points at a file inside the archive to a data:
    # URI of that file's bytes. Assets we can't resolve are left alone for
    # scrub! to deal with.
    def self.inline_dotlottie_images!(json, zip, read)
      Array(json["assets"]).each do |asset|
        next unless asset.is_a?(Hash)
        name = "#{asset['u']}#{asset['p']}"
        next if name.blank? || name.start_with?("data:", "http://", "https://")

        entry = zip.find { |e| e.file? && e.name.downcase.end_with?(File.basename(name).downcase) }
        type  = DOTLOTTIE_IMAGE_TYPES[File.extname(name).downcase]
        next if entry.nil? || type.nil?

        bytes = read.call(entry)
        next if bytes.nil?

        asset["u"] = ""
        asset["p"] = "data:#{type};base64,#{Base64.strict_encode64(bytes)}"
        asset["e"] = 1 # tells lottie-web the payload is embedded, not a path
      end
      json
    end

    # GET the URL with no redirect following (a redirect off the allowlisted
    # host is exactly what the allowlist exists to prevent). Returns the body
    # string or nil. Split out as the test seam — everything around it is pure.
    def self.fetch(url)
      uri = URI.parse(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                            open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      res.is_a?(Net::HTTPOK) ? res.body : nil
    rescue StandardError
      nil
    end

    # In place, recursively:
    #   • drop every "x" key holding a String — that's where Lottie keeps
    #     expression code (numeric/array/hash "x" values are ordinary
    #     animation data and survive);
    #   • blank every asset "u"/"p" pair that points at a remote host, so the
    #     stored animation never phones out at render time (data: and
    #     embedded base64 payloads survive — the CSP already allows data:
    #     images).
    def self.scrub!(node)
      case node
      when Hash
        node.delete("x") if node["x"].is_a?(String)
        if node["u"].is_a?(String) && node["u"].match?(%r{\Ahttps?://}i)
          node["u"] = ""
          node["p"] = "" unless node["p"].to_s.start_with?("data:")
        end
        node["p"] = "" if node["p"].is_a?(String) && node["p"].match?(%r{\Ahttps?://}i)
        node.each_value { |v| scrub!(v) }
      when Array
        node.each { |v| scrub!(v) }
      end
      node
    end
  end
end
