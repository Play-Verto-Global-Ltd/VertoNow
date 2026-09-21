require "test_helper"

class ResultsHelperTest < ActionView::TestCase
  include ResultsHelper

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
end
