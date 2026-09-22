require "test_helper"

class ResultsHelperTest < ActionView::TestCase
  include ResultsHelper
  # result_option_thumbs reaches for option_focal_style, and
  # result_card_thumb_style for card_focal_style — both ApplicationHelper, both
  # already in the view context this helper renders inside.
  include ApplicationHelper

  IMG = "/assets/verto-library/a.jpg".freeze
  IMG2 = "/assets/verto-library/b.jpg".freeze

  def seg(id, count = 1)
    { id: id, label: id.to_s.titleize, count: count }
  end

  test "groups segments by the id prefixes ResolvesResultSegments mints" do
    groups = results_segment_groups([
      seg("overall"), seg("direct"), seg("share_7"), seg("link_3"),
      seg("wave_1"), seg("region_GB"), seg("gender_male"), seg("age_25-34"),
      seg("heritage_x"), seg("neuro_y")
    ])

    assert_equal %w[links waves places gender age heritage neuro], groups.map { |g| g[:key] }
    assert_equal %w[direct share_7 link_3], groups.first[:segments].map { |s| s[:id] }
  end

  test "overall is never grouped — it is the reset, drawn on its own" do
    groups = results_segment_groups([ seg("overall"), seg("region_GB") ])

    assert_equal [ "places" ], groups.map { |g| g[:key] }
    refute_includes groups.flat_map { |g| g[:segments] }.map { |s| s[:id] }, "overall"
  end

  test "a kind nobody has used contributes no group rather than an empty one" do
    groups = results_segment_groups([ seg("overall"), seg("gender_male") ])

    assert_equal [ "gender" ], groups.map { |g| g[:key] }
    assert groups.none? { |g| g[:segments].empty? }
  end

  # The picker is the only way to reach a segment now, so a segment it does not
  # draw is a segment nobody can select. A new kind upstream must therefore
  # land SOMEWHERE rather than being silently dropped by a prefix list that
  # has not caught up.
  test "an unrecognised prefix falls into a final group instead of vanishing" do
    groups = results_segment_groups([ seg("overall"), seg("mood_sunny") ])

    assert_equal [ "other" ], groups.map { |g| g[:key] }
    assert_equal [ "mood_sunny" ], groups.last[:segments].map { |s| s[:id] }
  end

  test "every segment given is drawn exactly once" do
    ids = %w[overall direct link_1 wave_2 region_ES age_18-24 mood_sunny]
    drawn = results_segment_groups(ids.map { |i| seg(i) }).flat_map { |g| g[:segments] }.map { |s| s[:id] }

    assert_equal (ids - [ "overall" ]).sort, drawn.sort
    assert_equal drawn.uniq, drawn
  end

  # The picker's rows and the combination grammar (OR within a row, AND
  # across) are one table — every kind the resolver can mint has a row here,
  # so nothing it mints can compose under one rule and be drawn under another.
  test "every kind the resolver mints has a row in the picker" do
    minted = ResolvesResultSegments::SEGMENT_KINDS.values.uniq
    assert_equal minted.sort, SEGMENT_GROUPS.map { |g| g[:key] }.sort
  end

  # ── segment_toggle_param ────────────────────────────────────────────────────
  # Every pill is a toggle against the active selection; the param it builds
  # is the resolver's canonical form, so a click lands on the URL the server
  # would have written itself.

  SEGMENTS = %w[overall region_AT region_DE gender_male age_25-34].map { |id| { id: id, label: id, count: 1 } }.freeze

  test "from Overall a pill selects just itself" do
    assert_equal "region_AT", segment_toggle_param(SEGMENTS, SEGMENTS.first, "region_AT")
  end

  test "from a single segment a pill of another kind adds itself, in picker order" do
    active = SEGMENTS.find { |s| s[:id] == "gender_male" }
    assert_equal "region_AT,gender_male", segment_toggle_param(SEGMENTS, active, "region_AT")
  end

  test "a selected part's pill removes it, and the last one out is Overall" do
    combo = { id: "region_AT,gender_male", parts: [ SEGMENTS[1], SEGMENTS[3] ], combination: true }
    assert_equal "gender_male", segment_toggle_param(SEGMENTS, combo, "region_AT")

    single = SEGMENTS.find { |s| s[:id] == "region_AT" }
    assert_nil segment_toggle_param(SEGMENTS, single, "region_AT")
  end

  test "segment_selected? reads the parts of a combination and the id of a single" do
    combo = { id: "region_AT,gender_male", parts: [ SEGMENTS[1], SEGMENTS[3] ], combination: true }
    assert segment_selected?(combo, "gender_male")
    refute segment_selected?(combo, "region_DE")
    assert segment_selected?(SEGMENTS[1], "region_AT")
    refute segment_selected?(SEGMENTS.first, "overall"), "Overall is the absence of a selection, never a selected part"
  end

  # ── result_option_thumbs ────────────────────────────────────────────────────
  # The index-to-label hop is the whole point of this helper, and it is the
  # part that silently mis-renders rather than failing: counts come back keyed
  # by label and sorted by size, so an off-by-one here puts one option's
  # photograph on another option's row and nothing anywhere says so. Each test
  # below was checked by breaking the helper under it.

  test "an option's picture is keyed by its LABEL, taken from its own slot" do
    card = { "options" => %w[Red Green Blue], "option_images" => [ IMG, "", IMG2 ] }

    thumbs = result_option_thumbs(card)

    assert_includes thumbs["Red"], IMG
    assert_includes thumbs["Blue"], IMG2
    assert_nil thumbs["Green"], "an option with no picture must not get one"
  end

  test "a card with no option_images at all maps nothing" do
    assert_empty result_option_thumbs({ "options" => %w[Red Green] })
    assert_empty result_option_thumbs({ "options" => %w[Red Green], "option_images" => [ "", nil ] })
    assert_empty result_option_thumbs(nil)
  end

  # option_images is positional and may be SHORTER than options (a deck that
  # gained statements after its pictures were set). The tail must map to
  # nothing rather than wrapping or raising.
  test "options past the end of option_images get no picture" do
    thumbs = result_option_thumbs({ "options" => %w[A B C], "option_images" => [ IMG ] })

    assert_includes thumbs["A"], IMG
    assert_nil thumbs["B"]
    assert_nil thumbs["C"]
  end

  # Two statements can legitimately read the same. Whichever wins, it must be
  # deterministic — and first is the one a reader can predict from the card.
  test "a label that appears twice keeps the first slot's picture" do
    thumbs = result_option_thumbs({ "options" => [ "Same", "Same" ], "option_images" => [ IMG, IMG2 ] })

    assert_includes thumbs["Same"], IMG
    refute_includes thumbs["Same"], IMG2
  end

  test "an option's own reposition rides along with its picture" do
    card = { "options" => %w[A B], "option_images" => [ IMG, IMG2 ],
             "option_focals" => [ nil, { "x" => 20, "y" => 80 } ] }

    thumbs = result_option_thumbs(card)

    assert_includes thumbs["B"], "--focal-x: 20%"
    assert_includes thumbs["B"], "--focal-y: 80%"
    assert_includes thumbs["A"], "--focal-x: 50%", "an unreframed option centres, as it does in the player"
  end

  # ── result_card_thumb_style ─────────────────────────────────────────────────

  test "the card's own picture carries the card's reposition" do
    style = result_card_thumb_style({ "image" => IMG, "focal_x" => 30 })

    assert_includes style, IMG
    assert_includes style, "--focal-x: 30%"
  end

  # A video card's panel is a clip, which a 52px background can't be. Its
  # poster frame is the still of that same clip, and is what the respondent
  # saw first.
  test "a video card falls back to its poster frame" do
    assert_includes result_card_thumb_style({ "video" => "/v.mp4", "video_poster" => IMG }), IMG
  end

  test "a card with no art of its own gets no tile" do
    assert_nil result_card_thumb_style({ "text" => "Pick one" })
    assert_nil result_card_thumb_style({ "image" => "" })
    assert_nil result_card_thumb_style(nil)
  end
end
