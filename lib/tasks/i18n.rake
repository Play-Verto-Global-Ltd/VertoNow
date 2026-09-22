require "yaml"

namespace :i18n do
  desc "Fill in missing translations in config/locales/<code>.yml from en.yml via Claude. " \
       "Merges: existing translations are kept, only missing keys are translated. " \
       "Usage: bin/rails i18n:translate          (all languages, missing keys only) " \
       "       bin/rails i18n:translate[es,fr]   (only these) " \
       "       FORCE=1 bin/rails i18n:translate   (re-translate every key)"
  # Batched (~150 keys/call) rather than one giant request, and a translated
  # key is only ever written if the model actually returned it — both fix the
  # same bug: a first run on a brand-new locale could ask for 1000+ keys in
  # one call, the model's response got cut off well before covering them all
  # (max_tokens: 16384 output, not input), and the old code silently filled
  # every key the response DIDN'T cover with the raw English source string as
  # though it were a translation. That written English then looked
  # "translated" (present?) to the next run's own todo filter, so those keys
  # were never retried — a truncated first run permanently pinned however
  # many hundred keys it didn't reach to English. Skipping the fallback write
  # entirely lets a key stay genuinely missing (Rails' own i18n fallback
  # already renders it in English at runtime — config.i18n.fallbacks = true)
  # until a later run actually translates it.
  BATCH_SIZE = 150

  task :translate, [ :only ] => :environment do |_t, args|
    require "anthropic"

    source = YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en")
    flat   = flatten_strings(source)

    only  = (args[:only] || ENV["ONLY"]).to_s.split(/[,\s]+/).reject(&:blank?)
    force = ENV["FORCE"].present?

    # English variants are excluded, not merely defaulted past. en-US differs
    # from en by SPELLING, and "translate these strings into English (US)" is
    # not a job a translator can do sensibly — it invites paraphrase where the
    # only wanted change is colour→color. `i18n:en_us` below is its maintenance
    # path, and being a transform it cannot drift structurally.
    targets = SupportedLocales.codes.reject { |c| SupportedLocales.english?(c) }
    targets &= only if only.any?
    # A registry code with no file is not a translation target, it is a new
    # file — and creating one has consequences nobody asked for here. `zh` is
    # in supported_locales.yml with no config/locales/zh.yml; the moment one
    # exists it joins the three parity suites that glob the directory and
    # SupportedLocales.ui_ready starts offering Chinese in the switcher. Adding
    # it is a decision, not a side effect of running a translation.
    targets = targets.select { |c| Rails.root.join("config/locales/#{c}.yml").exist? }

    # ── Working without a key ────────────────────────────────────────────────
    #
    # The same hatch bin/trello_week_summary carries, for the same reason: the
    # thing on the other side of this API call is Claude, and a Claude session
    # holding no key can do the work itself. PRINT emits exactly what would be
    # asked; TRANSLATIONS feeds the answer back through the identical merge and
    # write path, so the hatch cannot drift from the API path.
    #
    # Both are read-with-encoding on purpose: a locale-less container (cron, a
    # sandbox) has Encoding.default_external == US-ASCII, and JSON.parse raises
    # Encoding::InvalidByteSequenceError on the first accented byte of a file
    # that is perfectly good UTF-8. trello_week_summary:102-105 hit this first.
    print_to = ENV["PRINT"].presence
    supplied = if ENV["TRANSLATIONS"].present?
      JSON.parse(File.read(ENV["TRANSLATIONS"], encoding: "UTF-8"))
    end

    # Built only when a batch is actually about to be sent, so neither hatch
    # mode trips over a missing key. This used to be an eager ENV.fetch, which
    # meant no key = KeyError before any work, for every locale, with no
    # partial output and nothing to show for it.
    client = nil
    payload = {}

    targets.each do |code|
      out_path      = Rails.root.join("config/locales/#{code}.yml")
      existing      = out_path.exist? ? (YAML.load_file(out_path)[code] || {}) : {}
      existing_flat = flatten_strings(existing)

      # Only translate keys that don't already have a translation (unless FORCE).
      todo = force ? flat : flat.reject { |k, _| existing_flat[k].present? }
      if todo.empty?
        puts "skip #{code} (up to date)"
        next
      end

      loc = SupportedLocales.find(code)

      if print_to
        payload[code] = todo
        puts "#{code}: #{todo.size} key(s)"
        next
      end

      translated =
        if supplied
          # Only what this locale was actually given. Keys outside `todo` are
          # dropped rather than written: the point of the hatch is to be the
          # same operation the API path is, and that one can only ever answer
          # the question it was asked.
          (supplied[code] || {}).slice(*todo.keys)
        else
          client ||= Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
          batches = todo.each_slice(BATCH_SIZE).map(&:to_h)
          puts "translating -> #{code} (#{loc&.english_name}) — #{todo.size} key(s) in #{batches.size} batch(es)"
          batches.each_with_index.each_with_object({}) do |(batch, i), acc|
            print "  batch #{i + 1}/#{batches.size} (#{batch.size} keys)… "
            acc.merge!(translate_batch(client, loc, batch))
            puts "ok"
          rescue StandardError => e
            warn "failed: #{e.class}: #{e.message} — keeping what this locale already has for this batch"
          end
        end

      # Placeholders are keyword arguments, not prose. A value that dropped or
      # renamed one is not a slightly worse translation, it is
      # I18n::MissingInterpolationArgument in front of a respondent — and until
      # now the only thing asking for them to be preserved was one line of
      # prompt text with nothing checking it. Refusing the value leaves the key
      # missing, which is the state the next run knows how to fix.
      #
      # you.wallet_across is the case that proves it: "Across %{vertos} and
      # %{organisations}." carries a BRITISH-SPELLED variable name, and a
      # translator tidying it to %{organizations} breaks that locale alone.
      translated = translated.reject do |k, v|
        source = todo[k]
        next false if source.nil?

        bad = placeholders(source) != placeholders(v)
        warn "  #{code}: dropped #{k} — placeholders #{placeholders(source).to_a.inspect} " \
             "became #{placeholders(v).to_a.inspect}" if bad
        bad
      end

      if translated.empty?
        puts "skip #{code} (no batch returned anything usable)"
        next
      end

      # Only ever ADD. A key the model didn't return, or one whose placeholders
      # were refused above, is simply left out — never backfilled with English
      # (see the BATCH_SIZE comment for why that was the bug) and never
      # rewritten (see splice_into_locale! for why the old whole-file rewrite
      # could not be kept).
      added = splice_into_locale!(out_path, code, translated.reject { |k, _| existing_flat[k].present? })
      puts "wrote #{out_path.relative_path_from(Rails.root)} " \
           "(+#{added} line(s), #{translated.size} new, #{todo.size - translated.size} still missing)"
    end

    if print_to
      json = JSON.pretty_generate(payload)
      if print_to == "1"
        puts json
      else
        File.write(print_to, json, encoding: "UTF-8")
        puts "wrote #{payload.values.sum(&:size)} key(s) across #{payload.size} locale(s) to #{print_to}"
      end
    end
  end

  desc "Regenerate config/locales/en-US.yml from en.yml by respelling. " \
       "No API key needed — the two English variants differ in a closed set of " \
       "words, not in meaning. DIFF=1 checks without writing."
  # A word list rather than a regex, and that is the whole design: the near
  # misses are the danger. "analysis" is identical in both variants, and so are
  # "promise", "otherwise", "audience", "sequence", "confidence" and
  # "preference" — every one of which appears in en.yml, and every one of which
  # a blind /is([ae])/ rule would mangle.
  #
  # Generating also makes the KEY STRUCTURE identical by construction, which is
  # what LocaleStructureParityTest, LocaleRulesParityTest and
  # LocaleFlashParityTest each separately require of it.
  task en_us: :environment do
    lines = File.readlines(Rails.root.join("config/locales/en.yml"), encoding: "UTF-8")
    root  = lines.index { |l| l.start_with?("en:") }
    abort "en.yml no longer opens with an `en:` root key" unless root

    out = lines.map do |line|
      if line.strip.start_with?("#")
        EnglishSpellings.americanise(line)
      else
        # The VALUE side only. A key is an identifier the code looks up —
        # `editor.tab_tokens` is asked for by that name in both variants, and
        # respelling keys here would make every one of those lookups miss.
        m = line.match(/\A(\s*(?:- )?)([\w.\-]+:)?(\s*)(.*)\z/m)
        m ? "#{m[1]}#{m[2]}#{m[3]}#{EnglishSpellings.americanise(m[4])}" : line
      end
    end
    out[root] = "en-US:\n"

    body = EN_US_HEADER + out[root..].join
    path = Rails.root.join("config/locales/en-US.yml")

    if ENV["DIFF"].present?
      current = path.exist? ? File.read(path, encoding: "UTF-8") : ""
      puts(body == current ? "en-US.yml is up to date" : "en-US.yml would change — run without DIFF")
      next
    end

    File.write(path, body, encoding: "UTF-8")
    puts "wrote config/locales/en-US.yml"
  end
