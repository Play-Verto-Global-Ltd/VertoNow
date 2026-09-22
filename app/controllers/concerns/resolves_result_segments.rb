module ResolvesResultSegments
  extend ActiveSupport::Concern

  # ── Kinds ───────────────────────────────────────────────────────────────────
  # What kind of thing a segment is, read off the id prefix it is minted with
  # below. The kind decides two things: how the picker groups the pills
  # (ResultsHelper adds the colour and the order), and what picking two of
  # them MEANS. Two of one kind are alternatives — a respondent has one country
  # and one gender — so "Austria, Germany" can only mean Austria OR Germany.
  # Two of different kinds are both true of one respondent, so "Austria, Male"
  # is Austrian men. OR within a kind, AND across kinds: the grammar every
  # faceted filter uses, and the only one under which no combination is
  # trivially empty.
  SEGMENT_KINDS = {
    "direct"    => "links",
    "share_"    => "links",
    "link_"     => "links",
    "wave_"     => "waves",
    "region_"   => "places",
    "gender_"   => "gender",
    "age_"      => "age",
    "heritage_" => "heritage",
    "neuro_"    => "neuro"
  }.freeze

  # The kinds that slice by WHO someone is rather than how or when they
  # arrived. One of these on its own is only ever offered above the small-cell
  # threshold; a combination that includes one is held to the same rule,
  # because intersecting two safe slices is exactly how a cell gets small —
  # Austria is 144 people and women over 65 are 20, and Austrian women over
  # 65 may be two.
  IDENTITY_KINDS = %w[places gender age heritage neuro].freeze

  # ?segment=region_AT,gender_male — one param, comma-joined, so a single id
  # (every link the product ever minted) is the one-part case of the same
  # thing, and every consumer that passes `segment: active[:id]` along
  # (exports, the answers panel, the Sheets round trip) carries a combination
  # without knowing it is one. No id can contain a comma: they are ids,
  # positions, country codes and parameterized labels.
  SEGMENT_SEPARATOR = ","

  def self.kind_of(id)
    id = id.to_s
    SEGMENT_KINDS.each { |prefix, kind| return kind if id.start_with?(prefix) }
    id # an unknown kind is its own kind: never merged with anything
  end

  # The canonical ?segment= value for a set of ids: in the order the segments
  # are offered, once each, Overall dropped (it is the absence of a filter),
  # nil for none — so the three clicks that build one combination in any order
  # land on one URL rather than six.
  def self.segment_param(segments, ids)
    order  = segments.map { |s| s[:id].to_s } - [ "overall" ]
    picked = Array(ids).map(&:to_s) & order
    picked.sort_by { |id| order.index(id) }.join(SEGMENT_SEPARATOR).presence
  end

  def self.split_segment_param(param)
    param.to_s.split(SEGMENT_SEPARATOR).map(&:strip).reject(&:empty?).uniq
  end

  private

  # Response segments for the results filter: always "Overall", plus a
  # "Direct link" and one entry per partner share when this Verto is shared,
  # one entry per custom link (SurveyLink) unless `links: false`, one entry per
  # wave when it's been run more than once, and one entry per region tag when
  # this Verto is region-tagged.
  # Each entry is { id:, label:, scope:, count: }. Shared by the results screen
  # and the CSV / Google Sheets exports so they all scope responses identically.
  # The public shared-results page passes `links: false`: a link's name is the
  # owner's own label for an audience (a research assistant, a newsletter), not
  # something a stranger with the results token should read.
  def result_segments(survey, base, links: true)
    segments = [ { id: "overall", label: "Overall", scope: base, count: base.count } ]

    shares = survey.survey_shares
                   .includes(:partner_organisation, partnership_verto: :partnership)
                   .order(:created_at)

    if shares.any?
      direct = base.where(survey_share_id: nil)
      if (direct_count = direct.count).positive?
        segments << { id: "direct", label: "Direct link", scope: direct, count: direct_count }
      end

      shares.each do |share|
        scope = base.where(survey_share_id: share.id)
        partnership_name = share.partnership_verto&.partnership&.name
        label = partnership_name ? "#{share.display_name} · #{partnership_name}" : share.display_name
        segments << { id: "share_#{share.id}", label: label, scope: scope, count: scope.count }
      end
    end

    # Custom links (SurveyLink): structural groupings the owner made on purpose,
    # like waves — no small-cell suppression, zero-count links stay ("0", not
    # missing, so a freshly minted link shows up at once), recalled links stay
    # (their old responses still point at them). The "Direct link" segment
    # above is left alone: it means "not via a partner share" and so still
    # counts link responses, matching SurveyLink's own contract that a link's
    # answers are the Verto's own — the export names the link, the pill does
    # not subtract it.
    if links
      survey.survey_links.ordered.each do |link|
        scope = base.where(survey_link_id: link.id)
        segments << { id: "link_#{link.id}", label: "🔗 #{link.name}", scope: scope, count: scope.count }
      end
    end

    # Waves — explicit open/close cycles of running the same Verto again (see
    # Survey#start_next_wave!). Deliberately NO small-cell suppression: unlike
    # regions/demographics (identity slices that could re-identify someone), a
    # wave is a structural grouping the owner explicitly created, and stays a
    # segment even at zero responses so a freshly-started wave shows as "0" —
    # not silently missing from the pills.
    if survey.survey_waves.any?
      survey.survey_waves.each do |wave|
        # Wave 1's scope also absorbs nil: responses genuinely written in the
        # brief window around start_next_wave!'s backfill transaction (a
        # live /progress landing between the UPDATE and the commit) can in
        # principle stay unstamped — folding nil into wave 1 specifically
        # (never a later wave) keeps that rare race from going uncounted
        # anywhere, matching what nil already means everywhere else: "at or
        # before wave 1".
        ids   = wave.position == 1 ? [ wave.id, nil ] : wave.id
        scope = base.where(survey_wave_id: ids)
        segments << { id: "wave_#{wave.position}", label: wave.display_label, scope: scope, count: scope.count }
      end
    end

    # Region segments come from the responses themselves, so they cover both
    # link-minted regions and ask-players self-declared ones. Rolled up to
    # COUNTRY level only — sub-region labels (e.g. "Yorkshire", "London") stay
    # on Response#region_label for potential future use, but two respondents
    # in different UK sub-regions count as one "GB" segment, matching the
    # map/list UI which is country-granularity everywhere. Ordered by volume
    # and capped, so a Verto with hundreds of tagged countries doesn't explode
    # the filter row.
    # reorder(nil) drops base's `ORDER BY created_at`: Postgres rejects an
    # ORDER BY column that isn't in the GROUP BY (SQLite quietly allows it).
    # Small-cell suppression: a country with fewer than MIN_REGION_SAMPLE_SIZE
    # respondents never gets its own segment — see Response for why.
    country_counts = base.reorder(nil).where.not(region_country: nil)
                         .group(:region_country).count
                         .select { |_, count| count >= Response::MIN_REGION_SAMPLE_SIZE }
    country_counts.sort_by { |_, count| -count }.first(REGION_SEGMENT_CAP).each do |country, count|
      segments << {
        id:      "region_#{country}",
        label:   "🌍 #{WorldRegions.name_for(country)}",
        country: country,
        scope:   base.where(region_country: country),
        count:   count
      }
    end

    segments + demographic_segments(base)
  end

  REGION_SEGMENT_CAP = 30
  # Same small-cell rule the regions use: a demographic slice thin enough to
  # identify someone is worse than no slice at all.
  MIN_DEMOGRAPHIC_SAMPLE = Response::MIN_REGION_SAMPLE_SIZE

  # Age bands rather than birth years: a year is close to an identifier on a
  # small Verto, and nobody analyses "people born in 1987" — they analyse
  # "under 25". Open-ended at both ends so no respondent falls outside a band.
  AGE_BANDS = [
    [ "Under 18",  0,  17 ],
    [ "18–24",    18,  24 ],
    [ "25–34",    25,  34 ],
    [ "35–49",    35,  49 ],
    [ "50–64",    50,  64 ],
    [ "65+",      65, 200 ]
  ].freeze

  # Slices by the set demographic questions plus the opt-in ones (Heritage,
  # Neurodiversity), from the denormalised columns (see
  # AddDemographicsToResponses for why they aren't read out of the answers
  # JSON). Suppressed below the small-cell threshold, like regions.
  def demographic_segments(base)
    gender_segments(base) + age_segments(base) +
      heritage_segments(base) + neurodiversity_segments(base)
  end

  def gender_segments(base)
    counts = base.reorder(nil).where.not(demographic_gender: nil)
                 .group(:demographic_gender).count

    counts.select { |_g, n| n >= MIN_DEMOGRAPHIC_SAMPLE }
          .sort_by { |_g, n| -n }
          .map do |gender, count|
      { id: "gender_#{gender.parameterize}", label: "👤 #{gender}",
        scope: base.where(demographic_gender: gender), count: count }
    end
  end

  # Same shape as gender_segments against the opt-in Heritage column — values
  # are tamper-validated at write (sync only stores options the card offered),
  # so grouping the stored data needs no card lookup.
  def heritage_segments(base)
    counts = base.reorder(nil).where.not(demographic_heritage: nil)
                 .group(:demographic_heritage).count

    counts.select { |_h, n| n >= MIN_DEMOGRAPHIC_SAMPLE }
          .sort_by { |_h, n| -n }
          .map do |heritage, count|
      { id: "heritage_#{heritage.parameterize}", label: "👥 #{heritage}",
        scope: base.where(demographic_heritage: heritage), count: count }
    end
  end

  # Neurodiversity is multi-select, packed "|A|B|" (see the column migration),
  # so the column can't be GROUPed: unpack in Ruby (one pluck, not N COUNTs),
  # then build a LIKE scope per surviving label. Segments deliberately OVERLAP
  # (one respondent with ADHD+Dyslexia belongs to both) — correct for filters.
  # The exclusive picks are stored alone, so "None of these" is never inflated
  # by condition-pickers.
  def neurodiversity_segments(base)
    tallies = Hash.new(0)
    base.reorder(nil).where.not(demographic_neurodiversity: nil)
        .pluck(:demographic_neurodiversity).each do |packed|
      packed.to_s.split("|").reject(&:empty?).uniq.each { |label| tallies[label] += 1 }
    end

    tallies.select { |_l, n| n >= MIN_DEMOGRAPHIC_SAMPLE }
           .sort_by { |_l, n| -n }
           .map do |label, count|
      # Explicit ESCAPE: SQLite's LIKE has no default escape character
      # (Postgres defaults to backslash — stating it is a no-op there).
      pattern = "%|#{Response.sanitize_sql_like(label)}|%"
      { id: "neuro_#{label.parameterize}", label: "🧠 #{label}", count: count,
        scope: base.where("demographic_neurodiversity LIKE ? ESCAPE '\\'", pattern) }
    end
  end

  def age_segments(base)
    this_year = Date.current.year

    AGE_BANDS.filter_map do |label, min_age, max_age|
      # Two card generations, one reporting row. A Verto published before the
      # age slider denormalises a birth year, which maps to a band by a window
      # approximate to within a birthday — the right trade for not storing
      # birth dates. A Verto carrying the slider denormalises a band key
      # directly, and the keys inside this reporting band join the same row.
      keys  = DemographicQuestions.age_band_keys_within(min_age, max_age)
      scope = base.where(demographic_birth_year: (this_year - max_age)..(this_year - min_age))
                  .or(base.where(demographic_age_band: keys))
      count = scope.reorder(nil).count
      next if count < MIN_DEMOGRAPHIC_SAMPLE

      { id: "age_#{label.parameterize}", label: "🎂 #{label}", scope: scope, count: count }
    end
  end

  # The base response scope, plus the segments and the active segment selected
  # by params[:segment]. Returns [base, segments, active_segment].
  #
  # Base is every *responder* — anyone who answered at least one question, not
  # only those who reached Submit — so the per-question results reflect all the
  # data collected, including partial responses that stopped part-way. The
  # aggregator counts each card off its own answers, so an unfinished response
  # simply contributes to the questions it did reach. (Completion is still
  # surfaced separately as the dashboard's completion rate.)
  def resolve_result_segments(survey, segment_param, range_param = nil, links: true)
    base     = survey.responses.where(answered: true).order(created_at: :desc)
    base     = apply_date_range(base, range_param)
    segments = result_segments(survey, base, links: links)
    [ base, segments, select_result_segment(segments, base, segment_param) ]
  end

  # The segment ?segment= asks for. One id is that segment; several, comma
  # joined in any order, are their combination; none — or only ids this base
  # doesn't offer (a slice that fell under the small-cell threshold in a
  # narrower date window, a link's id on the public page) — is Overall.
  # Unknown ids are dropped rather than failing the whole request, so a
  # combination link keeps working when one of its parts is suppressed in
  # the window it was opened in; the page then names what it is showing.
  def select_result_segment(segments, base, segment_param)
    ids   = ResolvesResultSegments.split_segment_param(segment_param)
    parts = segments.select { |s| ids.include?(s[:id]) }
    parts = parts.reject { |s| s[:id] == "overall" } if parts.size > 1

    case parts.size
    when 0 then segments.first
    when 1 then parts.first
    else combine_result_segments(parts, base)
    end
  end

  # A combination is a segment like any other — id, label, scope, count — so
  # every consumer (the page, the exports, the answers panel) filters by it
  # without knowing it is several. Its id is the canonical joined form, which
  # is also what every toggle link on the page is built from
  # (ResultsHelper#segment_toggle_param), so the URL a click produces is the
  # URL the server would have written.
  #
  # The scope is the parts' own scopes composed, not re-derived: each is
  # `base.where(...)` (see result_segments), so `or` within a kind and `and`
  # across kinds is a flat WHERE that reads the same on SQLite and Postgres.
  # Relation#and rather than #merge — merge drops an earlier condition on a
  # column the later relation also names, which is right for chaining a
  # default scope and wrong for an intersection.
  def combine_result_segments(parts, base)
    by_kind = parts.group_by { |s| ResolvesResultSegments.kind_of(s[:id]) }
    scope   = by_kind.values.map { |same| same.map { |s| s[:scope] }.reduce(:or) }.reduce(:and)
    count   = scope.reorder(nil).count

    # Small-cell suppression, the combination's way: the count AND the rows
    # go, not just the breakdown. "3 responses" above an empty feed is still
    # the disclosure — that exactly three Austrian women over 65 answered —
    # and a scope of none keeps every consumer downstream honest by
    # construction rather than by each of them remembering to check.
    suppressed = by_kind.keys.intersect?(IDENTITY_KINDS) && count < MIN_DEMOGRAPHIC_SAMPLE

    {
      id:          parts.map { |s| s[:id] }.join(SEGMENT_SEPARATOR),
      label:       combination_label(by_kind),
      scope:       suppressed ? base.none : scope,
      count:       suppressed ? 0 : count,
      parts:       parts,
      combination: true,
      suppressed:  suppressed
    }
  end

  # "🌍 Austria or Germany · 👤 Male · 🎂 25–34": each kind's alternatives
  # joined with "or", the kinds joined with a middle dot — the sentence the
  # scope above is. A kind's emoji is said once per run, not once per pill.
  EMOJI_PREFIX = /\A\p{Emoji_Presentation}\uFE0F?\s+/

  def combination_label(by_kind)
    joiner = " #{I18n.t("results.combination_or", default: "or")} "
    by_kind.values.map do |same|
      labels = same.map { |s| s[:label].to_s }
      [ labels.first, *labels.drop(1).map { |l| l.sub(EMOJI_PREFIX, "") } ].join(joiner)
    end.join(" · ")
  end

  # Named windows rather than free date pickers: these are the questions a
  # researcher actually asks of a running Verto ("how's the last week going?"),
  # and a preset can't be given an invalid or inverted range.
  DATE_RANGES = {
    "7d"  => [ "Last 7 days",   7 ],
    "30d" => [ "Last 30 days",  30 ],
    "90d" => [ "Last 90 days",  90 ]
  }.freeze

  def date_range_options
    [ { id: "all", label: "All time" } ] +
      DATE_RANGES.map { |id, (label, _days)| { id: id, label: label } }
  end

  # The range narrows the BASE, so every segment below it is counted within the
  # window too — a date filter that only moved the charts while the segment
  # pills kept whole-Verto counts would be lying about one of them.
  def apply_date_range(base, range_param)
    entry = DATE_RANGES[range_param.to_s]
    return base unless entry

    base.where(created_at: entry.last.days.ago..)
  end
end
