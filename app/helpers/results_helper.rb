module ResultsHelper
  # The VIEW filter is one list of up to a few dozen pills covering four or five
  # different KINDS of thing — a partner's share link, a country, a wave, a
  # gender, an age band. Undifferentiated they read as one long undifferentiated
  # wrap (thirteen pills over three rows on the Unleash Football deck), and
  # nothing but the emoji tells you that "Spain" and "Male" are answers to
  # different questions.
  #
  # So they are grouped by the KIND ResolvesResultSegments reads off the id
  # prefix it mints (SEGMENT_KINDS — one table, because the same grouping
  # decides what picking two pills means: alternatives within a row, both at
  # once across rows), and each group carries an accent. The accent says
  # KIND; teal stays reserved for "this one is active", as it is everywhere
  # else in the product.
  #
  # Order is deliberate: how they reached the Verto, then when, then where, then
  # who — narrowing from the study's own structure down to the person.
  SEGMENT_GROUPS = [
    { key: "links",    accent: "#8B85FF" },
    { key: "waves",    accent: "#FF9F45" },
    { key: "places",   accent: "#0CA7FF" },
    { key: "gender",   accent: "#FF1E6F" },
    { key: "age",      accent: "#FFC24B" },
    { key: "heritage", accent: "#615BF5" },
    { key: "neuro",    accent: "#00C2A8" }
  ].freeze

  # [{ key:, accent:, segments: [...] }, ...] for everything except "overall",
  # which is drawn on its own as the reset. A kind nobody has used contributes
  # no group rather than an empty one, and anything whose prefix is not listed
  # falls into a final unlabelled group so a segment can never silently vanish
  # from the picker because someone added a new kind upstream.
  def results_segment_groups(segments)
    rest = segments.reject { |s| s[:id].to_s == "overall" }

    grouped = SEGMENT_GROUPS.filter_map do |group|
      matched = rest.select { |s| ResolvesResultSegments.kind_of(s[:id]) == group[:key] }
      next if matched.empty?
      { key: group[:key], accent: group[:accent], segments: matched }
    end

    known = grouped.flat_map { |g| g[:segments] }
    others = rest - known
    grouped << { key: "other", accent: "rgba(255,255,255,0.45)", segments: others } if others.any?
    grouped
  end

  # The ids the active segment is made of: each part's for a combination, its
  # own for a single segment, none for Overall.
  def segment_part_ids(active)
    return [] if active.nil? || active[:id].to_s == "overall"

    Array(active[:parts]).map { |s| s[:id].to_s }.presence || [ active[:id].to_s ]
  end

  def segment_selected?(active, id)
    segment_part_ids(active).include?(id.to_s)
  end

  # Where a pill leads: this segment ADDED to what is selected, or REMOVED
  # from it when it already is — and nil once nothing is left, which is
  # Overall. Every pill is a toggle, so a combination is built by clicking
  # its parts and taken apart the same way, with no separate "apply".
  def segment_toggle_param(segments, active, id)
    ids = segment_part_ids(active)
    ids = ids.include?(id.to_s) ? ids - [ id.to_s ] : ids + [ id.to_s ]
    ResolvesResultSegments.segment_param(segments, ids)
  end

  # { option label => the inline style that paints its thumbnail }, for the
  # result card's answer rows.
  #
  # Keyed by LABEL because that is what the aggregator tallies under: counts
  # come back as { "Play on!" => 12 }, in whatever order the answers arrived,
  # and are then sorted by size — so there is no index left to line up against
  # by the time a row is drawn. `option_images` is positional against `options`
  # (BUG-026), so the map is built by index here, while the pairing still
  # exists, and a label that appears twice keeps the FIRST slot's picture
  # rather than the last one silently winning.
  #
  # Only options that actually have a picture get an entry — the rows draw a
  # thumbnail iff the label is in this hash, so the ones without stay flush
  # with their own text instead of carrying a placeholder tile.
  def result_option_thumbs(card)
    images = Array(card.is_a?(Hash) ? card["option_images"] : nil)
    return {} unless images.any?(&:present?)

    Array(card["options"]).each_with_index.with_object({}) do |(label, i), out|
      image = images[i]
      next if image.blank?
      out[label.to_s] ||= "background-image:url('#{image}'); #{option_focal_style(card, i)}"
    end
  end

  # The card's own picture for the question row — its panel photo, or a video
  # card's poster frame, both of which are what the respondent actually looked
  # at. nil when the card has neither, and the view falls back to the type
  # gradient so the question text starts in the same place down the feed.
  def result_card_thumb_style(card)
    return nil unless card.is_a?(Hash)
    image = card["image"].presence || card["video_poster"].presence
    return nil if image.blank?

    "background-image:url('#{image}'); #{card_focal_style(card)}"
  end
end