end

# One batched translation call: { dotted_key => english_source } in,
# { dotted_key => translated_value } out. Keys the model doesn't return (or
# returns unchanged from the key/source) are simply absent from the result —
# callers must not backfill them with English themselves (see BATCH_SIZE).
def translate_batch(client, loc, batch)
  response = client.messages.create(
    model: "claude-opus-4-7",
    max_tokens: 16384,
    tools: [ {
      name: "submit_translations",
      description: "Submit the translated UI strings as an array of {key, value} pairs.",
      input_schema: {
        type: "object",
        properties: {
          translations: {
            type: "array",
            description: "One entry per input key. 'key' is the dotted key exactly as given; 'value' is the translation of the English source string into the target language.",
            items: {
              type: "object",
              properties: {
                key:   { type: "string" },
                value: { type: "string" }
              },
              required: [ "key", "value" ]
            }
          }
        },
        required: [ "translations" ]
      }
    } ],
    tool_choice: { type: "tool", name: "submit_translations" },
    system: <<~SYS,
      You translate UI strings for a survey app and submit them via the
      submit_translations tool.

      The user gives you an object of { dotted_key: english_source_string }.
      You return a translations ARRAY where each entry has:
        - "key":   the dotted key, exactly as given
        - "value": the translation of the English source string into the
                   target language

      CRITICAL: every key in the input must appear exactly once in your
      output. "value" must be the translation. Never repeat the key as the
      value, and never repeat the English source verbatim unless it is a
      brand name ("Verto", "Playverto") or made up of only
      punctuation/numbers/whitespace.

      Worked example, target French:
        input:  { "card.yes": "Yes", "auth.email": "Email address" }
        output translations:
          [
            { "key": "card.yes",   "value": "Oui" },
            { "key": "auth.email", "value": "Adresse e-mail" }
          ]

      Other rules:
      - Preserve interpolation placeholders like %{name} verbatim.
      - Preserve HTML tags and their attributes exactly; translate only
        the human-readable text between tags.
      - Leave brand names ("Verto", "Playverto") untranslated.
      - Keep it natural and concise for UI use.
    SYS
    messages: [ {
      role: "user",
      content: "Target language: #{loc&.english_name} (#{loc&.native_name}).\n" \
               "Translate the English source values below into " \
               "#{loc&.english_name}. Return the SAME dotted keys with " \
               "TRANSLATED values — never copy the key into the value.\n\n" \
               "#{JSON.pretty_generate(batch)}"
    } ]
  )

  block = Array(response.content).find do |b|
    (b.respond_to?(:type) ? b.type : b["type"]).to_s == "tool_use"
  end
  raise "No tool_use block in response" unless block
  input = block.respond_to?(:input) ? block.input : block["input"]
  input = JSON.parse(input) if input.is_a?(String)
  input = input.transform_keys(&:to_s) if input.respond_to?(:transform_keys)
  pairs = input["translations"] || []
  pairs = JSON.parse(pairs) if pairs.is_a?(String)

  pairs.each_with_object({}) do |entry, acc|
    entry = entry.transform_keys(&:to_s) if entry.respond_to?(:transform_keys)
    k = entry["key"].to_s
    v = entry["value"].to_s
    # Sanity: a value equal to its key is a model mistake. Drop it so the
    # caller treats it as not-yet-translated rather than writing junk.
    acc[k] = v unless k.empty? || v == k
  end
