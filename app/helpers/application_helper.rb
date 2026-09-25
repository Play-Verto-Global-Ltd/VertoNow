module ApplicationHelper
  # Whether the "Connect to Google Sheets" results export is available (OAuth
  # client configured). Used to hide the button when it can't work.
  def google_sheets_configured?
    GoogleOauthService.configured?
  end

  # Rating answer-type icon, themed to the Verto. The classic star is the
  # default; a Verto whose subject matches one of these keyword groups rates in
  # an icon that fits it — a "space" Verto in rockets, a "food" Verto in
  # burgers, and so on.
  #
  # Matching (see #rating_icon): the signal is the theme PLUS the title and
  # key_insight, tokenised to whole words and singularised so plurals/variants
  # (rockets, fans, dogs…) hit without being hand-listed. The group with the
  # most keyword hits wins (ties break on the order below), so a mixed brief
  # resolves to its dominant subject rather than whichever keyword is listed
  # first. Keywords here are written singular; both sides are singularised so
  # the lists stay short.
  #
  # The ★/☆ star is a monochrome glyph coloured by CSS (grey → gold). Emoji
  # ignore CSS `color`, so they instead render full-colour when active and
  # dim/greyscale when not — hence the `kind` the views/JS switch on.
  RATING_ICON_THEMES = [
    [ %w[space rocket astronaut galaxy cosmos cosmic planet orbit moon mars spacecraft], "🚀" ],
    [ %w[football soccer fifa], "⚽" ],
    [ %w[basketball nba hoop], "🏀" ],
    [ %w[sport fitness gym workout athlete training exercise running marathon], "💪" ],
    [ %w[food eat eating meal restaurant cuisine snack dinner lunch breakfast cooking recipe nutrition], "🍔" ],
    [ %w[coffee cafe barista espresso], "☕" ],
    [ %w[nature climate environment environmental eco sustainability sustainable green earth recycling carbon], "🌍" ],
    [ %w[plant garden gardening flower bloom growth tree forest], "🌱" ],
    [ %w[health wellness wellbeing medical mental healthcare], "❤️" ],
    [ %w[love dating relationship romance valentine wedding marriage], "❤️" ],
    [ %w[music song concert band audio festival playlist gig album], "🎵" ],
    [ %w[money finance financial budget invest investing bank banking salary saving economy economic spending], "💰" ],
    [ %w[travel holiday vacation trip flight tourism adventure destination hotel], "✈️" ],
    [ %w[game gaming gamer esport arcade console], "🎮" ],
    [ %w[movie film cinema tv television streaming show series], "🎬" ],
    [ %w[book reading library education school learning study student teaching academic college university], "📚" ],
    [ %w[pet dog cat animal wildlife veterinary], "🐾" ],
    [ %w[car auto vehicle driving motor automotive], "🚗" ],
    [ %w[tech technology software app digital computer coding data], "💻" ],
    [ %w[fashion style clothing beauty makeup outfit apparel], "👗" ],
    [ %w[water ocean sea beach surf marine river lake], "🌊" ],
    [ %w[party celebration festive birthday], "🎉" ],
    [ %w[work career job business office professional workplace employee], "💼" ],
    [ %w[home house property housing rent mortgage interior], "🏠" ],
    [ %w[news politics political election vote government policy], "📰" ],
    [ %w[science research scientific experiment lab physics chemistry biology], "🔬" ],
    [ %w[art design creative drawing painting illustration], "🎨" ],
    [ %w[photography photo camera photographer], "📷" ],
    [ %w[social media instagram tiktok influencer content], "📱" ]
  ].map { |keywords, glyph| [ keywords.map { |w| w.singularize }.to_set, glyph ] }.freeze

  STAR_RATING_ICON = { on: "★", off: "☆", kind: "star" }.freeze

  # The NPS "liquid container" silhouette, themed per Verto so the scale leans
  # into brand alignment. Maps to a CSS class `nps-shape-<name>`.
  #
  # Resolution (see #nps_container_shape): a themed subject picks a FITTING
  # vessel first — a science Verto fills a conical flask, a coffee Verto a mug,
  # a space Verto a capsule (tube), a food Verto a jar, and so on (whole-word,
  # singularised match, like rating_icon). Anything without a subject match
  # falls back to a stable shape from a digest of the theme, so every Verto is
  # still consistent and the fuller set stays in rotation.
  # Only genuine VESSEL silhouettes — they read correctly at the tall, narrow
  # NPS container aspect. (Object shapes like a lightbulb/rocket/battery stretch
  # into unrecognisable blobs when squeezed into that ratio, so they're out.)
  NPS_CONTAINER_SHAPES = %w[
    pill glass tube popsicle bottle flask mug jar can beaker
  ].freeze

  # Ordered — the first group with a keyword hit wins, so put the more specific
  # subjects before the broader ones. Every target is a real container.
  NPS_SHAPE_THEMES = [
    [ %w[space rocket astronaut galaxy planet cosmos cosmic orbit moon mars spacecraft launch], "tube" ],
    [ %w[chemistry chemical molecule reaction], "beaker" ],
    [ %w[science lab laboratory research experiment biology physics medical health wellness], "flask" ],
    [ %w[idea innovation creativity inspiration insight brainstorm discovery], "flask" ],
    [ %w[energy power electric electricity charge charging renewable solar], "bottle" ],
    [ %w[coffee cafe tea beverage barista espresso latte], "mug" ],
    [ %w[soda cola beer fizzy lager cider], "can" ],
    [ %w[food nutrition meal cooking recipe kitchen jam honey pickle], "jar" ],
    [ %w[water ocean sea river lake climate environment environmental sustainability eco nature fitness sport gym], "bottle" ],
    [ %w[ice summer treat dessert sweet lolly], "popsicle" ],
    [ %w[juice smoothie cocktail wine party celebration festival], "glass" ]
  ].map { |keywords, shape| [ keywords.map { |w| w.singularize }.to_set, shape ] }.freeze

  def nps_container_shape(survey)
    theme = survey&.theme.to_s.strip.downcase
    return NPS_CONTAINER_SHAPES.first if theme.empty?

    words = theme.scan(/[a-z]+/).map { |w| w.singularize }.to_set
    match = NPS_SHAPE_THEMES.find { |keywords, _| (words & keywords).any? }
    return match[1] if match

    idx = Integer(Digest::SHA256.hexdigest(theme)[0, 8], 16) % NPS_CONTAINER_SHAPES.size
    NPS_CONTAINER_SHAPES[idx]
  end

  # Inline SVG for a tap-card (Swipe Cards) response button. The three
  # responses used raw emoji (👍 / 👎 / ☝), but the "unsure" glyph (U+261D) has
  # default TEXT presentation and renders as a monochrome/tofu box on many
  # devices — so the deck looked like it had no icons. These SVGs use
  # `currentColor`, so the per-response border colour (red / amber / green set
  # on .rotate-action-* in application.css) tints them, and they render
  # identically everywhere, matching the app's other inline-SVG icons.
  TAP_RESPONSE_ICONS = {
    "yes" => %(<path d="M1 21h4V9H1v12zm22-11c0-1.1-.9-2-2-2h-6.31l.95-4.57.03-.32c0-.41-.17-.79-.44-1.06L14.17 1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73v-1z"/>),
    "no"  => %(<path d="M15 3H6c-.83 0-1.54.5-1.84 1.22l-3.02 7.05c-.09.23-.14.47-.14.73v1c0 1.1.9 2 2 2h6.31l-.95 4.57-.03.32c0 .41.17.79.44 1.06L9.83 23l6.59-6.59c.36-.36.58-.86.58-1.41V5c0-1.1-.9-2-2-2zm4 0v12h4V3h-4z"/>),
    "unsure" => %(<path d="M11 18h2v-2h-2v2zm1-16C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4z"/>)
  }.freeze

  def tap_response_icon(kind)
    path = TAP_RESPONSE_ICONS[kind.to_s] || TAP_RESPONSE_ICONS["unsure"]
    %(<svg class="rotate-action-icon" viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true" focusable="false">#{path}</svg>).html_safe
  end

  # The mark on one response button, from a TapScales.for_card entry. Same
  # precedence as option_tile_icon above — a creator's explicit pick beats
  # anything the scale supplies — with the built-in swipe glyph standing in for
  # the keyword lookup, because a response is a point on a scale and its artwork
  # comes from where it sits, not from what it happens to be called.
  #
  # TapScales has already decided whether this card shows glyphs or emoji (a
  # circle wears the glyph, a pill wears the emoji), so this only picks between
  # what it handed over; nil for the field it didn't fill.
  def tap_response_mark(response, index: 0)
    if (svg = OptionIconLibrary.svg_by_id(response["icon"].to_s))
      svg
    elsif response["emoji"].present?
      emoji_tile_span(response["emoji"])
    elsif response["glyph"].present?
      tap_response_icon(response["glyph"])
    else
      emoji_tile_span(OptionIconLibrary.emoji_for(response["label"], index))
    end
  end

  def rating_icon(survey)
    signal = %i[theme title key_insight]
             .filter_map { |m| survey.public_send(m) if survey.respond_to?(m) }
             .join(" ").downcase
    words = signal.scan(/[a-z]+/).map { |w| w.singularize }.to_set
    return STAR_RATING_ICON if words.empty?

    keywords, glyph = RATING_ICON_THEMES.max_by { |kw, _| (words & kw).size }
    return STAR_RATING_ICON if keywords.nil? || (words & keywords).empty?

    { on: glyph, off: glyph, kind: "emoji" }
  end

  # Minimal per-card, per-locale projection for the editor's inline
  # `#survey-cards-i18n` island. The language-tab JS (survey_editor_controller
  # _seedStore/_normContent) only reads text/description/options per locale, so
  # we deliberately omit image / option_images (multi-MB base64 data URLs) and
  # all structural fields. Without this, every uploaded image was serialised an
  # extra time into the inline <script> on each editor load — pure dead weight,
  # since the cards are already rendered once and carry their image on a data
  # attribute for autosave. Keeps the island to just the translatable text.
  def editor_cards_i18n(cards)
    Array(cards).map { |card| slim_card_i18n(card) }
  end

  def slim_card_i18n(card)
    card = card || {}
    out = {
      "text"        => card["text"],
      "description" => card["description"],
      "options"     => card["options"],
      "pages"       => card["pages"],
      # A tap card's response labels are translatable content too — just the
      # words, not the keys, colours or glyphs, which are language-neutral.
      "responses"   => Array(card["responses"]).map { |r| r.is_a?(Hash) ? r["label"].to_s : "" }.presence,
      # Rich-text layer (primary locale only — translations are plain), so
      # the editor's store starts with the same html the DOM shows.
      # The intro modal's words — respondent-facing copy the language tabs swap
      # like any other, so they ride the store rather than being read back off
      # the DOM alone.
      "modal_title" => card["modal_title"],
      "modal_body"  => card["modal_body"],
      # The NPS anchor lines — the same reason as the modal's words.
      "nps_low_label"  => card["nps_low_label"],
      "nps_high_label" => card["nps_high_label"],
      "text_html"        => card["text_html"],
      "description_html" => card["description_html"],
      "modal_body_html"  => card["modal_body_html"],
      "options_html"     => card["options_html"]
    }
    if card["i18n"].is_a?(Hash)
      out["i18n"] = card["i18n"].transform_values do |tr|
        tr = tr || {}
        { "text" => tr["text"], "description" => tr["description"], "options" => tr["options"],
          "pages" => tr["pages"], "responses" => tr["responses"],
          "modal_title" => tr["modal_title"], "modal_body" => tr["modal_body"],
          "nps_low_label" => tr["nps_low_label"], "nps_high_label" => tr["nps_high_label"] }.compact
      end
    end
    out.compact
  end

  # Returns a view of `card` with text/description/options in `locale`, falling
  # back per-field to the primary (default_locale) content. Structural fields
  # (type, image, allow_other, option count/order) are language-neutral and
  # preserved. Used by the player/preview to display a chosen language; the
  # editor renders the primary card directly.
  def localized_card(card, locale, default_locale = SupportedLocales::DEFAULT)
    return card if locale.blank? || locale.to_s == default_locale.to_s

    tr = card.dig("i18n", locale.to_s)
    return card unless tr.is_a?(Hash)

    base_opts = Array(card["options"])
    loc_opts  = Array(tr["options"])
    # Scenario pages align by id (not index) — unlike options, a creator
    # plausibly reorders narrative pages after translating them, and index
    # alignment would silently scramble which translation goes with which page.
    merged = card.merge(
      "text"        => tr["text"].presence        || card["text"],
      "description" => tr["description"].presence  || card["description"],
      # Keep the primary array's length & order; fall back per slot.
      "options"     => base_opts.each_with_index.map { |o, i| loc_opts[i].presence || o }
    )

    if card["pages"].present?
      base_pages = Array(card["pages"])
      loc_pages  = Array(tr["pages"]).index_by { |p| p.is_a?(Hash) ? p["id"].to_s : nil }
      merged["pages"] = base_pages.map { |p|
        next p unless p.is_a?(Hash)
        translated = loc_pages[p["id"].to_s]
        p.merge("text" => translated&.dig("text").presence || p["text"])
      }
    end

    # Quiz answer feedback, shown to the respondent after they answer — plain
    # scalar, so a straight fall-back to the source string.
    if card["explanation"].present?
      merged["explanation"] = tr["explanation"].presence || card["explanation"]
    end

    # The intro modal's words. Plain scalars like `explanation`, so a straight
    # per-field fall-back to the source. The body's rich-text layer needs no
    # handling here: rich_card_text only paints html when the shown string is
    # still the primary one, so a translated body renders plain by the same
    # rule that already governs a translated question.
    if card["modal_title"].present? || card["modal_body"].present?
      merged["modal_title"] = tr["modal_title"].presence || card["modal_title"]
      merged["modal_body"]  = tr["modal_body"].presence  || card["modal_body"]
    end

    # The anchor lines beside an NPS scale's ends — plain scalars, so the same
    # per-field fall-back as explanation.
    Survey::NPS_ANCHOR_KEYS.each do |k|
      merged[k] = tr[k].presence || card[k] if card[k].present?
    end

    merged
  end

  # All card-type metadata lives in config/card_types.yml. This helper
  # returns the symbol-keyed shape that the existing views were written
  # against, with a graceful fallback for unknown types.
  def card_type_meta(type)
    m = CardTypes.meta(type)
    return { badge: type.to_s.tr("_", " ").upcase, badge_css: "sb-range", q_label: "" } if m.empty?
    { badge: CardTypes.badge(type), badge_css: m["badge_css"], q_label: CardTypes.panel_label(type) }
  end

  # Per-type "how to answer" caption (card_component's `eyebrow`), translated
  # into every language this Verto exists in — not the full app catalog, so
  # the inline blob stays small. Read by survey_editor_controller._writeCard
  # when a translation tab is switched (the editor swaps card text client-side,
  # without a server round-trip — see #survey-cards-i18n) and by
  # type_panel_controller for the primary-locale caption when a card's type
  # changes. Server-rendered cards (editor primary tab, player) get theirs
  # straight from `t` in card_component instead — see display_locale there.
  def card_eyebrows_i18n(survey)
    survey.verto_locales.index_with do |loc|
      CardTypes.all.each_with_object({}) do |(key, attrs), out|
        next if attrs["eyebrow"].blank?
        out[key] = I18n.t("card.eyebrow.#{key}", locale: loc, default: attrs["eyebrow"])
      end.merge(
        # A capped multi-select's caption names the cap instead of the type, so
        # the JS writers need the TEMPLATE per locale — they interpolate it
        # themselves (lib/card_eyebrow.js). Keyed with a leading underscore
        # because every other key here is a real card type and none has one.
        "_max" => I18n.t("card.eyebrow_max", locale: loc, default: "Choose up to %{n}")
      )
    end
  end

  # Placeholder answer options per card type, resolved in the VERTO's default
  # locale (not the viewer's): they become real card content the moment a
  # creator keeps them, so a French Verto edited from an English dashboard
  # still starts its cards in French. Read by lib/default_options.js
  # `defaultOptionsFor` via the `card-defaults` blob; the `defaults:` locale
  # namespace mirrors DEFAULT_OPTIONS there, English fallback included.
  def card_default_options_i18n(survey)
    I18n.t("defaults", locale: survey.default_locale,
                       default: I18n.t("defaults", locale: :en, default: {}))
  end

  # ── Rich text (presentation-only HTML twins of plain card text) ───────────
  # Rendered ONLY when the string being shown is the primary-locale one — a
  # translation (plain by design) renders unformatted rather than wearing the
  # primary text's markup. Re-sanitised at render as defence-in-depth; the
  # stored value already passed clean_equivalent.

  def rich_card_text(card, display, field)
    html = card["#{field}_html"]
    shown = display[field].to_s
    return shown unless html.present? && shown == card[field].to_s

    RichTextSanitizer.clean(html).html_safe
  end

  # Does this card carry an intro modal? Presence of the words IS the flag
  # (Survey.sanitize_cards_images!), so every caller asks the same question the
  # same way rather than each picking a field to test.
  def card_has_modal?(card)
    return false unless card.is_a?(Hash)
    card["modal_title"].to_s.strip.present? || card["modal_body"].to_s.strip.present?
  end

  # The speech-bubble that marks the intro modal everywhere it appears — the
  # rail control, the editor chrome strip, the player's re-open pill. One
  # drawing, so the three are recognisably the same thing. Stroke-based like
  # the delete bin beside it in the rail, and sized by its caller.
  def card_modal_icon(size = 13)
    tag.svg(width: size, height: size, viewBox: "0 0 24 24", fill: "none",
            aria: { hidden: true }, style: "flex-shrink:0;") do
      tag.path(d: "M4 5.5h16a1 1 0 011 1v9a1 1 0 01-1 1h-8.5L7 20.5V16.5H4a1 1 0 01-1-1v-9a1 1 0 011-1z",
               stroke: "currentColor", "stroke-width": "1.7", "stroke-linejoin": "round")
    end
  end

  def rich_option_text(card, shown, index)
    html = Array(card["options_html"])[index]
    return shown unless html.present? && shown.to_s == Array(card["options"])[index].to_s

    RichTextSanitizer.clean(html).html_safe
  end

  def rich_page_text(card, page)
    primary = Array(card["pages"]).find { |p| p.is_a?(Hash) && p["id"] == page["id"] }
    html = primary && primary["html"]
    return page["text"] unless html.present? && page["text"].to_s == primary["text"].to_s

    RichTextSanitizer.clean(html).html_safe
  end

  # ── Per-option visual overrides (`option_styles` on choice-shaped cards) ──
  # Mirrored client-side in lib/option_styles.js so the popover's live repaint
  # matches the server render exactly.

  def option_style_at(card, i)
    style = Array(card["option_styles"])[i]
    style.is_a?(Hash) ? style : nil
  end

  # Inline background for a styled tile — same gradient shape as the stock
  # choice-bg-N classes, built from the picked hex. "" when unstyled (the
  # positional class shows through).
  def option_tile_style(style)
    hex = style && style["color"].to_s
    return "" unless hex.present? && BrandPalette.valid_hex?(hex)
    "background:linear-gradient(135deg, #{BrandPalette.lighten(hex, 0.18)}, #{hex});"
  end

  # Where the card's media sits inside whatever frame crops it, as percentages
  # for background-position (a photo) or object-position (a video). 50 (centre)
  # on an axis the creator hasn't dragged.
  #
  # Vertical bites where the frame is wider than the media — the mobile header
  # strip and the editor's device frames. Horizontal bites the other way round,
  # which is the ordinary desktop panel: a 9:16 photo in a taller-than-9:16
  # column is cropped left and right, and until this axis existed there was no
  # way to say which side to keep.
  def card_focal_y(card)
    card_focal_axis(card, "focal_y")
  end

  def card_focal_x(card)
    card_focal_axis(card, "focal_x")
  end

  def card_focal_axis(card, key)
    return 50 unless card.is_a?(Hash)
    v = card[key]
    v.presence ? v.to_f.clamp(0, 100).round : 50
  end

  # How far past cover-fit the media is punched in. 1 unless the creator has
  # zoomed — which they do to give an axis that already fits the frame
  # something to slide (see Survey.sanitize_focal_zoom).
  def card_focal_zoom(card)
    focal_zoom_value(card.is_a?(Hash) ? card["focal_zoom"] : nil)
  end

  # A card stores it as `focal_zoom`; one statement's slot in option_focals
  # stores it as `z`, alongside that slot's own x/y. Same number either way.
  def focal_zoom_value(raw)
    raw.presence ? raw.to_f.clamp(1.0, Survey::FOCAL_ZOOM_MAX).round(2) : 1.0
  end

  # The whole reposition as custom properties, for the elements whose CSS reads
  # them. Emitted whole rather than only when moved: the editor rewrites these
  # live as the creator drags, and a property that isn't on the element to
  # start with has nothing for the fallback to be replaced on.
  #
  # Two forms of each axis, because CSS can't turn one into the other: the
  # percentage drives background-position/object-position, and the bare
  # fraction drives the layer's own offset (see .split-left-img).
  def focal_custom_properties(x, y, zoom)
    "--focal-x: #{x}%; --focal-y: #{y}%; " \
    "--focal-fx: #{(x / 100.0).round(4)}; --focal-fy: #{(y / 100.0).round(4)}; " \
    "--focal-zoom: #{zoom};"
  end

  def card_focal_style(card)
    focal_custom_properties(card_focal_x(card), card_focal_y(card), card_focal_zoom(card))
  end

  # The same, for one tap-card statement's media layer. Centre at cover-fit —
  # the historic rendering — unless that statement has been reframed.
  def option_focal_style(card, index)
    focal = Array(card.is_a?(Hash) ? card["option_focals"] : nil)[index]
    focal = {} unless focal.is_a?(Hash)
    focal_custom_properties(card_focal_axis(focal, "x"), card_focal_axis(focal, "y"),
                            focal_zoom_value(focal["z"]))
  end

  # The whole inline style for one tap statement's media layer: its picture (as
  # longhands — see .rotate-card-media for why never the shorthand) plus that
  # statement's reposition, or the positional gradient when it has no picture.
  # type_panel_controller's tap_card builder and card_editor#addTapOption mirror
  # this, so a statement rebuilt or added client-side paints identically.
  OPTION_TILE_FILLS = [
    %w[#d4edda #a8d5b5], %w[#d1ecf1 #9fd5df], %w[#fff3cd #ffd88a],
    %w[#f8d7da #f5a8b0], %w[#e2d9f3 #c3aee8]
  ].freeze

  def option_media_style(card, index, image)
    if image.present?
      "background-color:#fff; background-image:url('#{image}'); #{option_focal_style(card, index)}"
    else
      a, b = OPTION_TILE_FILLS[index % OPTION_TILE_FILLS.length]
      "background-image:linear-gradient(135deg,#{a},#{b});"
    end
  end

  # ── The two backdrops a card carries ────────────────────────────────────
  # media_bg is the HEADER backdrop: what sits behind the left panel's animation
  # (or IS the panel, on a card with no media). On a desktop that panel is the
  # card's left half; on a phone it is the header strip. mobile_bg is the
  # MOBILE BACKGROUND: what sits behind the question and answers on a phone —
  # below the header where the card has one, the whole card where it has none.
  # They are separate stored values painted on separate elements, and neither
  # helper ever reads the other's field, which is what "changing one must never
  # change the other" comes down to. Survey.sanitize_cards_images! holds the
  # same split on the way in.

  # A card's header backdrop, as an inline style for .split-left. An image
  # wins over a colour when both are set (the colour still paints underneath,
  # so a transparent PNG sits on it rather than on the brand panel). "" when
  # the card hasn't set one, leaving the CSS default --brand-panel in charge.
  #
  # The model already refuses a backdrop on a card whose panel holds a photo or
  # video (Survey.sanitize_cards_images!), so there is no exclusivity check
  # here — but a card being edited client-side can be mid-change, hence the
  # animated? guard.
  def card_media_bg_style(card)
    bg = card_media_bg(card)
    return "" if bg.blank?

    parts = []
    parts << "background-color:#{bg['color']}" if bg["color"].present?
    if (img = bg["image"]).present?
      parts << "background-image:url('#{css_url_escape(img)}')"
      parts += [ "background-size:cover", "background-position:center" ]
    end
    parts.join(";")
  end

  # Escaped for a single-quoted CSS url(), NOT URL-encoded: these URLs
  # legitimately carry query strings (Pexels crops are
  # ?auto=compress&cs=tinysrgb&w=720…) and percent-encoding the & and = would
  # break the image. The value is already host-allowlisted by
  # Survey.sanitize_image_url; this only stops a quote or backslash from
  # closing the url() and escaping into the style attribute.
  def css_url_escape(url)
    url.to_s.delete("\n\r").gsub(/["'\\]/) { |c| "\\" + c }
  end

  # The same value as a JSON attribute, so the editor's serialiser can read the
  # backdrop back off the DOM (survey_editor_controller#_readCard) — the deck is
  # rebuilt from the rendered card, so anything not written here is dropped on
  # the next autosave.
  def card_media_bg_attr(card)
    bg = card_media_bg(card)
    bg.blank? ? "" : bg.to_json
  end

  # Whether a card's panel can show a header backdrop at all: anything but an
  # opaque medium. An animation (a range card's reaction set, a pasted Lottie)
  # has transparency to see through, and a card with NO media is nothing BUT
  # its backdrop. A photo or a video covers the panel edge to edge, so a
  # backdrop behind one is a control that does nothing and is not offered.
  #
  # The three full-screen types take none: the phone draws them no header at
  # all (CardTypes::FULL_SCREEN_ANSWER_TYPES), so there is nothing for a header
  # backdrop to be behind — their phone design is the mobile background, below.
  #
  # The single definition of that rule: Survey.sanitize_cards_images! refuses to
  # store a backdrop the same way, and media_picker#_cardTakesBackground is its
  # client-side twin. Change one and change all three.
  def card_takes_backdrop?(card)
    return false unless card.is_a?(Hash)
    return false if CardTypes.full_screen_answer?(card["type"])
    return true if card["type"].to_s == "range" || card["lottie"].present?
    card["image"].blank? && card["video"].blank?
  end

  # The path a card's pasted Lottie is fetched from: always the same-origin
  # PROXY form, whatever form the card stored. Every animation saved before
  # 2026-09-25 holds the redirect form, whose 302 lands on the bucket where
  # lottie-web's XHR cannot read it (Survey.lottie_proxy_path) — rewriting at
  # render time is what makes those cards work again without a re-save.
  def card_lottie_url(card)
    Survey.lottie_proxy_path(card["lottie"])
  end

  def card_media_bg(card)
    return nil unless card_takes_backdrop?(card)

    bg = card["media_bg"]
    return nil unless bg.is_a?(Hash)

    kept = bg.slice("color", "image").compact_blank
    kept.empty? ? nil : kept
  end

  # The card's MOBILE BACKGROUND — a phone-only layer painted on .split-right,
  # the panel that holds the question and answers, so it starts below the
  # header on a card that has one and fills the card on one that has none.
  # The desktop and tablet layouts never read it ("allow creators to add that
  # background and it not affect anything on the desktop or tablet side").
  #
  # Every type takes one. The three full-screen types used to keep theirs in
  # media_bg — that was the working implementation this generalises — so a deck
  # saved before mobile_bg existed is read from there until its next save moves
  # it (Survey.sanitize_cards_images!). A mobile_bg the creator has set since
  # always wins.
  def card_mobile_bg(card)
    return nil unless card.is_a?(Hash)

    bg = card["mobile_bg"]
    bg = card["media_bg"] if !bg.is_a?(Hash) && CardTypes.full_screen_answer?(card["type"])
    return nil unless bg.is_a?(Hash)

    kept = bg.slice("color", "image").compact_blank
    return nil if kept.empty?

    # `ink` rides along but never keeps a background alive on its own — it is a
    # text colour, and a text colour with nothing behind it is not a background.
    ink = Survey.sanitize_backdrop_ink(bg["ink"])
    ink.present? ? kept.merge("ink" => ink) : kept
  end

  # The mobile background as custom properties on the panel, NOT as a
  # background — and that is the mechanism that keeps desktop and tablet out of
  # it: only the two phone blocks in application.css read --mobile-bg-*, so the
  # same inline attribute paints nothing at all until a phone rule asks for it.
  # No second attribute, no duplicated value, and no way for the two to disagree
  # about what the creator picked.
  def card_mobile_bg_style(card)
    bg = card_mobile_bg(card)
    return "" if bg.blank?

    parts = []
    parts << "--mobile-bg-color:#{bg['color']}" if bg["color"].present?
    parts << "--mobile-bg-image:url('#{css_url_escape(bg['image'])}')" if bg["image"].present?
    parts.join(";")
  end

  def card_mobile_bg_attr(card)
    bg = card_mobile_bg(card)
    bg.blank? ? "" : bg.to_json
  end

  # The classes the phone blocks key on: .has-mobile-bg is what paints the
  # panel, and .bg-ink-dark flips the card's words to dark ink on a light
  # background. "The text colour goes white regardless of the background — we
  # need it to react to the colour of the background." It reacts here, off a
  # measurement taken when the creator picked (lib/backdrop_ink.js), rather
  # than in the browser on every visit: a respondent's phone would have to
  # decode the picture before it could colour the question, which is a flash
  # of the wrong ink on the slowest connections, every time.
  def card_mobile_bg_classes(card)
    bg = card_mobile_bg(card)
    return "" if bg.blank?

    bg["ink"] == "dark" ? " has-mobile-bg bg-ink-dark" : " has-mobile-bg"
  end

  # The tile's icon slot, in precedence order: the creator's explicit icon
  # pick, their explicit emoji, the keyword-matched icon (where the type shows
  # them), and finally a fallback emoji — because a selection answer with an
  # empty tile reads as unfinished beside the rows that did match. nil-safe
  # everywhere. `index` only feeds the neutral fallback cycle.
  def option_tile_icon(style, label, keyword_fallback: true, index: 0)
    if style && (svg = OptionIconLibrary.svg_by_id(style["icon"].to_s))
      svg
    elsif style && style["emoji"].present?
      emoji_tile_span(style["emoji"])
    elsif keyword_fallback && (svg = OptionIconLibrary.svg_for(label))
      svg
    else
      emoji_tile_span(OptionIconLibrary.emoji_for(label, index))
    end
  end

  def emoji_tile_span(emoji)
    return nil if emoji.blank?
    content_tag(:span, emoji, class: "choice-icon-emoji", aria: { hidden: true })
  end

  # data-* attributes the editor's option-style popover reads/writes on each
  # option row; serialize() reads them back off the DOM. Editable mode only.
  def option_style_data_attrs(style)
    return "".html_safe unless style
    tag.attributes("data-option-color": style["color"], "data-option-icon": style["icon"],
                   "data-option-emoji": style["emoji"])
  end

  # Icon lookup for option markup built client-side (lib/option_icons.js):
  # `keywords` mirrors OptionIconLibrary::KEYWORD_TO_FILE with digest asset
  # URLs, `ids` addresses each icon by its basename for explicit picks.
  def option_icon_map_data
    {
      keywords: OptionIconLibrary::KEYWORD_TO_FILE.transform_values { |f| image_path("option-icons/#{f}") },
      ids: OptionIconLibrary::DATA.to_h { |entry| [ File.basename(entry["file"], ".svg"), image_path("option-icons/#{entry["file"]}") ] },
      # The emoji fallback, so a row built client-side (Add option, a type
      # switch) fills its tile exactly like the server would.
      emojis: OptionIconLibrary::EMOJI_KEYWORDS,
      fallbacks: OptionIconLibrary::EMOJI_FALLBACKS
    }
  end

  # Images present under app/assets/images/verto-library/, grouped by
  # sub-folder (`backgrounds`, `left-panel`, `select-art`, `range-art`,
  # `swipe-cards`, `mobile-backgrounds`, ...). Each value is an array of
  # paths relative to verto-library/ (e.g. `backgrounds/landscape.jpg`),
  # ready to feed into `asset_path("verto-library/#{rel}")`. Files dropped
  # directly into verto-library/ are grouped under the empty-string key.
  # Picked up at request time so dropping a new file requires no rebuild.
  def verto_library_images
    dir = Rails.root.join("app/assets/images/verto-library")
    return {} unless Dir.exist?(dir)

    image_ext = /\.(jpe?g|png|webp|svg)\z/i
    grouped   = Hash.new { |h, k| h[k] = [] }

    Dir.children(dir).sort.each do |entry|
      full = dir.join(entry)
      if File.directory?(full)
        Dir.children(full).select { |f| f =~ image_ext }.sort.each do |fname|
          grouped[entry] << "#{entry}/#{fname}"
        end
      elsif entry =~ image_ext
        grouped[""] << entry
      end
    end

    grouped.reject { |_, files| files.empty? }
  end

  # Renders the organisation's uploaded logo, or NOTHING when they haven't
  # uploaded one. `style` overrides the default sizing.
  #
  # No-logo means no logo, everywhere. This used to substitute the Playverto
  # wordmark, which put OUR mark in the space reserved for the customer's —
  # above their deck, and on the thank-you card directly above the "Powered by
  # Playverto" line that is the real attribution, so it appeared twice. That
  # line (player.powered_by) is untouched and remains the one place we sign the
  # work; this slot belongs to whoever published the Verto or to nobody.
  #
  # Returns nil rather than an empty string so `<%= %>` renders nothing and a
  # caller can test the result to decide whether its wrapper is worth drawing
  # at all (see .player-brand-header and .split-right-logo, both of which skip
  # an empty box that would otherwise hold its padding open).
  #
  # PROXY rather than the usual redirect path. `rails_blob_path` returns
  # /rails/active_storage/blobs/redirect/…: a 302 cached for 300s pointing at a
  # SECOND, separately signed disk URL that lapses 300s after the server minted
  # it (ActiveStorage.service_urls_expire_in). Replay a still-fresh redirect
  # whose disk signature has expired and you get a bare 404 — which an <img>
  # paints as the grey broken-image box. The margin is sub-second on a
  # clock-synced device, so this is a flake rather than the explanation for any
  # particular report, but it is a real one and there is no reason to keep it
  # in the path of the offline player, whose whole job is replaying cached
  # markup hours later. The proxy path is a single same-origin 200 with an
  # immutable cache header and no expiring signature anywhere; a new upload
  # mints a new blob and therefore a new URL, so nothing goes stale.
  #
  # `brand-logo` is the backstop. A blob whose bytes are genuinely gone can't
  # be rescued by any URL scheme, and a respondent should get no logo rather
  # than a broken-image glyph on someone's Verto.
  # `on:` names the SURFACE the logo will be drawn on, not the logo's colour.
  # :dark is the default because almost everything the platform draws is dark
  # chrome; :light is the welcome card's white answer panel, and picks the
  # alternate upload when there is one. Falling back to :logo rather than
  # rendering nothing is deliberate — an account with one logo keeps behaving
  # exactly as it did, and a missing alternate is a worse-looking logo rather
  # than no logo at all.
  # `direct: true` (the public player only) draws the logo from the bucket's own
  # presigned URL once uploads live there — see PlayerAssetUrls — instead of
  # streaming it through Rails for every respondent. Same-origin proxy otherwise.
  def brand_logo_tag(organisation, style: "height:22px;width:auto;flex-shrink:0;", alt: nil, class: nil, on: :dark, direct: false)
    css_class = binding.local_variable_get(:class)
    logo = brand_logo_for(organisation, on)
    if logo
      proxy = rails_storage_proxy_path(logo, only_path: true)
      image_tag(
        direct ? PlayerAssetUrls.attachment_url(logo, proxy_path: proxy) : proxy,
        style: "#{style};object-fit:contain;",
        # Translated, because this is what a screen reader reads out. It used
        # to be an English word on every logo the platform draws — tolerable
        # while the respondent-facing ones were a masthead and a card, and not
        # once a phone's only logo is the one in the player's bar.
        alt:   alt || I18n.t("player.org_logo", org: organisation.name, default: "#{organisation.name} logo"),
        class: css_class,
        data:  { controller: "brand-logo", action: "error->brand-logo#failed" }
      )
    end
  end

  # The attachment to draw for a surface, or nil if the account has no logo at
  # all. Only :light has an alternate; every other surface is dark chrome.
  def brand_logo_for(organisation, surface)
    return nil unless organisation

    if surface == :light && organisation.logo_on_light.attached?
      organisation.logo_on_light
    elsif organisation.logo.attached?
      organisation.logo
    end
  end

  # SVG QR code for a published Verto's share link, so a participant can point a
  # camera at a screen (or a printed handout) instead of typing a URL.
  #
  # SVG rather than PNG: it stays crisp at any print size, weighs a few KB, and
  # goes into the page as markup — no data-URL <img>, nothing extra for the CSP
  # to allow. `level: :m` is the middle error-correction tier: it tolerates a
  # fair bit of print smudging without inflating the module count the way :h
  # would, and a denser code is harder for a phone to read off a screen at arm's
  # length.
  #
  # `offset` is the quiet zone — the blank margin a scanner needs to find the
  # code's edges. Four modules is the spec minimum; without it a QR dropped onto
  # a coloured poster often just won't scan. viewbox + no width/height means the
  # caller sizes it with CSS rather than the gem baking in a fixed pixel size.
  QR_MODULE_SIZE = 4
  private_constant :QR_MODULE_SIZE

  def verto_qr_svg_document(url)
    RQRCode::QRCode.new(url.to_s, level: :m).as_svg(
      color: "1C2034", shape_rendering: "crispEdges",
      module_size: QR_MODULE_SIZE, offset: QR_MODULE_SIZE * 4,
      standalone: true, use_path: true, viewbox: true
    )
  end

  # The same QR for embedding in a page. Identical markup minus the XML prolog,
  # which is meaningless (and invalid) inside an HTML document.
  def verto_qr_svg(url)
    verto_qr_svg_document(url)
      .sub(/\A<\?xml.*?\?>/, "")
      .html_safe # rubocop:disable Rails/OutputSafety -- markup comes from rqrcode, not user input
  end

  # The same QR as a PNG download, for tools that won't place an SVG — Google
  # Slides, Canva, Word, most chat apps. 2048px is ~17cm at print resolution,
  # poster headroom, yet the two-colour image indexes down to a few KB.
  #
  # `size:` selects rqrcode's exact-canvas algorithm: the module size is
  # floored to fit and the leftover pixels join the margin, so the quiet zone
  # is always at least the 4-module spec minimum (`border_modules`) and the
  # canvas is exactly square. Fill is opaque white, not transparent: a PNG gets
  # dropped onto slides of any colour, and dark modules on a dark deck don't
  # scan.
  QR_PNG_SIZE = 2048
  private_constant :QR_PNG_SIZE

  def verto_qr_png(url)
    RQRCode::QRCode.new(url.to_s, level: :m)
      .as_png(color: "#1C2034", fill: "white", size: QR_PNG_SIZE, border_modules: 4)
      .to_blob
  end

  # Every module the /play player must have before a tap can do anything,
  # preloaded from the <head> (see layouts/_head) so a cold cache fetches them
  # in one wave alongside application.js instead of a four-deep lazy-import
  # waterfall. The list is the closure of what player pages actually mount:
  # the Stimulus registry pair, every controller a player-rendered view can
  # carry in data-controller, and the lib modules those controllers import.
  # lottie-web is deliberately absent — it's ~300KB, only NPS/range cards
  # animate with it, and the interactive part of those cards (the slider) is
  # in the list; the animation may arrive a beat later.
  # PlayerPreloadClosureTest keeps this list honest against the source tree.
  PLAYER_PRELOAD_MODULES = %w[
    controllers/index
    controllers/application
    controllers/player_controller
    controllers/picker_controller
    controllers/tap_stack_controller
    controllers/nps_slider_controller
    controllers/rating_controller
    controllers/slider_controller
    controllers/freeform_controller
    controllers/prioritise_controller
    controllers/scenario_controller
    controllers/autogrow_controller
    controllers/month_year_controller
    controllers/location_search_controller
    controllers/other_controller
    controllers/locale_switcher_controller
    controllers/cookie_consent_controller
    controllers/bg_image_healer_controller
    controllers/autoplay_video_controller
    controllers/lottie_player_controller
    lib/haptics
    lib/i18n
    lib/tap_scales
    lib/visible_band
    lib/page_limits
    lib/viewport_height
    lib/question_types
  ].freeze

  def player_module_preload_paths
    PLAYER_PRELOAD_MODULES.map { |m| asset_path("#{m}.js") }
  end

  # A small same-origin thumbnail path for a brand-library image — used by the
  # library tiles (media picker + branding page) so a tile loads a ~400px variant
  # instead of the full-size original. Display only: the full-size blob path is
  # what gets stored on a card when the tile is picked.
  #
  # Takes the ATTACHMENT, not the blob, so it can ask for the named :thumb
  # variant declared on Organisation#assets. That variant is preprocessed at
  # upload, so this resolves to an already-built blob rather than queueing a
  # libvips transform onto a request thread — see the declaration for why that
  # matters on a 60-tile library.
  #
  # Non-variable images (SVG) have no variant to serve and fall back to the
  # original, which is the right answer for vector art anyway. An attachment
  # without the named variant declared (or a bare blob passed by an older caller)
  # falls back to an on-demand variant, so nothing breaks — it just costs what it
  # always used to.
  def as_thumb_path(attachment, size: Organisation::ASSET_THUMB_LIMIT)
    blob = attachment.try(:blob) || attachment
    return rails_blob_path(blob, only_path: true) unless blob.variable?

    rails_representation_path(as_thumb_representation(attachment, blob, size), only_path: true)
  end

  # The wrapper attributes for a Show/Hide password toggle, to spread onto the
  # `.password-field` div that holds the input and the button.
  #
  # One definition because there are now five of these — the creator's sign-in
  # and sign-up, the respondent's sign-in, and the two copies of the
  # end-of-Verto card — and the controller's four labels are the part that is
  # easy to get subtly wrong: hideLabel was never passed from anywhere, so
  # every one of them read "Afficher" and then "Hide".
  def password_visibility_data
    {
      controller: "password-visibility",
      password_visibility_show_label_value: t("auth.show"),
      password_visibility_hide_label_value: t("auth.hide"),
      password_visibility_show_aria_value: t("auth.show_password"),
      password_visibility_hide_aria_value: t("auth.hide_password")
    }
  end

  # Inline `style` value that sets the Verto-experience brand variables for a
  # given palette. Spread onto a wrapper element (player overlay, preview
  # overlay, editor card feed) so the brand colours are scoped to the Verto and
  # never leak into the Playverto platform chrome. Returns "" for the default
  # palette so un-branded Vertos fall back to the current Playverto look.
  def brand_palette_style_attr(palette)
    return "" if BrandPalette.default?(palette)

    r = BrandPalette.resolve(palette)
    {
      "--brand-primary"      => r["primary"],
      "--brand-cta"          => r["cta"],
      "--brand-bg"           => r["bg"],
      "--brand-panel"        => r["panel"],
      "--brand-cta-text"     => r["cta_text"],
      "--brand-cta-hover"    => r["cta_hover"],
      "--brand-text"         => r["text"],
      "--brand-surface"      => r["surface"],
      "--brand-surface-2"    => r["surface_2"],
      "--brand-primary-soft" => r["primary_soft"],
      "--brand-primary-ink"  => r["primary_ink"],
      "--brand-scrim"        => r["scrim"],
      "--brand-scrim-fade"   => r["scrim_fade"]
    }.map { |k, v| "#{k}:#{v}" }.join(";")
  end

  # Full backdrop style for a Verto's canvas wrappers (player overlay, preview
  # overlay, editor card feed): the brand-colour variables plus, when set, a
  # --brand-bg-image with a top/bottom scrim so the nav/footer text stays
  # legible over the image. Spread into the wrapper's inline `style`.
  #
  # `image:` lets the editor opt out of inlining the (potentially multi-MB
  # base64) --brand-bg-image here and instead define it ONCE on a shared
  # ancestor (see verto_brand_bg_image_var) — both the feed and the preview
  # overlay then inherit the var, so the data URL isn't materialised per-wrapper.
  # The palette + mobile vars stay scoped to the wrapper (the surrounding editor
  # chrome must NOT inherit brand colours), so those are always emitted.
  def verto_backdrop_style_attr(survey, image: true)
    parts = []
    palette = brand_palette_style_attr(survey.brand_palette)
    parts << palette if palette.present?
    # The Verto's typeface, as a custom property the card text inherits. This
    # helper is the one place the editor feed, the preview overlay and the
    # player all set their brand vars, so declaring it here is what makes a
    # font pick reach every surface at once.
    if (stack = survey.brand_font_stack)
      parts << "--verto-font: #{stack}"
    end
    if (heading = survey.brand_font_heading_stack)
      parts << "--verto-font-heading: #{heading}"
    end
    # Answer icon tiles derived from the brand colour. Same reasoning as the
    # font: declared once here, so the editor feed, the preview overlay and
    # the player all pick it up.
    if survey.brand_answer_tint?
      BrandPalette.tile_gradients(BrandPalette.resolve(survey.brand_palette)["primary"])
                  .each_with_index { |grad, i| parts << "--choice-bg-#{i + 1}: #{grad}" }
    end
    parts << verto_brand_bg_image_var(survey) if image && survey.background_image.present?
    # Mobile-only per-card backdrop: a themed image picked from
    # verto-library/mobile-backgrounds/, applied behind a heavy white
    # scrim by the @media (max-width:767px) CSS on .split-card.
    if (mb = AssetPopulator.mobile_bg_url_for(survey)).present?
      parts << %(--mobile-card-bg: url("#{mb}"))
    end
    parts.join(";")
  end

  # Just the --brand-bg-image custom property (scrim gradient + the background
  # data URL), for defining once on a shared ancestor. Returns "" when no
  # background is set. Custom properties inherit, so wrappers that paint
  # `background-image: var(--brand-bg-image)` pick it up without re-inlining it.
  def verto_brand_bg_image_var(survey)
    return "" if survey.background_image.blank?
    url = survey.background_image.to_s.gsub(/["\r\n]/, "")
    %(--brand-bg-image: linear-gradient(rgba(0,0,0,0.45), rgba(0,0,0,0.12) 28%, rgba(0,0,0,0.12) 72%, rgba(0,0,0,0.45)), url("#{url}"))
  end

  def mini_preview_html(card)
    type = card["type"].to_s
    opts = Array(card["options"])
    bgs  = %w[mini-bg-1 mini-bg-2 mini-bg-3 mini-bg-4 mini-bg-5 mini-bg-6]

    html = case type
    when "range"
      dots = (0..4).map { |i| "<div class=\"mini-s-dot#{i.between?(1, 2) ? ' active' : ''}\"></div>" }.join
      "<div class=\"mini-tooltip\">Neutral</div>" \
      "<div class=\"mini-slider-track\">#{dots}" \
      "<div class=\"mini-s-thumb\"><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div></div>" \
      "</div>"

    when "rating"
      stars = (0..4).map { |i| "<span class=\"mini-rating-star\" style=\"color:#{i < 3 ? '#FFCC00' : 'rgba(255,255,255,0.2)'}\">#{i < 3 ? '★' : '☆'}</span>" }.join
      "<div class=\"mini-rating-stars\">#{stars}</div>"

    when "nps"
      dots = (0..4).map { |i| "<div class=\"mini-s-dot#{i == 3 ? ' active' : ''}\"></div>" }.join
      "<div class=\"mini-nps-face\">🙂</div>" \
      "<div class=\"mini-slider-track\">#{dots}" \
      "<div class=\"mini-s-thumb\"><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div><div class=\"mini-s-line\"></div></div>" \
      "</div>"

    when "multiple_choice", "select_many", "yes_no"
      items  = type == "yes_no" ? t("defaults.yes_no", default: %w[Yes No]) : (opts.empty? ? t("defaults.multiple_choice", default: [ "Option A", "Option B", "Option C" ]) : opts.first(3))
      square = type == "select_many" ? " mini-p-square" : ""
      rows   = items.map.with_index { |o, i|
        sel = i == 0 ? " selected" : ""
        "<div class=\"mini-pick-item#{sel}\"><span class=\"mini-p-dot#{square}#{sel}\"></span>#{h(o.truncate(18))}</div>"
      }.join
      "<div class=\"mini-pick-list\">#{rows}</div>"

    when "prioritise"
      items = opts.empty? ? t("defaults.multiple_choice", default: [ "Option A", "Option B", "Option C" ]) : opts.first(3)
      rows  = items.map.with_index { |o, i|
        "<div class=\"mini-pick-item\"><span class=\"mini-p-dot selected\" style=\"display:flex;align-items:center;justify-content:center;font-size:7px;color:#fff\">#{i + 1}</span>#{h(o.truncate(16))}</div>"
      }.join
      "<div class=\"mini-pick-list\">#{rows}</div>"

    when "select_one_grid", "select_many_grid"
      n    = opts.size
      cols = n >= 5 ? " cols-3" : ""
      cnt  = n >= 5 ? 6 : 4
      labels = %w[A B C D E F]
      cards  = cnt.times.map { |i|
        sel = i == 0 ? " selected" : ""
        "<div class=\"mini-img-card#{sel}\"><div class=\"mini-img-bg #{bgs[i % 6]}\"></div>" \
        "<div class=\"mini-img-ov\"></div><div class=\"mini-img-lbl\">#{labels[i]}</div></div>"
      }.join
      "<div class=\"mini-img-grid#{cols}\">#{cards}</div>"

    when "tap_card"
      # Non-interactive mockup — spans, not buttons: this preview is placed
      # inside a real <button> (the add-question type-tile), and a <button>
      # can't legally contain another <button> (the browser silently closes
      # the outer one early, wrecking everything rendered after it).
      "<div class=\"mini-swipe-stack\">" \
      "<div class=\"mini-swipe-card c1\"></div>" \
      "<div class=\"mini-swipe-card c2\"></div>" \
      "<div class=\"mini-swipe-card c3\"><span style=\"font-size:9px;color:rgba(0,0,0,0.5);padding:0 6px;text-align:center\">Swipe to respond</span></div>" \
      "</div>" \
      "<div class=\"mini-swipe-actions\">" \
      "<span class=\"mini-swipe-btn no\">✕</span>" \
      "<span class=\"mini-swipe-btn yes\">✓</span>" \
      "</div>"

    when "open_ended"
      # A <div>, not a <textarea>, for the same reason — <textarea> is
      # interactive content and isn't allowed inside a <button> either.
      "<div class=\"mini-textarea\">Type your answer here…</div>"

    when "scenario"
      "<div class=\"mini-swipe-stack\">" \
      "<div class=\"mini-swipe-card c1\"></div>" \
      "<div class=\"mini-swipe-card c2\"></div>" \
      "<div class=\"mini-swipe-card c3\"><span style=\"font-size:9px;color:rgba(0,0,0,0.5);padding:0 6px;text-align:center\">Read on, then choose</span></div>" \
      "</div>"

    else
      ""
    end

    html.html_safe
  end

  private

    # The representation as_thumb_path should link to.
    #
    # Prefers the attachment's declared :thumb, because that one is preprocessed
    # at upload — asking for it is a lookup, not a transform. Falls back to an
    # on-demand variant when there's no such declaration (a bare blob, or an
    # attachment on some other model), which is exactly what this used to do for
    # everything.
    #
    # ActiveStorage::Attachment#named_variants is private, so the declaration is
    # checked through the record's public reflections rather than by asking the
    # attachment — and never by rescuing the ArgumentError that variant(:thumb)
    # raises for an undeclared name, which would hide a real mistake.
    def as_thumb_representation(attachment, blob, size)
      on_demand = -> { blob.variant(resize_to_limit: [ size, size ]) }
      return on_demand.call unless attachment.respond_to?(:record) && attachment.respond_to?(:name)

      reflection = attachment.record&.attachment_reflections&.[](attachment.name)
      return on_demand.call unless reflection&.named_variants&.key?(:thumb)

      attachment.variant(:thumb)
    end
end
