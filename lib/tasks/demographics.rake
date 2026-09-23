namespace :demographics do
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
    token = ENV["TOKEN"].to_s.strip.sub(%r{\A.*/play/}, "").sub(%r{[/?#].*\z}, "")
    abort "TOKEN=<publish token or /play/ URL> is required" if token.blank?

    survey = Survey.find_by(publish_token: token) ||
             Survey.where.not(publish_token: nil).find_by(slug: token) ||
             SurveyLink.find_by(slug: token)&.survey
    abort "No Verto found for #{token.inspect}" unless survey

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