end

# Flatten a nested hash to { "a.b.c" => "value" } (string leaves only). Array
# leaves are flattened too — each element becomes "a.b.c[0]", "a.b.c[1]", … so
# array-typed translations (e.g. example lists) round-trip back to arrays
# instead of being stringified.
def flatten_strings(hash, prefix = nil)
  hash.each_with_object({}) do |(k, v), acc|
    key = [ prefix, k ].compact.join(".")
    case v
    when Hash
      acc.merge!(flatten_strings(v, key))
    when Array
      v.each_with_index { |item, i| acc["#{key}[#{i}]"] = item.to_s }
    else
      acc[key] = v.to_s
    end
  end
end

# Rebuild a nested hash from { "a.b.c" => "value" }. Keys ending in "[N]" are
# rebuilt as arrays (companion to flatten_strings's array handling).
ARRAY_KEY = /\A(.+)\[(\d+)\]\z/

def unflatten(flat)
  flat.each_with_object({}) do |(dotted, value), root|
    if (m = dotted.match(ARRAY_KEY))
      base, idx = m[1], m[2].to_i
      keys = base.split(".")
      leaf = keys[0..-2].reduce(root) { |h, k| h[k] ||= {} }
      leaf[keys.last] ||= []
      leaf[keys.last][idx] = value
    else
      keys = dotted.split(".")
      leaf = keys[0..-2].reduce(root) { |h, k| h[k] ||= {} }
      leaf[keys.last] = value
    end
  end
