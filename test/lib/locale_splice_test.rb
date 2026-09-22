require "test_helper"

# The append-only splicer inside lib/tasks/i18n.rake.
#
# Its header says a rake file cannot be tested, and that is true of the TASK —
# it talks to an API and walks 24 files. These three helpers are not the task,
# they are the thing that writes to disk, and the failure they guard against is
# silent: a duplicate YAML key is valid YAML, the later one simply wins, and 50
# translated strings disappear with no error anywhere.
#
# That is not hypothetical. Grouping additions by TOP-LEVEL namespace alone was
# correct for as long as every key the task wrote was one level deep; the first
# `js.player.*` addition rendered a second `player:` inside the existing `js:`
# and would have deleted every js.player string in all 24 files. The write-back
# assertion caught it and reverted. This file is so that the next such case is
# caught by a test instead.
class LocaleSpliceTest < ActiveSupport::TestCase
  def setup
    # The helpers are top-level `def`s in the .rake, so loading it puts them on
    # Object as private methods. Loading twice is harmless and Rake dedupes the
    # task definitions.
    Rails.application.load_tasks unless Rake::Task.task_defined?("i18n:translate")
    @dir = Dir.mktmpdir("locale-splice")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def write(body)
    path = File.join(@dir, "xx.yml")
    File.write(path, body, encoding: "UTF-8")
    path
  end

  def splice(path, additions)
    TOPLEVEL_BINDING.receiver.send(:splice_into_locale!, path, "xx", additions)
  end

  FILE = <<~YAML
    xx:
      js:
        player:
          progress: "Card"
          queued: "Saved"
        ask:
          title: "Ask"
      player:
        join_cta: "Join"
      # A comment between two namespaces, as every real locale file has.
      you:
        title: "You"
  YAML

  test "a nested addition lands under the parent it names, not beside it" do
    path = write(FILE)

    splice(path, { "js.player.join_use_google" => "Use Google" })

    data = YAML.load_file(path)["xx"]
    assert_equal %w[join_use_google progress queued], data["js"]["player"].keys.sort,
                 "the new leaf must join the existing js.player block"
    assert_equal "Ask", data.dig("js", "ask", "title"), "its sibling must be untouched"
    assert_equal 1, File.read(path).scan(/^    player:$/).size,
                 "a second `player:` under `js:` is valid YAML and silently eats the first"
  end

  test "a leaf on an existing top-level namespace still lands inside it" do
    path = write(FILE)

    splice(path, { "player.join_sign_in" => "Sign in" })

    data = YAML.load_file(path)["xx"]
    assert_equal %w[join_cta join_sign_in], data["player"].keys.sort
    assert_equal "Card", data.dig("js", "player", "progress")
  end

  test "a namespace the file has never seen is appended whole" do
    path = write(FILE)

    splice(path, { "player_join.title" => "One last tap", "player_join.body" => "Finish" })

    data = YAML.load_file(path)["xx"]
    assert_equal({ "title" => "One last tap", "body" => "Finish" }, data["player_join"])
    assert_equal "You", data.dig("you", "title")
  end

  test "additions at three different depths in one pass all land correctly" do
    path = write(FILE)

    splice(path, { "js.player.a" => "A", "player.b" => "B", "player_join.c" => "C" })

    data = YAML.load_file(path)["xx"]
    assert_equal "A", data.dig("js", "player", "a")
    assert_equal "B", data.dig("player", "b")
    assert_equal "C", data.dig("player_join", "c")
    # Nothing that was there before may have moved, whatever order the groups
    # were spliced in — line numbers shift under each other.
    assert_equal "Card", data.dig("js", "player", "progress")
    assert_equal "Ask",  data.dig("js", "ask", "title")
    assert_equal "Join", data.dig("player", "join_cta")
    assert_equal "You",  data.dig("you", "title")
  end

  test "it appends and never rewrites" do
    path = write(FILE)
    before = File.readlines(path)

    splice(path, { "js.player.a" => "A", "player_join.c" => "C" })

    after = File.readlines(path)
    assert_equal before, after - (after - before),
                 "every original line must still be present, in order — the locale files are " \
                 "hand-quoted and a reformatted diff is a diff nobody can review"
  end

  # The new logic's heart: where does a key's subtree actually have to be
  # created? Tested directly, because the answer is what decides between
  # "joins the existing block" and "silently shadows it".
  test "the deepest existing parent is what a splice targets" do
    lines = FILE.lines
    path_for = ->(keys) { TOPLEVEL_BINDING.receiver.send(:existing_block_path, lines, keys) }

    assert_equal %w[js player], path_for.call(%w[js player]),
                 "js.player exists, so a leaf under it joins that block"
    assert_equal %w[js], path_for.call(%w[js nested deeper]),
                 "js exists but nothing below — the rest is created inside it"
    assert_equal [], path_for.call(%w[player_join]),
                 "an unknown namespace is appended whole"
    # The trap the old code fell into: `player` exists at the top level AND
    # inside `js`. A search that is not scoped to the parent's own range finds
    # the wrong one and splices a leaf into a namespace nobody asked for.
    assert_equal %w[player], path_for.call(%w[player])
  end

  # A nested block that is the LAST under its parent is closed by a key
  # indented LESS than itself — `js.ask` here, by the top-level `player:`. The
  # range used to end only on a line indented exactly as far as the block, so
  # it ran on into the next namespace and the splice landed there: eight
  # six-space lines under a two-space key, which is not YAML, in 24 files
  # (2026-09-22). The write-back check could not revert what it could not
  # parse, so the file stayed broken — that half is guarded here too.
  test "a nested block is closed by a shallower key, not just by its own sibling" do
    path = write(FILE)

    splice(path, { "js.ask.hint" => "Hint" })

    data = YAML.load_file(path)["xx"]
    assert_equal "Hint", data.dig("js", "ask", "hint")
    assert_equal "Ask", data.dig("js", "ask", "title")
    assert_equal({ "join_cta" => "Join" }, data["player"], "the top-level player block must be untouched")
    assert_match(/^    ask:\n      title: "Ask"\n      hint: "Hint"\n  player:/, File.read(path),
                 "the leaf lands inside js.ask, before the shallower key that closes it")
  end

  test "a splice that would not parse is reverted rather than left on disk" do
    path = write(FILE)
    original = File.read(path)

    # A value the emitter cannot make safe inside a block is not a real case,
    # so the parse failure is provoked the direct way: by handing the splicer
    # a file whose end is mid-structure once anything is appended to it.
    File.write(path, original + "  broken: [\n", encoding: "UTF-8")
    assert_raises(RuntimeError) { splice(path, { "you.body" => "B" }) }
    assert_equal original + "  broken: [\n", File.read(path), "reverted to exactly what it was given"
  end

  # A block at the end of its parent, with a comment and a sibling after it —
  # the arrangement every real locale file has, and the one where a line-range
  # that runs on by one would splice a leaf into the wrong namespace.
  test "a block ends before the comment that introduces its sibling" do
    path = write(FILE)

    splice(path, { "player.zz" => "Z" })

    data = YAML.load_file(path)["xx"]
    assert_equal "Z", data.dig("player", "zz")
    assert_nil data.dig("you", "zz"), "the leaf must not fall through into the next namespace"
    assert_match(/# A comment between two namespaces/, File.read(path),
                 "and the comment must survive")
  end
end
