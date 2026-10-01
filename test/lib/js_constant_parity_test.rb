require "test_helper"

# Several card-type lists exist twice: once in Ruby, once in a JS module the
# editor and player import. Today they are kept in step by comments that say
# "keep in lock-step" — which is not a mechanism.
#
# That is not hypothetical. `consent_gate` was added to Survey::PAGED_TYPES on
# the server and the JS side kept saying `type === "scenario"`, so the editor
# stopped emitting `pages` for a consent gate: every autosave posted the card
# with no pages, the sanitiser rewrote them to [], and the gate went on
# blocking respondents while showing a blank screen and recording no consent
# snapshot — the compliance artefact the feature exists for. The whole feature
# had passing tests, because none of them made a round trip through the editor.
#
# Parsing JS with a regex is crude, but the alternative is a JS test runner the
# repo doesn't have, and the assertions below fail loudly if the shape of the
# file changes rather than silently passing.
class JsConstantParityTest < ActiveSupport::TestCase
  def js(path)
    File.read(Rails.root.join("app/javascript", path))
  end

  # Pulls `export const NAME = [ "a", "b" ]` out of a module.
  def js_array(path, name)
    source = js(path)
    match  = source[/export const #{Regexp.escape(name)}\s*=\s*\[(.*?)\]/m]
    assert match, "#{path} no longer exports a `#{name}` array — this test can " \
                  "no longer see the constant it is meant to be guarding."
    match[/\[(.*?)\]/m, 1].scan(/"([^"]+)"/).flatten
  end

  test "lib/paged_types.js matches Survey::PAGED_TYPES" do
    assert_equal Survey::PAGED_TYPES.sort, js_array("lib/paged_types.js", "PAGED_TYPES").sort,
                 "the editor decides whether to serialize a card's `pages` from this list. " \
                 "A type the server treats as paged but the JS does not will have its pages " \
                 "silently dropped on the next autosave."
  end

  test "lib/routable_types.js matches LogicGraph::ROUTABLE" do
    assert_equal LogicGraph::ROUTABLE.map(&:to_s).sort,
                 js_array("lib/routable_types.js", "ROUTABLE_TYPES").sort,
                 "a type routable on the server but not in the editor gets no routing UI; " \
                 "the reverse offers routing the compiler will discard."
  end

  # The editor decides whether to OFFER a mobile background from the JS list and
  # the server decides whether to STORE one from the Ruby list. Out of step in
  # one direction the creator sets a background that is silently dropped on the
  # next autosave; in the other, a type that can carry one is never offered it.
  test "lib/full_screen_types.js matches CardTypes::FULL_SCREEN_ANSWER_TYPES" do
    assert_equal CardTypes::FULL_SCREEN_ANSWER_TYPES.sort,
                 js_array("lib/full_screen_types.js", "FULL_SCREEN_ANSWER_TYPES").sort,
                 "the mobile background is offered on the types in the JS list and stored for " \
                 "the types in the Ruby one. A type in only one of them either loses what the " \
                 "creator set, or is never offered the one design a phone can carry."
  end

  test "lib/question_types.js matches CardTypes::NON_QUESTION_TYPES" do
    assert_equal CardTypes::NON_QUESTION_TYPES.sort,
                 js_array("lib/question_types.js", "NON_QUESTION_TYPES").sort,
                 "a type the server treats as a non-question but the JS does not gets scored, " \
                 "counted and rendered as if it asked something."
  end

  # This list was hand-copied into four JS files and one of them went stale —
  # results_compare kept the two-element version from before consent_gate, so
  # the compare view built an empty expandable block for one. There is one copy
  # now, and this asserts nobody re-types it.
  test "the non-question list is defined once" do
    definitions = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
      File.read(path).match?(/(?:const|let|var)\s+(?:NON_QUESTION_TYPES|SKIP_TYPES)\s*=\s*(?:new Set\()?\[/)
    end.map { |path| path.sub("#{Rails.root}/app/javascript/", "") }

    assert_equal [ "lib/question_types.js" ], definitions,
                 "import NON_QUESTION_TYPES from lib/question_types instead of re-typing it"
  end

  # Every type a creator can pick must have placeholder options — including the
  # ones that deliberately have none, so an omission stays distinguishable from
  # a decision. `prioritise` and `nps` were missing from the add-question copy,
  # so picking Prioritise there produced a card with no options at all.
  test "every pickable type has default options" do
    source = js("lib/default_options.js")
    table  = source[/export const DEFAULT_OPTIONS = \{(.*?)\n\}/m]
    assert table, "DEFAULT_OPTIONS not found in lib/default_options.js"

    missing = CardTypes.pickable.map(&:first).reject { |type| table.match?(/^\s+#{Regexp.escape(type)}:/) }
    assert_empty missing,
                 "these pickable types have no entry, so a card created as one arrives empty: " \
                 "#{missing.inspect}"
  end

  test "the default-options table is defined once" do
    definitions = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
      File.read(path).match?(/(?:export\s+)?(?:const|let|var)\s+DEFAULT_OPTIONS\s*=\s*\{/)
    end.map { |path| path.sub("#{Rails.root}/app/javascript/", "") }

    assert_equal [ "lib/default_options.js" ], definitions
  end

  # Bounds, not lists — same mirroring problem, and these had no JS side at all,
  # so the editor let a creator write a seventh page and the sanitiser dropped
  # it on the next save without a word.
  def js_number(path, name)
    source = js(path)
    match  = source[/export const #{Regexp.escape(name)}\s*=\s*(\d+)/, 1]
    assert match, "#{path} no longer exports a numeric `#{name}`"
    match.to_i
  end

  test "lib/page_limits.js matches the Survey page bounds" do
    assert_equal Survey::MAX_SCENARIO_PAGES, js_number("lib/page_limits.js", "MAX_PAGES"),
                 "the editor refuses to add a page past this; if it is higher than the " \
                 "server's cap the extra pages are silently discarded on save."
    assert_equal Survey::MAX_SCENARIO_PAGE_LENGTH, js_number("lib/page_limits.js", "MAX_PAGE_LENGTH")
  end

  # The advisory scoring thresholds must stay STRICTER than the hard caps, so a
  # creator is nudged well before anything is actually thrown away.
  test "the Rules of the Game warn before the hard limits bite" do
    rules = js("lib/verto_rules.js")
    max_pages  = rules[/PAGE_RULES\s*=\s*\{[^}]*max:\s*(\d+)/, 1].to_i
    max_length = rules[/PAGE_LENGTH_LIMIT\s*=\s*(\d+)/, 1].to_i

    assert_operator max_pages, :>, 0, "expected to find PAGE_RULES.max in verto_rules.js"
    assert_operator max_pages, :<=, Survey::MAX_SCENARIO_PAGES
    assert_operator max_length, :>, 0, "expected to find PAGE_LENGTH_LIMIT in verto_rules.js"
    assert_operator max_length, :<=, Survey::MAX_SCENARIO_PAGE_LENGTH
  end

  # The list is only worth asserting against if it is non-trivial — an empty or
  # unparsed array would make both tests above pass by comparing nothing.
  test "the parsed JS constants are non-empty" do
    assert_operator js_array("lib/paged_types.js", "PAGED_TYPES").size, :>=, 2
    assert_operator js_array("lib/routable_types.js", "ROUTABLE_TYPES").size, :>=, 5
  end

  # Option-row markup existed three times client-side (type panel rebuilds,
  # card_editor's "Add option", scenario's answer page) and one copy drifted:
  # "＋ Add option" built a tile-less row that sat visibly mis-sized between
  # the server-rendered rows until the next reload. One template module now.
  test "the option-row markup is defined once" do
    %w[choice-list-item\ pick-item choice-card].each do |marker|
      definitions = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
        File.read(path).include?(%(class="#{marker}"))
      end.map { |path| path.sub("#{Rails.root}/app/javascript/", "") }

      assert_equal [ "lib/choice_templates.js" ], definitions,
                   "build option rows via lib/choice_templates instead of re-typing the " \
                   "markup — a drifted copy renders mis-sized rows until the next reload"
    end
  end

  # A tap card's response strip existed twice the moment it existed at all: the
  # server partial and the type panel's rebuild. The previous pair had already
  # drifted — COMPONENTS.tap_card was still emitting a two-button ✕/✓ strip long
  # after the card had grown a third response and a controls scrim — so a card
  # rebuilt by a type switch looked nothing like the same card after a reload.
  test "the response-strip markup is defined once" do
    # The wrapper's own class is interpolated (it varies with `strong`), so the
    # markers are the two fixed classes inside it plus the hook the serializer
    # finds the strip by — between them nothing can build a strip elsewhere.
    # The mark's marker is an unclosed prefix: the editor flavour appends
    # `rotate-action-btn--editable` (the mark is the 🎨 popover's click target).
    [ %(class="rotate-action-btn), %(class="rotate-action-label"), "data-tap-response-label>" ].each do |marker|
      definitions = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
        File.read(path).include?(marker)
      end.map { |path| path.sub("#{Rails.root}/app/javascript/", "") }

      assert_equal [ "lib/tap_response_templates.js" ], definitions,
                   "build the response strip via lib/tap_response_templates instead of " \
                   "re-typing the markup (#{marker}) — the last two copies of it drifted apart"
    end
  end

  # The scale itself lives twice: Ruby renders it, the editor rebuilds it. A
  # drifted key is worse than a drifted label — the key IS the stored answer, so
  # a strip rebuilt with the wrong one records answers nothing can read back.
  test "lib/tap_scales.js matches TapScales" do
    source = js("lib/tap_scales.js")
    table  = source[/export const TAP_PRESETS = \{(.*?)\n\}/m]
    assert table, "lib/tap_scales.js no longer exports a TAP_PRESETS table"

    TapScales.preset_counts.each do |count|
      TapScales.preset(count).each do |entry|
        assert_includes table, %(key: "#{entry["key"]}"),
                        "preset #{count} names #{entry["key"]} in Ruby but not in JS"
      end
    end

    %w[MIN_TAP_RESPONSES MAX_TAP_RESPONSES DEFAULT_TAP_COUNT TAP_FAN_THRESHOLD
       FAN_START FAN_END].zip(
      [ TapScales::MIN_RESPONSES, TapScales::MAX_RESPONSES,
        TapScales::DEFAULT_COUNT, TapScales::FAN_THRESHOLD,
        TapScales::FAN_START.to_i, TapScales::FAN_END.to_i ]
    ).each do |name, value|
      assert_match(/export const #{name} = #{value}\b/, source,
                   "#{name} disagrees with Ruby, so the editor and the server bound the scale differently")
    end
  end

  # The swipe glyphs are inline SVG on both sides (the editor cannot wait for a
  # round trip to draw a strip). A drifted path is a button with the wrong
  # artwork on it — or, since they are drawn from a shared fallback, the wrong
  # answer's artwork.
  test "the tap glyph paths match ApplicationHelper::TAP_RESPONSE_ICONS" do
    source = js("lib/tap_response_templates.js")
    ApplicationHelper::TAP_RESPONSE_ICONS.each do |name, svg|
      path = svg[/ d="([^"]+)"/, 1]
      assert_includes source, path, "the #{name} glyph has drifted from the Ruby constant"
    end
  end

  test "serialize emits the tap response scale" do
    assert_match(/out\.responses/, js("controllers/survey_editor_controller.js"),
                 "serialize() no longer emits responses — every re-scaled tap card " \
                 "falls back to the default three on the next autosave")
  end

  # Per-option style overrides are serialized for exactly the types the server
  # sanitiser accepts them on — drift in either direction silently loses a
  # creator's colours/icons on the next autosave.
  test "lib/option_style_types.js matches Survey::OPTION_STYLE_TYPES" do
    assert_equal Survey::OPTION_STYLE_TYPES.sort,
                 js_array("lib/option_style_types.js", "OPTION_STYLE_TYPES").sort
  end

  # The single most common data-loss shape in this codebase: a card field the
  # serializer doesn't emit is stripped on the next autosave of ANY card.
  test "serialize emits option_styles" do
    assert_match(/out\.option_styles/, js("controllers/survey_editor_controller.js"),
                 "serialize() no longer emits option_styles — every styled deck " \
                 "loses its overrides on the next autosave")
  end

  # A rating card's own emoji and a card's text ink are both read back off the
  # card row by the serializer; a field it stops emitting is stripped on the
  # next autosave of ANY card.
  test "serialize emits rating_emoji and text_ink" do
    source = js("controllers/survey_editor_controller.js")
    assert_match(/out\.rating_emoji/, source,
                 "serialize() no longer emits rating_emoji — every rating card with its own " \
                 "emoji goes back to the themed glyph on the next autosave")
    assert_match(/out\.text_ink/, source,
                 "serialize() no longer emits text_ink — every card a creator gave dark or " \
                 "light words goes back to the measured ink on the next autosave")
  end

  test "serialize emits the rich-text layer" do
    source = js("controllers/survey_editor_controller.js")
    %w[out\.text_html out\.description_html out\.options_html].each do |emission|
      assert_match(/#{emission}/, source,
                   "serialize() no longer emits #{emission.delete("\\")} — every formatted deck " \
                   "loses its rich text on the next autosave")
    end
  end

  # The SDG titles and official colours live twice: UnSdgs stamps a source with
  # goal NUMBERS only, and the Ask Verto stream resolves them to chips
  # client-side. A drifted copy paints goal 13 a different green in the live
  # stream than in the server-rendered replay of the very same answer.
  test "lib/un_sdgs.js titles and colours match UnSdgs" do
    source = js("lib/un_sdgs.js")
    js_map = ->(name) do
      body = source[/export const #{name} = \{(.*?)\n\}/m, 1]
      assert body, "lib/un_sdgs.js no longer exports #{name}"
      body.scan(/(\d+):\s*"([^"]+)"/).to_h { |n, v| [ n.to_i, v ] }
    end

    assert_equal UnSdgs::TITLES, js_map.call("SDG_TITLES")
    assert_equal UnSdgs::COLORS, js_map.call("SDG_COLORS")
  end

  # The palette maths lives twice (live preview vs server render); the roles
  # drifting means a colour a creator can pick that one side silently ignores.
  test "lib/brand_palette.js roles and defaults match BrandPalette" do
    assert_equal BrandPalette::ROLES, js_array("lib/brand_palette.js", "ROLES"),
                 "a role missing from the JS side never live-previews; missing from " \
                 "Ruby it never renders for respondents"

    js_default = js("lib/brand_palette.js")[/export const DEFAULT = \{(.*?)\}/m, 1]
                   .scan(/(\w+):\s*"([^"]+)"/).to_h
    assert_equal BrandPalette::DEFAULT, js_default,
                 "differing defaults make default? disagree across the mirror, so the " \
                 "same palette brands the player but not the editor (or vice versa)"
  end

  # Every derived key has to exist on BOTH sides, or the live preview and the
  # served page disagree about a colour. primary_ink is the one that prompted
  # this: a key added in Ruby and forgotten in JS would preview a creator's
  # selected answers in the raw brand colour and then serve respondents the
  # readable one — the preview lying about the product, which is the exact
  # failure the mirror exists to prevent.
  test "lib/brand_palette.js derives the same keys as BrandPalette#resolve" do
    ruby_keys = BrandPalette.resolve("primary" => "#01EACB").keys.sort
    body = js("lib/brand_palette.js")[/export function resolve\(raw\) \{.*?\n\}/m]
    assert body, "resolve() not found in lib/brand_palette.js"

    js_keys = (body.scan(/^\s{4}(\w+):/).flatten + BrandPalette::ROLES).uniq.sort
    assert_equal ruby_keys, js_keys,
                 "the two sides of the palette derive different keys. Missing in JS: " \
                 "#{(ruby_keys - js_keys).inspect}; missing in Ruby: #{(js_keys - ruby_keys).inspect}"

    # …and every one of them needs a CSS variable name, or it is derived and
    # then dropped on the floor.
    vars = js("lib/brand_palette.js")[/export const CSS_VARS = \{(.*?)\n\}/m, 1].scan(/(\w+):/).flatten
    assert_empty ruby_keys - vars - %w[panel],
                 "these derived colours have no --brand-* variable, so nothing can read " \
                 "them: #{(ruby_keys - vars - %w[panel]).inspect}"
  end

  # The derivation itself, not just its name. Ported by hand once already; a
  # silent divergence here shows up as a preview that is a shade off.
  test "readableInk in the JS mirror agrees with BrandPalette#readable_ink" do
    source = js("lib/brand_palette.js")
    assert_includes source, "export function readableInk",
                    "the JS mirror has no readableInk, so the live preview cannot derive " \
                    "the readable selected-label colour at all"
    assert_match(/step \+= 0\.02/, source,
                 "the JS mirror walks in different steps from the Ruby side, so the two " \
                 "will stop on different shades of the same brand")
    assert_match(/minRatio = 4\.5/, source,
                 "the JS mirror targets a different contrast ratio from the Ruby side")
    assert_match(/readableInk\(p\.primary, lighten\(p\.primary, 0\.88\)\)/, source,
                 "the JS mirror measures against a different surface — rgba(P, 0.12) over " \
                 "white is lighten(P, 0.88), and anything else is not the row the label " \
                 "actually sits on")
  end

  # The specific hole the drift went through: the editor's type panel builds a
  # card's right-hand component from a lookup table, falling back to an empty
  # string. A type missing from that table silently blanks the card when a
  # creator picks it, which is how consent_gate behaved.
  #
  # Scoped to EVERY pickable type, not just the paged ones. The first version of
  # this test checked PAGED_TYPES only and passed while `token_checkpoint` — the
  # one other type with the same gap — was still missing. A guard written from a
  # single bug tends to be shaped like that bug; the rule is "anything a creator
  # can pick must render as something".
  test "every pickable card type has a component builder in the type panel" do
    source = js("controllers/type_panel_controller.js")
    table  = source[/const COMPONENTS = \{(.*?)\n\}/m]
    assert table, "COMPONENTS table not found in type_panel_controller.js"

    pickable = CardTypes.pickable.map(&:first)
    assert_operator pickable.size, :>=, 10, "expected the pickable list to be substantial"

    missing = pickable.reject { |type| table.match?(/^\s+#{Regexp.escape(type)}:/) }
    assert_empty missing,
                 "these types fall through to COMPONENTS' `() => \"\"` default, so picking " \
                 "them in the Answer Type panel blanks the card: #{missing.inspect}. " \
                 "A type that deliberately renders nothing still needs an explicit entry " \
                 "(see welcome_card), so an omission stays distinguishable from a decision."
  end

  # The hole the builder-key test above cannot see: the KEY can exist while the
  # identifier behind it does not. COMPONENTS.yes_no called `yesNoItemHtml`,
  # which lib/choice_templates exports — and this file never imported. Importmap
  # ships source, nothing compiles, so the miss surfaced only as a click-time
  # ReferenceError inside applyType: "Yes / No" showed in every picker and
  # silently did nothing when applied (Stimulus swallows action errors into
  # handleError). This asserts every bare identifier the file calls is imported,
  # defined in the file, or a recognised JS global — extend the globals list
  # when a new browser API is legitimately adopted.
  test "type_panel_controller calls only identifiers it imports or defines" do
    code = js("controllers/type_panel_controller.js").gsub(%r{//.*$}, "")

    imported = code.scan(/^import\s*\{([^}]*)\}/).flatten
                   .flat_map { |list| list.split(",") }
                   .map { |name| name.split(/\s+as\s+/).last.strip }
                   .reject(&:empty?)
    imported += code.scan(/^import\s+(\w+)\s+from/).flatten

    defined = code.scan(/(?:function|const|let|var)\s+([A-Za-z_$][\w$]*)/).flatten
    # Class/object method definitions look like calls at line start; their
    # names count as defined (calls to them go through `this.`/the table).
    defined += code.scan(/^\s*(?:static\s+|async\s+|get\s+|set\s+)*#?([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/).flatten

    globals = %w[
      if for while switch catch return typeof await function
      Array Boolean CustomEvent Date Error Event JSON Map Math Number Object
      Promise RegExp Set String WeakMap WeakSet
      clearTimeout setTimeout clearInterval setInterval fetch
      requestAnimationFrame cancelAnimationFrame structuredClone
      parseFloat parseInt isNaN alert confirm
    ]
    # CSS/SVG functions inside the builders' template strings — not JS calls.
    globals += %w[var url scale rotate translate calc rgb rgba]

    known   = (imported + defined + globals).to_set
    # No whitespace before the paren: prose inside the builders' strings reads
    # "richer data (the ORDER…)", and a space-tolerant scan flags it.
    called  = code.scan(/(?<![.\w$#])(?<!new )([A-Za-z_$][\w$]*)\(/).flatten.uniq
    unknown = called.reject { |name| known.include?(name) }

    assert_empty unknown,
                 "type_panel_controller.js calls #{unknown.inspect} without importing or " \
                 "defining them. In an importmap app that is not a build error — it is a " \
                 "ReferenceError at click time, and Stimulus swallows it, so the button " \
                 "just silently does nothing (how yes_no shipped unpickable)."
  end

  # The original defect, stated directly: `type === "scenario"` where the rule is
  # "is this a paged type".
  #
  # Scanned across every editor JS file rather than the two that were fixed —
  # the first version listed two paths by hand and missed lib/verto_rules.js,
  # which still had the literal. A ban that only covers the files you already
  # edited bans nothing.
  # TYPE_LABEL is the load-bearing English fallback typeLabel() (Rules of the
  # Game variety feedback) falls back to when card.type_label.<ty> has no
  # translation for the current locale — including English itself, since
  # en.yml carries the same key/value pairs rather than relying on the miss
  # path (see card.eyebrow's identical precedent). A drifted copy would
  # silently change what an English creator sees the moment ANY locale's
  # translation exists, because the two are meant to read identically.
  test "en.yml's card.type_label matches lib/verto_rules.js's TYPE_LABEL" do
    source = js("lib/verto_rules.js")
    body   = source[/const TYPE_LABEL = \{(.*?)\n\}/m, 1]
    assert body, "lib/verto_rules.js no longer defines TYPE_LABEL in the expected shape"
    js_map = body.scan(/(\w+):\s*"([^"]+)"/).to_h

    assert js_map.size >= 10, "expected TYPE_LABEL to be substantial, parsed #{js_map.size} entries"
    assert_equal js_map, I18n.t("card.type_label", locale: :en).transform_keys(&:to_s)
  end

  test "no editor JS gates paged behaviour on the literal type name" do
    offenders = Dir[Rails.root.join("app/javascript/**/*.js")].filter_map do |path|
      rel = path.sub("#{Rails.root}/app/javascript/", "")
      # Comments stripped first: lib/paged_types.js documents the banned pattern
      # by quoting it, and a guard that flags its own explanation is a guard
      # people delete.
      code = File.read(path).gsub(%r{//.*$}, "")
      rel if code.match?(/type\s*===\s*"scenario"/)
    end
    assert_empty offenders,
                 "#{offenders.inspect} gate behaviour on the literal type `scenario`. " \
                 "Use isPaged() from lib/paged_types so a new paged type is picked up — " \
                 "this is what let a consent gate lose its pages on every save."
  end

  # ── Rich-text markers ─────────────────────────────────────────────────────
  # The floating font/bold toolbar shows itself only inside an element carrying
  # `data-rich-text` (rich_text_controller.js#_region). The server partial marks
  # its option rows; the client templates that build the SAME rows — "＋ Add
  # option", and every row of a card whose answer type was picked in-session —
  # did not, so an Image List built in the editor could not be given a font
  # until the next full reload, while the Image Grid beside it (never rebuilt
  # client-side) could. Marker parity, per row shape, on both sides.
  def template_body(source, name)
    body = source[/export function #{Regexp.escape(name)}\(.*?\n\}/m]
    assert body, "lib/choice_templates.js no longer defines #{name}"
    body
  end

  RICH_LABEL = /contenteditable="true"[^>]*\bdata-rich-text\b/

  test "client-built editable labels are rich-text regions exactly where their server twins are" do
    source  = js("lib/choice_templates.js")
    partial = File.read(Rails.root.join("app/views/shared/_card_component.html.erb"))

    %w[choiceListItemHtml prioritiseItemHtml choiceGridItemHtml].each do |name|
      assert_match RICH_LABEL, template_body(source, name),
                   "#{name} builds an editable label with no data-rich-text: a row added or " \
                   "rebuilt in this session shows no formatting toolbar until the page is reloaded"
    end
    refute_match RICH_LABEL, template_body(source, "yesNoItemHtml"),
                 "yes_no labels are the translated canonical Yes/No — the server row has no " \
                 "data-rich-text, and the client row must match it"

    # The server side of the same contract: list, prioritise, grid and the
    # scenario answer page all mark their label; the yes_no row does not.
    marked = partial.scan(/(?:pick-text choice-list-label|choice-label)" <%= ce_attr %> <%= "data-rich-text"\.html_safe if editable %>/)
    assert_operator marked.size, :>=, 4,
                    "expected the list, prioritise, grid and scenario-answer rows of " \
                    "_card_component.html.erb to carry data-rich-text; found #{marked.size}"
    yes_no_row = partial.lines.find { |l| l.include?('t("card.#{canon_label.downcase}"') }
    assert yes_no_row, "the yes_no row's markup moved — update this test's anchor"
    refute_includes yes_no_row, "data-rich-text"

    # Scenario page text: the type panel's rebuild and "＋ Add page" both build
    # the .book-page-text the server marks (and renders through rich_page_text).
    page_text = /book-page-text" contenteditable="true"[^>]*\bdata-rich-text\b/
    scenario  = js("controllers/type_panel_controller.js")[/^  scenario: \(opts, ctx = \{\}\) => \{.*?^  \},/m]
    assert scenario, "type_panel_controller.js no longer has a scenario: builder"
    assert_match page_text, scenario, "a scenario rebuilt by the type panel has unformattable pages"
    assert_match page_text, js("controllers/scenario_controller.js"), "a page added with ＋ Add page is unformattable"
  end

  # ── Save warnings ─────────────────────────────────────────────────────────
  # Every silent repair the server makes on save is reported through one
  # `warnings` array of codes, and the editor used to answer all of them with
  # "an image didn't stick". The table in survey_editor_controller.js is what
  # turns a code into a sentence; a code the server can emit that the table
  # doesn't know falls back to the image wording — exactly the lie this pins
  # against.
  test "every save-warning code the server can emit has a message in the editor" do
    server = %w[app/models/survey.rb app/controllers/surveys_controller.rb].flat_map do |path|
      File.read(Rails.root.join(path)).scan(/warnings << "([a-z_]+)"/).flatten
    end.uniq.sort
    assert_operator server.size, :>=, 8, "expected to find the server's warning codes; got #{server.inspect}"

    source = js("controllers/survey_editor_controller.js")
    table  = source[/const SAVE_WARNING_KEYS = \{(.*?)\n\}/m, 1]
    assert table, "survey_editor_controller.js no longer defines SAVE_WARNING_KEYS"
    entries = table.scan(/(\w+):\s*"([^"]+)"/)

    assert_empty server - entries.map(&:first),
                 "server warning codes with no editor message — each would be reported as " \
                 "\"an image didn't stick\""
    entries.map(&:last).uniq.each do |key|
      assert I18n.exists?("js.#{key}", :en), "SAVE_WARNING_KEYS points at js.#{key}, which en.yml does not define"
    end
    refute_match(/flash\(t\("editor\.save_warning"\)/, source,
                 "_doSave must route through _saveWarningMessage, not the fixed image sentence")
  end

  # The picker refuses an upload it could not store once its inline fallback is
  # over the sanitiser's cap — the two sizes must agree, or the refusal is
  # either needless or too late (the creator gets "an image didn't stick").
  test "the media picker's inline cap matches Survey::MAX_BACKGROUND_DATA_URL_BYTES" do
    cap = js("controllers/media_picker_controller.js")[/static INLINE_DATA_URL_CAP\s*=\s*(\d+)/, 1]
    assert cap, "media_picker_controller.js no longer defines a numeric INLINE_DATA_URL_CAP"
    assert_equal Survey::MAX_BACKGROUND_DATA_URL_BYTES, cap.to_i
  end
end