end

# The interpolation names a string declares, as a Set so order doesn't matter
# (a translator is free to move %{name} after %{count}; it is not free to lose
# one). Both spellings i18n accepts: %{name} and sprintf's %<name>s.
#
# The scanner itself lives in app/lib so the parity suites check exactly what
# this guard checks. A rake file cannot be tested — the same reason
# EnglishSpellings is a class and not a lambda in here.
def placeholders(text)
  LocaleProperties.placeholders(text)
end

# ── Writing a locale file ───────────────────────────────────────────────────
#
# NOT `File.write(path, {code => unflatten(merged)}.to_yaml)`, which is what
# this task used to do and what every caller expects. Two measured reasons:
#
#   * flatten_strings/unflatten is LOSSY. `templates.*.cards` is an array of
#     Hashes, and flatten_strings does `item.to_s` on array elements — so 34
#     leaves per locale come back as Ruby inspect strings
#     (`{"text"=>"Une petite question", …}`), and the six `defaults.*` empty
#     arrays vanish entirely because each_with_index never runs. 816 corrupted
#     and 144 deleted leaves across 24 files, caught by
#     LocaleStructureParityTest only after the damage is on disk.
#   * Re-emitting from a Hash REFORMATS THE WHOLE FILE. The locale files are
#     hand-quoted ("Nécessaires"); Psych emits minimal quoting (Nécessaires).
#     Regenerating fr.yml while changing nothing rewrites 1,224 of its 1,896
#     lines. ~30,000 lines of churn to add 2,500 real ones is not reviewable,
#     and a reviewer who cannot read the diff cannot catch a bad translation.
#
# So: append-only text splicing. Every key this task writes is one that is
# ABSENT from the target — that is what `todo` means — so nothing is ever
# edited in place and a removal in the diff is a bug by definition.
#
# Returns the number of lines added.
def splice_into_locale!(path, code, additions)
  return 0 if additions.empty?

  original = File.read(path, encoding: "UTF-8")
  before   = YAML.load_file(path)[code] || {}
  lines    = original.lines

  # Group by the DEEPEST block the file already has on each key's path, and
  # splice each group in at the end of that block.
  #
  # It used to group by top-level namespace alone, which was correct only
  # because every key this task had ever written was one level deep. The first
  # `js.player.*` addition broke it: `js` exists, so the new leaves were
  # rendered as `player:` and appended inside it — a SECOND `player:` key under
  # `js:`, which YAML resolves by letting the last one win, silently deleting
  # every js.player string already there. The write-back assertion caught it
  # and reverted, which is what that assertion is for; this is the fix it was
  # asking for.
  #
  # Grouped by the deepest EXISTING parent rather than by the full parent path,
  # because the remainder has to be created: `player_join.title` in a file with
  # no player_join namespace appends the whole namespace, exactly as before.
  additions.group_by { |k, _| existing_block_path(lines, k.split(".")[0..-2]) }
           .each do |parent, pairs|
    # The part of each key that still has to be written, below the block we
    # are about to insert into.
    subtree = unflatten(pairs.to_h.transform_keys { |k| k.split(".").drop(parent.size).join(".") })
    body    = yaml_block(subtree, indent: 2 * (parent.size + 1))

    if parent.any?
      range = block_line_range(lines, parent)
      lines.insert(range.end + 1, *body.lines)
    else
      lines << "\n" unless lines.last.to_s.end_with?("\n")
      lines.concat(body.lines)
    end
  end

  File.write(path, lines.join, encoding: "UTF-8")

  # The write-back assertion. Re-parse what actually landed and prove it is
  # exactly what was there before plus what we meant to add — no pre-existing
  # leaf changed, none disappeared, nothing was reformatted into a different
  # type. A rewrite that silently ate `templates.*.cards` would have been
  # caught here rather than by a parity test three commits later.
  # A splice that lands where YAML cannot be is caught here too: without the
  # rescue the parse error escaped BEFORE the revert, and the broken file was
  # what the next test run found.
  after = begin
    YAML.load_file(path)[code] || {}
  rescue Psych::SyntaxError => e
    File.write(path, original, encoding: "UTF-8")
    raise "splice into #{File.basename(path)} produced YAML that does not parse (#{e.message}) — reverted"
  end
  wanted = deep_merge_flat(before, additions)
  unless after == wanted
    File.write(path, original, encoding: "UTF-8")
    raise "splice into #{File.basename(path)} changed something it should not have — reverted"
  end

  lines.size - original.lines.size
