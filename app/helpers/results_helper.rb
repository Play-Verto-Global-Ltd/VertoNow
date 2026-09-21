module ResultsHelper
  # The VIEW filter is one list of up to a few dozen pills covering four or five
  # different KINDS of thing — a partner's share link, a country, a wave, a
  # gender, an age band. Undifferentiated they read as one long undifferentiated
  # wrap (thirteen pills over three rows on the Unleash Football deck), and
  # nothing but the emoji tells you that "Spain" and "Male" are answers to
  # different questions.
  #
  # So they are grouped by the id prefix ResolvesResultSegments mints, and each
  # group carries an accent. The accent says KIND; teal stays reserved for
  # "this one is active", as it is everywhere else in the product.
  #
  # Order is deliberate: how they reached the Verto, then when, then where, then
  # who — narrowing from the study's own structure down to the person.
  SEGMENT_GROUPS = [
    { key: "links",    accent: "#8B85FF", prefixes: %w[direct share_ link_] },
    { key: "waves",    accent: "#FF9F45", prefixes: %w[wave_] },
    { key: "places",   accent: "#0CA7FF", prefixes: %w[region_] },
    { key: "gender",   accent: "#FF1E6F", prefixes: %w[gender_] },
    { key: "age",      accent: "#FFC24B", prefixes: %w[age_] },
    { key: "heritage", accent: "#615BF5", prefixes: %w[heritage_] },
    { key: "neuro",    accent: "#00C2A8", prefixes: %w[neuro_] }
  ].freeze

  # [{ key:, accent:, segments: [...] }, ...] for everything except "overall",
  # which is drawn on its own as the reset. A kind nobody has used contributes
  # no group rather than an empty one, and anything whose prefix is not listed
  # falls into a final unlabelled group so a segment can never silently vanish
  # from the picker because someone added a new kind upstream.
  def results_segment_groups(segments)
    rest = segments.reject { |s| s[:id].to_s == "overall" }

    grouped = SEGMENT_GROUPS.filter_map do |group|
      matched = rest.select { |s| group[:prefixes].any? { |p| s[:id].to_s.start_with?(p) } }
      next if matched.empty?
      { key: group[:key], accent: group[:accent], segments: matched }
    end

    known = grouped.flat_map { |g| g[:segments] }
    others = rest - known
    grouped << { key: "other", accent: "rgba(255,255,255,0.45)", segments: others } if others.any?
    grouped
  end
end
