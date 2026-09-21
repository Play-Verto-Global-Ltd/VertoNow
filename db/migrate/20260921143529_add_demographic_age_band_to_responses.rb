class AddDemographicAgeBandToResponses < ActiveRecord::Migration[8.1]
  # The band a respondent picked on the age slider, as a stable key
  # (DemographicQuestions::AGE_BAND_KEYS) — never a label, because labels are
  # translated per Verto and reworded over time, and a stored label would
  # orphan the moment either happened.
  #
  # It sits BESIDE demographic_birth_year rather than replacing it: every
  # Verto published before the slider still carries the month card, and its
  # responses still denormalise a year. Nothing backfills the old rows — a
  # birth year reads back into a band at query time
  # (DemographicQuestions.age_band_key_for_age) so one segment list can span
  # both card generations, and the year is left alone rather than rewritten
  # under decks that are still collecting against it.
  #
  # Indexed for the same reason demographic_gender is: the results page and
  # the corpus indexer both group by it across a whole Verto.
  def change
    add_column :responses, :demographic_age_band, :string
    add_index  :responses, [ :survey_id, :demographic_age_band ],
               name: "index_responses_on_survey_id_and_demographic_age_band"
  end
end