end

# `{ns => subtree}` as YAML, indented to sit under the locale root, with the
# document marker dropped.
#
# Every string scalar is forced to DOUBLE-QUOTED, which Psych would not do on
# its own — it quotes only what it must, so `label: Portefeuille` sits
# unquoted next to the `label: "Rejouer"` already in the file. Both are valid
# and equivalent; a hundred new lines in the minority style are not, because a
# reviewer reading a translation diff should be looking at the words rather
# than wondering why the punctuation changed. Doing it through the emitter's
# own node type rather than by wrapping strings in quotes is what keeps the
# escaping correct for the copy that contains a quote, a colon or a newline.
#
# line_width: -1 so a long sentence is never folded across lines — a folded
# scalar is legal YAML and unreadable in review.
def yaml_block(hash, indent: 2)
  visitor = Psych::Visitors::YAMLTree.create
  visitor << hash
  quote_mapping_values!(visitor.tree)
  visitor.tree.yaml(nil, line_width: -1)
         .sub(/\A---\n/, "").gsub(/^(?=.)/, " " * indent)
end

# A YAML mapping's children alternate key, value, key, value — so the values
# are the odd indices, and that is the only reliable way to tell one from the
# other. (Shape is not: "Portefeuille" is a value that looks exactly like the
# key "tab_wallet".) Psych reports `quoted: true` even for plain scalars, so
# the style constant is what to test.
def quote_mapping_values!(node)
  if node.is_a?(Psych::Nodes::Mapping)
    node.children.each_slice(2) do |_key, value|
      next unless value.is_a?(Psych::Nodes::Scalar)
      next unless value.style == Psych::Nodes::Scalar::PLAIN ||
                  value.style == Psych::Nodes::Scalar::ANY

      value.style = Psych::Nodes::Scalar::DOUBLE_QUOTED
    end
  end
  node.children&.each { |child| quote_mapping_values!(child) }
