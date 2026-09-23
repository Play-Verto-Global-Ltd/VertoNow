namespace :demographics do
  # A Verto named the way a person would paste it: its publish token, a whole
  # /play/ URL, a published slug, or a named share link's slug. Shared by the
  # one-off tasks below that each rewrite one live Verto's card in place.
  find_verto = lambda do
    token = ENV["TOKEN"].to_s.strip.sub(%r{\A.*/play/}, "").sub(%r{[/?#].*\z}, "")
    abort "TOKEN=<publish token or /play/ URL> is required" if token.blank?

    Survey.find_by(publish_token: token) ||
      Survey.where.not(publish_token: nil).find_by(slug: token) ||
      SurveyLink.find_by(slug: token)&.survey ||
      abort("No Verto found for #{token.inspect}")
  end

  desc "Swap a Verto's retired birth-date card for the age-band slider, in place (TOKEN=..., APPLY=1 to write)"
  # For a live Verto that still carries the month/year card. Only the CARD
  # changes: it is replaced at the SAME index, in one write, so every stored
  # answer stays keyed to the question it was given on. Doing this in the
  # editor means a delete and an insert, two autosaves, and a window in which
  # every later card sits one position early for anyone submitting.
  #
  # Stored data is deliberately left alone — the old "YYYY-MM" answers stay in
  # responses.answers and demographic_birth_year stays filled, so the age
  # segments keep counting those respondents. The cid is kept too, so anything
  # addressed to the card by cid still finds it.
  #
  # Dry run unless APPLY=1.
  task swap_age_card: :environment do
    survey = find_verto.call

    cards = Array(survey.cards).map { |c| c.is_a?(Hash) ? c.dup : c }
    idx   = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "month" }
    if idx.nil?
      already = cards.any? { |c| c.is_a?(Hash) && c["demographic"] && c["type"].to_s == "range" }
      puts already ? "“#{survey.title}” already has the age slider — nothing to do." :
                     "“#{survey.title}” has no birth-date card — nothing to do."
      next
    end

    old  = cards[idx]
    card = DemographicQuestions.core_card("age", locale: survey.default_locale)
    card["cid"] = old["cid"] if old["cid"].present?
    # Same prefill SurveysController#add_demographic_card gives a multilingual
    # Verto, so the slider is translated in every language the Verto claims.
    (Array(survey.locales) - [ survey.default_locale ]).each do |loc|
      tr = DemographicQuestions.core_card("age", locale: loc)
      (card["i18n"] ||= {})[loc] =
        { "text" => tr["text"], "description" => tr["description"], "options" => tr["options"] }.compact
    end
    cards[idx] = card

    answered = survey.responses.where.not(demographic_birth_year: nil).count
    puts "Verto:     “#{survey.title}” (id #{survey.id}, #{survey.responses.count} responses)"
    puts "Card #{idx + 1}:    “#{old['text']}” (month picker) → “#{card['text']}” (#{card['options'].size}-band slider)"
    puts "Unchanged: every card position, every stored answer, #{answered} stored birth year(s)"

    unless ENV["APPLY"] == "1"
      puts "[DRY RUN] nothing written — re-run with APPLY=1 to swap the card."
      next
    end

    # update_columns: the card list is written exactly as built above. A save
    # would run the deck normalisers, and a locked deck is never re-sanitised.
    survey.update_columns(cards: cards, updated_at: Time.current)
    puts "Swapped."
  end

  desc "Narrow a Verto's location-card search, in place (TOKEN=..., PLACES=country, COUNTRIES=KE,GB, CLEAR=1, APPLY=1 to write)"
  # The editor's "Search for" block (LocationScope) as a command, for a live
  # Verto nobody at hand can open in the editor. PLACES is any of the six
  # levels (country alone is countries only), COUNTRIES narrows to ISO codes,
  # CLEAR=1 takes the narrowing off. Cities are editor-only: each one needs
  # its boundary box from the geocoder, which a command line doesn't have.
  #
  # Only the three narrowing keys on the one card change. Nothing moves, so
  # every stored answer stays keyed to the question it was given on, and old
  # "GB|London" answers keep reading and counting as they did.
  #
  # CARD=n (as printed, 1-based) picks among several location cards; otherwise
  # it is the demographic one, or the only one. Dry run unless APPLY=1.
  task location_scope: :environment do
    survey = find_verto.call
    cards  = Array(survey.cards).map { |c| c.is_a?(Hash) ? c.deep_dup : c }

    location = cards.each_index.select { |i| LocationScope.location_card?(cards[i]) }
    abort "“#{survey.title}” has no location card — nothing to do." if location.empty?

    idx =
      if ENV["CARD"].present?
        n = Integer(ENV["CARD"], exception: false)
        abort "CARD=#{ENV["CARD"]} is not a location card. Location cards: #{location.map { |i| i + 1 }.join(", ")}" unless n && location.include?(n - 1)
        n - 1
      else
        demographic = location.select { |i| cards[i]["demographic"] }
        pick = demographic.size == 1 ? demographic : location
        if pick.size > 1
          abort "“#{survey.title}” has #{pick.size} location cards — choose one with CARD=: " +
                pick.map { |i| "#{i + 1} (“#{cards[i]['text']}”)" }.join(", ")
        end
        pick.first
      end

    listed = ->(var) { ENV[var].to_s.split(/[\s,]+/).reject(&:blank?) }
    places    = listed.("PLACES").map(&:downcase)
    countries = listed.("COUNTRIES").map(&:upcase)
    clear     = ENV["CLEAR"] == "1"

    # Refused rather than dropped: the sanitiser would quietly discard a typo,
    # and "countrys" silently becoming "any place" is the opposite of the ask.
    bad_places = places - LocationScope::PLACE_TYPES
    abort "Unknown PLACES #{bad_places.join(", ")} — use any of #{LocationScope::PLACE_TYPES.join(", ")}" if bad_places.any?
    bad_countries = countries.reject { |c| WorldRegions.valid?(c) }
    abort "Unknown COUNTRIES #{bad_countries.join(", ")} — use ISO codes such as KE, GB, US" if bad_countries.any?
    abort "Give PLACES and/or COUNTRIES, or CLEAR=1 to remove the narrowing" if !clear && places.empty? && countries.empty?

    old  = cards[idx]
    card = old.dup
    if clear
      %w[location_places location_countries location_cities].each { |k| card.delete(k) }
    else
      card["location_places"]    = places    if places.any?
      card["location_countries"] = countries if countries.any?
    end
    LocationScope.sanitize_card!(card)
    cards[idx] = card

    describe = lambda do |c|
      scope = LocationScope.for_card(c)
      [ scope[:places].any? ? scope[:places].join(" + ") : "any place",
        scope[:countries].any? ? "in #{scope[:countries].join(", ")}" : nil,
        scope[:cities].any? ? "in cities #{scope[:cities].map { |x| x['name'] }.join(", ")}" : nil ].compact.join(", ")
    end

    puts "Verto:     “#{survey.title}” (id #{survey.id}, #{survey.responses.count} responses)"
    puts "Card #{idx + 1}:    “#{old['text']}”"
    puts "Search:    #{describe.(old)}  →  #{describe.(card)}"
    puts "Unchanged: every card position, every stored answer"

    if card == old
      puts "Already set that way — nothing to do."
      next
    end
    unless ENV["APPLY"] == "1"
      puts "[DRY RUN] nothing written — re-run with APPLY=1 to apply."
      next
    end

    # update_columns, as swap_age_card: the card list is written exactly as
    # built above, and a locked deck is never re-run through the normalisers.
    survey.update_columns(cards: cards, updated_at: Time.current)
    puts "Applied."
  end

  desc "Backfill demographic_gender / demographic_birth_year from stored answers (DRY_RUN=1 to preview)"
  # New responses denormalise these on save; this fills in the ones stored
  # before the columns existed, so the demographic filters aren't blank on every
  # Verto that already has responses.
  task backfill: :environment do
    dry_run = ENV["DRY_RUN"].present?
    filled  = scanned = 0

    Survey.where.not(cards: nil).find_each(batch_size: 25) do |survey|
      cards      = Array(survey.cards)
      # Keyless-or-"gender" guard mirrors PlayerController#sync_demographics_from_answers! —
      # the opt-in Heritage card is also a demographic multiple_choice and must
      # not steal the gender slot.
      gender_idx = cards.find_index do |c|
        next false unless c.is_a?(Hash) && c["demographic"] && c["type"] == "multiple_choice"
        key = c["demographic_key"].to_s
        key.empty? || key == "gender"
      end
      birth_idx  = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "month" }
      next if gender_idx.nil? && birth_idx.nil?

      allowed = gender_idx ? Array(cards[gender_idx]["options"]).map(&:to_s) : []

      survey.responses.where(demographic_gender: nil, demographic_birth_year: nil)
            .select(:id, :answers).find_each(batch_size: 500) do |response|
        scanned += 1
        answers = response.answers.is_a?(Hash) ? response.answers : {}

        gender = gender_idx ? answers[gender_idx.to_s]&.dig("value").to_s.strip.presence : nil
        gender = nil unless allowed.include?(gender)

        year = birth_idx ? answers[birth_idx.to_s]&.dig("value").to_s[/\A(\d{4})/, 1]&.to_i : nil
        year = nil unless year && year.between?(1900, Date.current.year)

        next if gender.nil? && year.nil?

        filled += 1
        next if dry_run

        # update_columns: these are derived values, and a touched updated_at on
        # every historical response would look like a wave of new activity.
        Response.where(id: response.id)
                .update_all(demographic_gender: gender, demographic_birth_year: year)
      end
    end

    puts "#{dry_run ? '[DRY RUN] ' : ''}responses scanned: #{scanned}"
    puts "responses with demographics filled in: #{filled}"
  end
end
