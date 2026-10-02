# Who may create a respondent account, by age — the Privacy Notice's §15:
#
#   "Account creation is not available to anyone under 16, or under 18 where
#    local law sets a higher age."
#
# Taking part needs no account and is never gated here; only the account is.
#
# We hold an age BAND, never a date of birth (same section), so the question is
# always "does this whole band sit at or above the minimum?". The bands were cut
# at 16 and 18 (DemographicQuestions::AGE_BANDS), so no band straddles either
# minimum and the answer is never a guess. A Verto from before the band slider
# recorded a birth year instead; that is read at the LOWEST age it allows, since
# the birthday may not have come round yet.
#
# Three verdicts, because "we don't know" is common and is not "no":
#
#   :eligible   the run recorded an age at or above the minimum
#   :too_young  the run recorded an age below it — no account, whatever is ticked
#   :unknown    no age on record (the Verto has no age card, the respondent
#               skipped it, or the run isn't stored yet) — the person may still
#               declare they meet the minimum, which the join card asks for
module AccountAge
  DEFAULT_MIN = 16

  # Countries whose law puts the age a person can consent to an online account
  # on their own at 18. ISO 3166-1 alpha-2, matching WorldRegions.
  #
  # NOT EXHAUSTIVE and not legal advice: it is the list as compiled, and the
  # Privacy Notice is the authority. Adding a country here is the whole change.
  HIGHER_MIN = {
    "IN" => 18, # India — Digital Personal Data Protection Act 2023
    "ID" => 18, # Indonesia — Personal Data Protection Law 2022
    "KE" => 18, # Kenya — Data Protection Act 2019
    "LK" => 18, # Sri Lanka — Personal Data Protection Act 2022
    "NG" => 18, # Nigeria — Nigeria Data Protection Act 2023
    "UG" => 18, # Uganda — Data Protection and Privacy Act 2019
    "ZA" => 18  # South Africa — POPIA
  }.freeze

  module_function

  # The minimum for a country code, or the default when there isn't one.
  def min_age_for(country)
    HIGHER_MIN.fetch(country.to_s.upcase, DEFAULT_MIN)
  end

  # Where the respondent is, as far as this run can tell: the location card's
  # answer first (it is theirs), else the country the creator says the Verto
  # is for. nil — the default minimum — when neither was given.
  def country_for(response, survey)
    response&.region_country.presence || survey&.audience_country.presence
  end

  def min_age(response, survey) = min_age_for(country_for(response, survey))

  # The verdict for one stored run (nil when it isn't stored yet).
  def verdict(response, survey)
    lowest = lowest_age(response)
    return :unknown if lowest.nil?

    lowest >= min_age(response, survey) ? :eligible : :too_young
  end

  # The youngest the run's recorded age allows, in years; nil if none.
  def lowest_age(response)
    return nil if response.nil?

    if (key = response.demographic_age_band.presence)
      DemographicQuestions::AGE_BANDS.find { |b| b[:key] == key }&.dig(:min)
    elsif (year = response.demographic_birth_year)
      Date.current.year - year - 1
    end
  end
end