end

# The line range the block at `path` occupies, or nil if the file has no such
# block. Indentation is the only structure a text splice can see: a block whose
# path is n keys deep starts at `<2n spaces>key:` and ends before the next
# non-blank line indented that far or less — its own sibling, or an ancestor's.
#
# Each level is searched only INSIDE the range the level above resolved to, so
# a `player:` under `js:` is never mistaken for the top-level `player:`.
def block_line_range(lines, path)
  window = 0...lines.size
  range  = nil

  Array(path).each_with_index do |key, depth|
    pad   = "  " * (depth + 1)
    start = window.find { |i| lines[i].start_with?("#{pad}#{key}:") }
    return nil unless start

    # What closes the block: a non-blank line indented as far as the block's
    # own key OR LESS — its sibling, or an ancestor's. "Or less" is the part
    # that was missing: the check matched exactly `pad`, so a block two levels
    # deep that was not the last under its parent (`js.results`, followed by
    # the top-level `unsubscribe:`) ran on past the shallower key and ended
    # inside the NEXT namespace, and the splice landed there — as eight
    # six-space lines under a two-space key, which is not YAML (2026-09-22).
    closer = /\A {0,#{pad.size}}\S/
    finish = start
    ((start + 1)...lines.size).each do |i|
      line = lines[i]
      # A blank line inside a block belongs to it unless what follows has
      # closed the block — so look past the blank rather than stopping on it.
      next_real = lines[(i + 1)..]&.find { |l| l !~ /\A\s*\z/ }
      break if line =~ /\A\s*\z/ && next_real.to_s =~ closer
      break if line =~ closer

      finish = i
    end

    range  = start..finish
    window = (start + 1)..finish
  end

  range
end

# The longest prefix of `path` that the file actually has a block for. Where
# the remainder of the path has to be created, and therefore where the splice
# goes in. [] means "not even the top-level namespace exists": append it whole.
def existing_block_path(lines, path)
  candidate = Array(path)
  candidate = candidate[0..-2] while candidate.any? && block_line_range(lines, candidate).nil?
  candidate
end

# `before` deep-merged with the dotted-key additions, for the assertion above.
def deep_merge_flat(before, additions)
  wanted = Marshal.load(Marshal.dump(before))
  additions.each do |dotted, value|
    keys = dotted.split(".")
    leaf = keys[0..-2].reduce(wanted) { |h, k| h[k] ||= {} }
    leaf[keys.last] = value
  end
  wanted
end

# ── US English ──────────────────────────────────────────────────────────────
# The word list itself is EnglishSpellings (app/lib), not here: it is product
# knowledge about the copy, it is what LocaleEnUsTest checks, and a rake file
# cannot be tested.

EN_US_HEADER = <<~HEAD
  # US English — GENERATED from en.yml by `bin/rails i18n:en_us`. Do not edit by
  # hand; regenerate.
  #
  # Two English variants exist because the PDF import's optimiser was quietly
  # rewriting a creator's US spellings into UK ones. It had no instruction about
  # spelling at all — every generator's language instruction was skipped for the
  # default locale — so the model simply inherited the dialect of the prompts,
  # which are written in British English throughout. See PromptLanguage.
  #
  # A transform, not a translation: the structure has to mirror en.yml exactly
  # or the three locale parity tests fail, which is what they are for.
HEAD
