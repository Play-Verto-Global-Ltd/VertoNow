module NpsHelper
  # NPS is the classic 0–10 likelihood scale (the default), rendered as a
  # vertical "liquid container" the respondent drags to fill to their number.
  # The label set is editable, so a creator can use the traditional 0–10, a
  # shorter 4/5-point scale, or an agree/emotion range instead — the number of
  # steps follows the labels. NPS_STEPS is just the DEFAULT label count.
  NPS_STEPS = 11

  # The reactive Lottie animation (now used by the RANGE card, not NPS) has 5
  # frames; the range slider maps its position proportionally onto these. Kept
  # separate from NPS_STEPS so the two move independently.
  NPS_FRAMES = 5

  # The NEUTRAL middle frame (3 of 5) — the resting pose every reaction
  # animation must start on, before the respondent has expressed anything. A
  # character that opens on frame 1 reads as "strongly disagree" and biases the
  # answer before the slider is touched. Derived from NPS_FRAMES so adding
  # frames can't silently leave the resting pose off-centre.
  NPS_NEUTRAL_FRAME = (NPS_FRAMES + 1) / 2

  NPS_THEME  = "basketball".freeze # default reaction theme when a card doesn't pick one

  # Selectable reaction-animation themes, grouped by subject category — this is
  # the order (and grouping) shown in the editor's picker. Each slug is a folder
  # app/assets/lottie/<slug>/ holding 1..5.json (the five slider states). To add
  # a set: drop the folder in and add its slug to a group here. NPS_THEME (the
  # default) must appear in one of these groups. A set bound to ONE card rather
  # than offered to every range card is registered below (AGE_BAND_THEME),
  # never here.
  RANGE_THEME_GROUPS = {
    "Sport"                     => %w[basketball football football_goal stopwatch target snooker_ball
                                      sport_trainers water_bottle],
    "Climate & Sustainability"  => %w[sun flowers recycling lotus plant tree],
    "Mental Health & Wellbeing" => %w[balance lightbulb lightbulb_loading heart journal stones loading_hearts],
    "Education"                 => %w[puzzle robot],
    "General"                   => %w[pizza radar calendar coins cookies emoji_a emoji_b hand_gestures
                                      koala pv_mascots dog speech_bubbles speech_bubbles_colour speedometer]
  }.freeze

  # Flat allow-list derived from the groups — the single source of truth for
  # sanitisation (Survey.sanitize_cards_images!) and URL building.
  RANGE_THEMES = RANGE_THEME_GROUPS.values.flatten.freeze

  # A reaction set bound to ONE card rather than picked for a deck. The age
  # card's slider has a stop per age band and this set has a frame per stop —
  # seven, in DemographicQuestions::AGE_BANDS order, each the music of that
  # generation: online music (under 16), wireless headphones (16–17), an MP3
  # player (18–24), a CD (25–34), a cassette (35–49), vinyl (50–64), a
  # gramophone (65+). The slider changes the file per ANSWER, rather than
  # sampling five poses across seven stops, which is why the set has seven
  # frames and why it is not in RANGE_THEME_GROUPS: the picker never offers it
  # and the populator never draws it, because no other card has seven answers
  # to map it onto. The age card always plays it (range_theme_slug), whatever
  # `range_theme` it may still carry from before this set existed.
  AGE_BAND_THEME = "music_eras".freeze

  # Frame counts where a set departs from NPS_FRAMES. Every other folder holds
  # 1..5.json.
  LOTTIE_FRAMES = { AGE_BAND_THEME => DemographicQuestions::AGE_BANDS.length }.freeze

  # Every slug with a folder under app/assets/lottie/: the pickable sets plus
  # the card-bound one. RANGE_THEMES stays the allow-list for what a card may
  # STORE and the picker may offer; this is the list of what can be PLAYED.
  LOTTIE_THEMES = (RANGE_THEMES + [ AGE_BAND_THEME ]).freeze

  def self.frames_for(theme)
    LOTTIE_FRAMES.fetch(theme.to_s, NPS_FRAMES)
  end

  # A set's resting pose: its middle frame, the way NPS_NEUTRAL_FRAME is the
  # middle of a five-frame set. For the age set that is frame 4, the CD — the
  # band the slider parks its thumb on too (index 3 of 7, "25–34").
  def self.neutral_frame_for(theme)
    (frames_for(theme) + 1) / 2
  end

  # The demographic age card: a range card whose stops are the age bands. It
  # is drawn top-down (slider_top_down?) and plays AGE_BAND_THEME.
  def self.age_band_card?(card)
    card.is_a?(Hash) && card["type"].to_s == "range" && DemographicQuestions.key_for(card) == "age"
  end

  # Subject-specific words each animation set depicts, so auto-population and
  # Shuffle can prefer an on-theme animation (a Climate range card reacts with
  # recycling/flowers/sun, not basketball) before falling back to the General
  # group. Keys are RANGE_THEMES slugs.
  #
  # These are matched against the Verto theme's OWN words (see range_themes_for),
  # NOT the image matcher's cluster-expanded set: those clusters deliberately
  # bridge topics for stock-photo breadth (food ↔ lifestyle ↔ "game"), which
  # leaks generic words like "game"/"performance" into every set and lands a
  # football on a food Verto. So the vocabulary here is kept deliberately
  # concrete and non-generic — a word only earns its place if a survey that
  # literally uses it genuinely wants that animation.
  RANGE_THEME_KEYWORDS = {
    "basketball"    => %w[sport sports basketball nba hoop dunk court],
    "football"      => %w[sport sports football soccer fifa striker goalkeeper kickoff],
    "football_goal" => %w[sport sports football soccer goal penalty striker goalkeeper],
    "stopwatch"     => %w[sport sports running run marathon sprint race racing athletics athlete fitness gym workout exercise],
    "sun"           => %w[climate weather sustainability sustainable environment environmental nature outdoors renewable solar energy summer eco],
    "flowers"       => %w[climate nature flower flowers garden gardening plant plants biodiversity wildlife spring bloom growth environment sustainability],
    "recycling"     => %w[climate recycling recycle sustainability sustainable environment environmental waste plastic pollution renewable eco carbon conservation],
    "balance"       => %w[wellbeing wellness mental mindfulness meditation stress anxiety therapy counselling calm balance burnout mood emotional sleep],
    "pizza"         => %w[food foods nutrition eating meal meals restaurant cuisine snack snacks cooking diet dietary hunger grocery groceries],
    "radar"         => %w[tech technology digital data online internet innovation software cyber signal],
    "calendar"      => %w[work career job planning schedule productivity education study student students school university exam business office meeting deadline],
    "target"        => %w[sport sports darts dart archery target targets aim accuracy precision goal goals],
    "snooker_ball"  => %w[sport sports snooker pool billiards cue],
    "lotus"         => %w[nature lotus flower flowers bloom blossom garden pond yoga meditation mindfulness calm],
    "plant"         => %w[nature plant plants seed seeds seedling sprout garden gardening soil growth growing],
    "tree"          => %w[nature tree trees forest forests woodland planting climate environment sustainability growth],
    "lightbulb"     => %w[idea ideas creativity creative innovation insight inspiration learning thinking mental wellbeing],
    "lightbulb_loading" => %w[idea ideas thinking loading progress patience learning],
    "heart"         => %w[love heart hearts kindness empathy compassion emotion emotional feeling feelings mood wellbeing mental health],
    "journal"       => %w[journal journaling diary writing reflection gratitude notes study studying homework],
    "stones"        => %w[calm balance mindfulness meditation zen stress patience stability],
    "puzzle"        => %w[puzzle puzzles problem problems solving logic thinking skills learning education],
    "robot"         => %w[robot robots ai technology tech coding programming stem digital education],
    "coins"         => %w[money finance financial saving savings budget budgeting income wealth economy economic cost costs price prices],
    "cookies"       => %w[food snack snacks baking treat treats cookie cookies],
    "emoji_a"       => %w[emotion emotions emotional mood moods feeling feelings],
    "emoji_b"       => %w[emotion emotions emotional mood moods feeling feelings],
    "hand_gestures" => %w[gesture gestures hand hands approval agreement vote voting feedback],
    "koala"         => %w[animal animals wildlife koala zoo pet pets nature],
    "pv_mascots"    => [], # brand characters, no subject of their own — reachable via the General fallback and the picker
    "dog"           => %w[animal animals dog dogs puppy pet pets wildlife],
    "speech_bubbles"        => %w[communication conversation chat chatting message messages messaging talk talking discussion opinion opinions feedback],
    "speech_bubbles_colour" => %w[communication conversation chat chatting message messages messaging talk talking discussion opinion opinions feedback],
    "speedometer"   => %w[speed pace fast driving traffic transport travel commute frequency],
    "sport_trainers" => %w[sport sports running run runner jog jogging trainers sneakers shoes fitness gym workout exercise],
    "water_bottle"  => %w[sport sports hydration water drink drinking fitness gym workout exercise],
    "loading_hearts" => %w[love heart hearts kindness empathy compassion emotion emotional feeling feelings mood wellbeing]
  }.freeze

  # Where an off-theme Verto's animation comes from: the General group is the
  # neutral catch-all, so nothing themed matching still yields a sensible pool
  # (never an arbitrary sport animation on an unrelated Verto).
  RANGE_THEME_FALLBACK = (RANGE_THEME_GROUPS["General"] || RANGE_THEMES).freeze

  # Animation sets that are variants of one another: the same subject drawn
  # twice — a colour version, a loading version, a second sheet of the same
  # faces. Distinct slugs are not enough to make them distinct CONTENT, and a
  # respondent scrolling past `speech_bubbles` and then `speech_bubbles_colour`
  # has seen the same animation twice whatever the deck's data says. So
  # auto-population spends one member of a family before it comes back for a
  # second (see AssetPopulator#pick_range_theme). The picker still offers every
  # slug — this only orders what an automatic pick reaches for first. A slug not
  # named here is its own family.
  RANGE_THEME_FAMILIES = {
    "emoji_a"               => "emoji",
    "emoji_b"               => "emoji",
    "speech_bubbles"        => "speech_bubbles",
    "speech_bubbles_colour" => "speech_bubbles",
    "lightbulb"             => "lightbulb",
    "lightbulb_loading"     => "lightbulb",
    "heart"                 => "heart",
    "loading_hearts"        => "heart"
    # `football` and `football_goal` are deliberately NOT a family: a player and
    # a goal are two different animations that happen to share a sport, and
    # pairing them would push a sport Verto off its own theme to avoid a repeat
    # that isn't one. A family is a redraw, not a subject.
  }.freeze

  def self.range_theme_family(slug)
    RANGE_THEME_FAMILIES[slug.to_s] || slug.to_s
  end

  # Range-animation slugs suited to a Verto whose theme is `theme` (a string or
  # a list of words), best-matching first. Matches the theme's OWN words against
  # RANGE_THEME_KEYWORDS — deliberately NOT the image matcher's cluster expansion
  # (which over-bridges and would land a football on a food Verto). Words are
  # singularised on both sides so "schools"/"school" and "sports"/"sport" match.
  # Falls back to the General group when nothing is on-theme, so the result is
  # never empty — a caller (AssetPopulator, and thus Shuffle) can seed-pick from
  # it directly. Ties keep RANGE_THEMES order so the pick is deterministic for a
  # given seed + theme.
  def self.range_themes_for(theme)
    words = Array(theme).flat_map { |t| t.to_s.downcase.scan(/[a-z]+/) }
                        .select { |w| w.length >= 3 }
                        .map { |w| w.singularize }
                        .to_set
    scored = RANGE_THEMES.each_with_index.map do |slug, i|
      hits = Array(RANGE_THEME_KEYWORDS[slug]).count { |k| words.include?(k.singularize) }
      [ slug, hits, i ]
    end
    themed = scored.select { |_slug, n, _i| n.positive? }
                   .sort_by { |_slug, n, i| [ -n, i ] }
                   .map(&:first)
    themed.presence || RANGE_THEME_FALLBACK
  end

  # Picker display names where slug.titleize doesn't read right.
  RANGE_THEME_LABELS = {
    "water_bottle"          => "Sports Water Bottle",
    "lightbulb"             => "Light Bulb",
    "lightbulb_loading"     => "Light Bulb (Loading)",
    "emoji_a"               => "Emoji Set A",
    "emoji_b"               => "Emoji Set B",
    "pv_mascots"            => "PV Mascots",
    "speech_bubbles"        => "Speech Bubbles (White)",
    "speech_bubbles_colour" => "Speech Bubbles (Colour)"
  }.freeze

  def range_theme_label(slug)
    RANGE_THEME_LABELS[slug] || slug.titleize
  end

  def nps_card?(card)
    card["type"].to_s == "nps"
  end

  # ── How many stops the scale has ──────────────────────────────────────────
  # An NPS is 0-10, and that is the whole point of the type: the score only
  # means anything against the same eleven-point question everybody else asks.
  # So the count is LOCKED by default and the editor shows no way to change it.
  #
  # But the widget has always been able to carry another scale — the labels
  # drive the step count, and a 4/5-point or agree/emotion range renders
  # perfectly well — and creators do want one. Hence a switch rather than a
  # rule: turn the classic off and the card grows ＋ and × on its stops.
  #
  # Two floors, and they are different kinds of number. NPS_MIN_STEPS is what
  # the slider needs to be a slider at all (see nps_slider_controller's
  # `Math.max(2, …)`), and it is the same 2 the renderer already assumes.
  # NPS_MAX_STEPS is the classic itself: eleven stops is what the label column
  # holds legibly at the vessel's height, and a scale that wanted more than the
  # canonical one has stopped being this card.
  NPS_MIN_STEPS = 2
  NPS_MAX_STEPS = NPS_STEPS

  # The two anchor lines beside a scale's ends (card["nps_low_label"] /
  # card["nps_high_label"]). A caption, not a sentence: the column it sits in
  # is a few em wide and wraps, so a limit that fits "I am a decision maker"
  # with room for a wordier language is the right one.
  NPS_ANCHOR_MAX = 60

  # Whether this card is off the classic scale.
  #
  # Three-state on purpose. `nps_custom_scale` is stored ONLY when a creator
  # deliberately turns the classic off; its ABSENCE means "nobody has said", and
  # then the labels answer for themselves. That is what lets this ship without a
  # migration and without touching a single existing deck: a card sitting on
  # 0-10 (or on no labels at all) reads as classic, and one already carrying an
  # agree scale reads as custom and keeps every label it has. A stored default
  # either way would have been wrong for half the decks in the account.
  def nps_custom_scale?(card)
    return false unless card.is_a?(Hash)
    return true if card["nps_custom_scale"] == true
    labels = Array(card["options"]).map(&:to_s)
    labels.any? && labels != nps_default_labels
  end

  # ── The NPS card's own animation: which vessel it fills ────────────────────
  # A range card picks a reaction CHARACTER (range_theme, above); an NPS card's
  # animation IS its liquid container, and until now a creator could not choose
  # one — the shape was derived from the Verto's theme and that was that
  # (ApplicationHelper#nps_container_shape). Same shape of control as
  # range_theme: an editor picker writes a slug onto the card, the card's own
  # value wins where it is a real vessel, and the themed pick stays the default
  # so nothing changes for a deck nobody has touched.
  #
  # Grouped by what the container IS, which is how a creator looks for one — the
  # same reasoning as RANGE_THEME_GROUPS. Every NPS_VESSELS key must appear in
  # exactly one group (nps_shape_test holds that), so a vessel added to the
  # drawing table can't quietly go missing from the picker.
  NPS_SHAPE_GROUPS = {
    "Simple"  => %w[pill],
    "Drinks"  => %w[glass bottle can mug],
    "Science" => %w[flask beaker tube],
    "Food"    => %w[jar popsicle],
    # Named to match RANGE_THEME_GROUPS' own "Sport", which is where a creator
    # already finds the sibling picker's water bottle character.
    "Sport"   => %w[water_bottle]
  }.freeze

  # Picker display names where the slug doesn't read right on its own — the
  # code calls the default a "pill" because that is the silhouette, but a
  # creator scanning a grid reads "Pill" as medicine.
  NPS_SHAPE_LABELS = {
    "pill"     => "Capsule",
    "tube"     => "Test Tube",
    "can"      => "Drinks Can",
    "popsicle" => "Ice Lolly"
  }.freeze

  def nps_shape_label(shape)
    NPS_SHAPE_LABELS[shape] || shape.to_s.titleize
  end

  # [[category, [[label, slug], …]], …] for the shape picker's grouped grid.
  def nps_shape_groups
    NPS_SHAPE_GROUPS.map { |cat, shapes| [ cat, shapes.map { |s| [ nps_shape_label(s), s ] } ] }
  end

  # Editor payload for the shape picker: the same groups, as JSON, so the type
  # panel can rebuild a card's hidden <select> on a type switch without a
  # round-trip. Deliberately carries no geometry — lib/nps_vessels is already a
  # mirror of NPS_VESSELS and sending the paths a second time would make a third
  # copy to keep in sync.
  def nps_shape_picker_data
    {
      label:  t("editor.animation_theme", default: "Animation"),
      groups: NPS_SHAPE_GROUPS.map do |cat, shapes|
        { category: cat, shapes: shapes.map { |s| { slug: s, label: nps_shape_label(s) } } }
      end
    }
  end

  # The container an NPS card actually fills: its own `nps_shape` when that's a
  # vessel we can draw, otherwise the Verto-themed default. Safe on any card
  # hash, and on a nil survey (the seeders and the type panel both reach it
  # before a Verto is saved).
  def nps_shape_slug(card, survey = nil)
    slug = card.is_a?(Hash) ? card["nps_shape"].to_s : ""
    return slug if NPS_VESSELS.key?(slug)
    nps_container_shape(survey)
  end

  # One vessel drawn at rest for the picker's grid — the same SVG the card
  # renders, so the tile is the thing itself rather than a drawing of it. Part
  # filled, because an empty vessel and a full one look like two different
  # controls and neither reads as "this fills up".
  NPS_PREVIEW_FILL = 0.6

  def nps_shape_preview(shape)
    v = nps_vessel_for(shape)
    content_tag :span, class: "nps-control nps-shape-#{shape}",
                style: "#{nps_stage_style(shape)}; --nps-fill: #{NPS_PREVIEW_FILL}" do
      # concat, matching render_nps_control — content_tag's block runs through
      # capture, which reads the output buffer before the return value.
      concat nps_vessel_svg(shape, v)
    end
  end

  # Default 0–10 labels when a card hasn't set its own.
  def nps_default_labels
    (0..(NPS_STEPS - 1)).map(&:to_s)
  end

  # Asset URLs for a set's reaction Lotties — five, or LOTTIE_FRAMES' count.
  # Files live under `app/assets/lottie/<theme>/` which Sprockets treats as an
  # asset path root, so files resolve at `/assets/<theme>/<file>`. Using
  # asset_path so digested URLs work in prod.
  def nps_lottie_urls(theme = NPS_THEME)
    theme = NPS_THEME unless LOTTIE_THEMES.include?(theme.to_s)
    (1..NpsHelper.frames_for(theme)).map { |i| asset_path("#{theme}/#{i}.json") }
  end

  # The reaction theme a range card actually uses: the age card's own bound
  # set; otherwise the card's `range_theme` when that's a known slug, else the
  # default. Safe on any card hash.
  def range_theme_slug(card)
    return AGE_BAND_THEME if NpsHelper.age_band_card?(card)
    slug = card.is_a?(Hash) ? card["range_theme"].to_s : ""
    RANGE_THEMES.include?(slug) ? slug : NPS_THEME
  end

  # A tunable starting point, not a precisely derived number — refine
  # visually (see the /verify skill) rather than by adjusting the math.
  SLIDER_AXIS_LABEL_THRESHOLD = 18
  SLIDER_AXIS_COUNT_THRESHOLD = 5

  # Whether a Range card's slider should render vertical or horizontal. An
  # explicit slider_axis (set via the editor's toggle) always wins; otherwise
  # a simple length heuristic picks vertical when the horizontal layout would
  # likely look cramped — long labels, or a lot of them.
  def resolved_slider_axis(card)
    card = card.is_a?(Hash) ? card : {}
    explicit = card["slider_axis"].to_s
    return explicit if %w[horizontal vertical].include?(explicit)
    labels  = Array(card["options"]).map(&:to_s)
    longest = labels.map(&:length).max.to_i
    (longest > SLIDER_AXIS_LABEL_THRESHOLD || labels.size > SLIDER_AXIS_COUNT_THRESHOLD) ? "vertical" : "horizontal"
  end

  # Whether a vertical Range card lists its first option at the TOP rather than
  # the bottom. Only the age card: a list of age bands reads youngest first,
  # down the page, while a scale ("not at all" … "very") reads as a gauge
  # filling upward. Display only — the stored answer is still the option's
  # index, so the age sync's band mapping is untouched. Derived from the card
  # rather than stored on it, so Vertos already carrying the age card get it
  # without a data change.
  def slider_top_down?(card)
    NpsHelper.age_band_card?(card)
  end

  # [[category, [[label, slug], …]], …] for the range card's grouped <optgroup>
  # theme picker.
  def range_theme_groups
    RANGE_THEME_GROUPS.map { |cat, slugs| [ cat, slugs.map { |slug| [ range_theme_label(slug), slug ] } ] }
  end

  # Editor payload for the theme picker: the control label; the flat theme list
  # (slug → display label + 5 asset URLs, for live-preview swaps); and the
  # category groups (for building the grouped <optgroup> picker on a type-switch)
  # — so the editor never needs a round-trip. Emitted as JSON in the editor head
  # (see surveys/show).
  def range_theme_picker_data
    {
      label:  t("editor.animation_theme", default: "Animation"),
      themes: RANGE_THEMES.map { |slug| { slug: slug, label: range_theme_label(slug), urls: nps_lottie_urls(slug) } },
      groups: RANGE_THEME_GROUPS.map { |cat, slugs| { category: cat, slugs: slugs } }
    }
  end

  # LEFT panel: a div that the lottie-player Stimulus controller mounts into.
  # The full list of Lottie URLs is passed via data attribute so the JS doesn't
  # need to know about Rails asset digesting.
  #
  # Starts on the set's NEUTRAL middle frame (NPS_NEUTRAL_FRAME for a
  # five-frame set), matching where slider_controller parks the thumb on
  # connect — so the character is expressionless until the respondent actually
  # moves the slider, and there's no frame-1 flash.
  def render_nps_reaction(initial_value: nil, theme: NPS_THEME)
    initial_value ||= NpsHelper.neutral_frame_for(theme)
    content_tag :div, class: "nps-lottie",
                data: {
                  controller:                   "lottie-player",
                  "lottie-player-urls-value":   nps_lottie_urls(theme).to_json,
                  "lottie-player-current-value": initial_value
                } do
      content_tag(:div, "", class: "nps-lottie-mount",
                  data: { "lottie-player-target" => "mount" })
    end
  end

  # RIGHT panel: the vertical "liquid container", drawn as an SVG vessel themed
  # per Verto. Each vessel is a real object silhouette (test tube, flask, mug…)
  # with its own width so it reads as the thing it is. One <svg> carries: the
  # grey "empty" fill, the rising teal liquid (surface waves + bubbles rising
  # up through it), and the black outline stroke on top, plus any extras (jar
  # lid, mug handle, popsicle stick). The liquid level follows --nps-fill (0..1,
  # set by nps_slider_controller) by translating the `.nps-liquid` group — that
  # rising/falling motion IS the drag feedback, so nothing else sits over the
  # vessel; the static label list to the left shows which value is selected
  # (highlighted).
  #
  # Each entry: w (viewBox width), cx/hw (bubble column centre + half-spread),
  # kind (extra: jar lid / mug handle / popsicle stick), path (the open-topped
  # body outline; also the fill clip when closed with Z).
  # `top`/`bottom` are the y bounds of the vessel's INTERIOR — where the liquid
  # is empty and where it is brim-full. They are read off each path above and
  # are the whole reason "0" and "10" now line up with the vessel: the fill used
  # to translate by a single hard-coded 306, which only suited the five shapes
  # whose floor happens to sit at 306. The default `pill` bottoms at 316, so it
  # kept a slug of liquid at value 0; `popsicle` (268) over-emptied by 38. The
  # brim end was worse — every shape overshot its own top, and the clipPath hid
  # it, so the last two or three steps of the scale looked identical.
  # The label column is positioned off the same two numbers (see
  # nps_stage_style), which is what keeps the digits level with the liquid.
  NPS_VESSELS = {
    "tube"     => { w: 68,  cx: 34, hw: 11, kind: nil,   top: 16, bottom: 314, path: "M20,16 L20,300 A14,14 0 0 0 48,300 L48,16" },
    "pill"     => { w: 78,  cx: 39, hw: 13, kind: nil,   top: 24, bottom: 316, path: "M24,54 Q24,24 39,24 Q54,24 54,54 L54,286 Q54,316 39,316 Q24,316 24,286 Z" },
    "can"      => { w: 92,  cx: 46, hw: 26, kind: nil,   top: 36, bottom: 304, path: "M16,52 Q16,36 46,36 Q76,36 76,52 L76,288 Q76,304 46,304 Q16,304 16,288 Z" },
    "bottle"   => { w: 96,  cx: 48, hw: 22, kind: nil,   top: 18, bottom: 306, path: "M40,18 L40,74 Q24,94 24,134 L24,296 Q24,306 32,306 L64,306 Q72,306 72,296 L72,134 Q72,94 56,74 L56,18" },
    "popsicle" => { w: 98,  cx: 49, hw: 26, kind: "pop", top: 26, bottom: 268, path: "M20,54 Q20,26 49,26 Q78,26 78,54 L78,258 Q78,268 68,268 L30,268 Q20,268 20,258 Z" },
    # Converted from a 178x604 source drawing: scaled to this 340 box and drawn
    # at half its visual width, since WIDTH_SCALE stretches every vessel by 2.
    # The screw cap, its grip ridges and the carry loop are the "sportcap"
    # extra — the liquid path is the neck and body alone, open at the neck's rim
    # (top: 56) exactly as `bottle` is open at the top of its own neck.
    "water_bottle" => { w: 100, cx: 50, hw: 18, kind: "sportcap", top: 56, bottom: 308, path: "M39.8,56.3 L39.8,70.6 C34.3,78.5 30.7,89.1 29.2,102.4 L29.2,277.2 C29.2,290.5 33,299.8 40.7,305.1 C46.9,308.8 53,308.8 59.2,305.1 C66.9,299.8 70.7,290.5 70.7,277.2 L70.7,102.4 C69.2,89.1 65.6,78.5 60.1,70.6 L60.1,56.3" },
    "glass"    => { w: 106, cx: 53, hw: 28, kind: nil,   top: 24, bottom: 306, path: "M18,24 L30,300 Q30,306 36,306 L70,306 Q76,306 76,300 L88,24" },
    "beaker"   => { w: 116, cx: 58, hw: 38, kind: nil,   top: 44, bottom: 306, path: "M18,44 L18,298 Q18,306 26,306 L90,306 Q98,306 98,298 L98,52 L110,40" },
    "jar"      => { w: 118, cx: 59, hw: 40, kind: "jar", top: 50, bottom: 306, path: "M18,64 L18,298 Q18,306 26,306 L92,306 Q100,306 100,298 L100,64 L94,50 L24,50 Z" },
    "flask"    => { w: 130, cx: 65, hw: 22, kind: nil,   top: 22, bottom: 306, path: "M54,22 L58,34 L58,90 L10,296 Q10,306 20,306 L110,306 Q120,306 120,296 L72,90 L72,34 L76,22" },
    "mug"      => { w: 132, cx: 54, hw: 34, kind: "mug", top: 52, bottom: 308, path: "M16,52 L16,300 Q16,308 24,308 L84,308 Q92,308 92,300 L92,52" }
  }.freeze

  # The viewBox is 340 tall for every shape; widths vary per silhouette.
  VESSEL_H = 340

  # Vessels render twice as wide as they are drawn. Applied as an SVG transform
  # rather than by rewriting ten hand-authored paths in two files, so there is
  # one number to re-tune visually instead of ~60 coordinates to keep in sync.
  # The stroked paths carry vector-effect="non-scaling-stroke" so the outline
  # keeps its intended weight instead of smearing to 2x horizontally.
  WIDTH_SCALE = 2

  # Outline weight. Was 6, which against a 68-132 unit viewBox read as 5-9% of
  # the vessel's width — a very heavy black keyline for what is a soft,
  # liquid-filled object.
  STROKE_W = 3

  def nps_vessel_for(shape)
    NPS_VESSELS.fetch(shape.to_s) { NPS_VESSELS.fetch("pill") }
  end

  # The custom properties that tie the label column, the vessel and the liquid
  # to ONE set of numbers. Emitted on .nps-slider-stage — the nearest common
  # ancestor of the digits and the vessel — because the two used to be sized
  # independently (an 11-band flex column against a hard-coded fill travel) and
  # drifted apart by ~14px at value 0.
  #
  #   --nps-aspect  the control's width:height, now including WIDTH_SCALE
  #   --nps-top     where a FULL vessel's surface sits, in viewBox units
  #   --nps-travel  how far the liquid falls from full to empty
  #   --nps-top-f / --nps-bot-f  the same bounds as fractions of the viewBox
  #                 height, used to inset the label column so digit i lands on
  #                 fill level i (padding, because a percentage padding would
  #                 resolve against width, not height)
  def nps_stage_style(shape)
    v = nps_vessel_for(shape)
    [
      "--nps-aspect: #{v[:w] * WIDTH_SCALE} / #{VESSEL_H}",
      "--nps-top: #{v[:top]}px",
      "--nps-travel: #{v[:bottom] - v[:top]}px",
      "--nps-top-f: #{(v[:top].to_f / VESSEL_H).round(4)}",
      "--nps-bot-f: #{((VESSEL_H - v[:bottom]).to_f / VESSEL_H).round(4)}"
    ].join("; ")
  end

  def render_nps_control(shape: "pill", steps: NPS_STEPS)
    v = nps_vessel_for(shape)
    content_tag :div, class: "nps-control nps-shape-#{shape}",
                data: { axis: "vertical" } do
      concat nps_vessel_svg(shape, v)
    end
  end

  # Builds the vessel <svg>. All geometry is internal (no user input; `shape` is
  # validated against NPS_VESSELS by the caller), so the string is html_safe.
  # Bubbles are seeded off the shape name so the markup is stable per shape.
  def nps_vessel_svg(shape, v)
    w   = v[:w]
    rng = Random.new(Digest::SHA256.hexdigest(shape)[0, 8].to_i(16))
    wave = ->(y) { "M-40,#{y} q32.5,-8 65,0 t65,0 t65,0 t65,0 t65,0 L290,430 L-40,430 Z" }
    # Same treatment as the outline: keyed off STROKE_W so the whole drawing
    # re-weights together, and non-scaling so WIDTH_SCALE doesn't smear them.
    # The mug handle stays the heaviest line on the object (it reads as a
    # thick ceramic loop), just proportionally lighter than it was.
    extras = {
      "jar" => %(<rect x="22" y="22" width="74" height="26" rx="8" fill="#dfe2ee" stroke="#1a1a1a" stroke-width="#{STROKE_W}" vector-effect="non-scaling-stroke"/>),
      "mug" => %(<path d="M92,116 C130,120 130,244 92,248" fill="none" stroke="#1a1a1a" stroke-width="#{(STROKE_W * 2.2).round}" stroke-linecap="round" vector-effect="non-scaling-stroke"/>),
      "pop" => %(<rect x="41" y="260" width="16" height="52" rx="6" fill="#c9a678" stroke="#1a1a1a" stroke-width="#{(STROKE_W * 0.7).round(1)}" vector-effect="non-scaling-stroke"/>),
      # Three pieces, drawn above the liquid: the screw cap (filled like the jar
      # lid, so it reads as solid rather than as more container), its four grip
      # ridges, and the carry loop. All keyed off STROKE_W like everything else.
      "sportcap" => %(<path d="M36.1,27.6 V50.7 C36.1,54.4 37.2,56.3 39.3,56.3 H60.6 C62.7,56.3 63.8,54.4 63.8,50.7 V27.6 C63.8,25.5 63.2,24.5 61.9,24.5 H38 C36.7,24.5 36.1,25.5 36.1,27.6 Z" fill="#dfe2ee" stroke="#1a1a1a" stroke-width="#{STROKE_W}" stroke-linejoin="round" vector-effect="non-scaling-stroke"/><path d="M40.7,30.8 V49.9 M45.3,30.8 V49.9 M54.6,30.8 V49.9 M59.2,30.8 V49.9 M39.8,70.6 H60.1" fill="none" stroke="#1a1a1a" stroke-width="#{STROKE_W}" stroke-linecap="round" vector-effect="non-scaling-stroke"/><path d="M51.4,16 H48.5 C48,16 47.6,17 47.6,18.1 V22.4 C47.6,23.5 48,24.5 48.5,24.5 H51.4 C51.9,24.5 52.3,23.5 52.3,22.4 V18.1 C52.3,17 51.9,16 51.4,16 Z" fill="none" stroke="#1a1a1a" stroke-width="#{STROKE_W}" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>)
    }[v[:kind]].to_s

    # Everything is drawn in the ORIGINAL coordinate space and stretched by
    # WIDTH_SCALE, so the ten silhouettes above stay exactly as authored.
    # vector-effect keeps the stroke round under that non-uniform scale — it
    # would otherwise be twice as thick on the vertical sides as on the curves.
    <<~SVG.html_safe
      <svg class="nps-vessel" viewBox="0 0 #{w * WIDTH_SCALE} #{VESSEL_H}" preserveAspectRatio="xMidYMid meet" aria-hidden="true" focusable="false">
        <defs>
          <linearGradient id="nps-g-#{shape}" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" style="stop-color: var(--brand-primary, #16e0c4)"/>
            <stop offset="1" style="stop-color: var(--brand-primary, #01c9ad); stop-opacity: .85"/>
          </linearGradient>
          <clipPath id="nps-c-#{shape}"><path d="#{v[:path]} Z"/></clipPath>
        </defs>
        <g transform="scale(#{WIDTH_SCALE} 1)">
          <g clip-path="url(#nps-c-#{shape})">
            <rect x="-40" y="0" width="#{w + 80}" height="#{VESSEL_H}" fill="#eef0f6"/>
            <g class="nps-liquid">
              <g class="nps-surface">
                <path class="nps-wave2" d="#{wave.call(3)}" fill="url(#nps-g-#{shape})"/>
                <path class="nps-wave"  d="#{wave.call(0)}" fill="url(#nps-g-#{shape})"/>
              </g>
              <rect x="-40" y="4" width="#{w + 80}" height="440" fill="url(#nps-g-#{shape})"/>
              #{nps_bubbles(v[:cx], v[:hw], rng)}
            </g>
          </g>
          <path d="#{v[:path]}" fill="none" stroke="#1a1a1a" stroke-width="#{STROKE_W}" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>
          #{extras}
        </g>
      </svg>
    SVG
  end

  # Nine bubbles rising up through the liquid. Each carries its own rise/sway/
  # duration/delay so they read as an uneven stream. They live INSIDE the
  # translated `.nps-liquid` group, so they only ever appear within the fluid.
  def nps_bubbles(cx, hw, rng)
    Array.new(9) do
      x     = cx + (rng.rand * 2 - 1) * hw * 0.6
      r     = 1.8 + rng.rand * 2.2
      start = 150 + rng.rand * 85
      rise  = -(start - (10 + rng.rand * 8))
      sway  = rng.rand * 8 - 4
      dur   = 1.9 + rng.rand * 1.5
      delay = rng.rand * 2.6
      %(<circle cx="#{x.round(1)}" cy="#{start.round}" r="#{r.round(1)}" fill="#ecfffb" class="nps-bub" ) +
        %(style="--rise: #{rise.round}px; --sway: #{sway.round(1)}px; --dur: #{dur.round(2)}s; --d: #{delay.round(2)}s"/>)
    end.join.html_safe
  end
end
