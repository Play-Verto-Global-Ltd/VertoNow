class AddTokenResultNoteToSurveys < ActiveRecord::Migration[8.1]
  # The sentence above the final points tally — "the scores seem to be just
  # numbers, so I wonder if they need a bit more context", from a creator
  # running a study measuring exactly what those numbers are supposed to
  # measure.
  #
  # A column rather than the card copy its mid-deck twin uses (a Points
  # Checkpoint explains itself through its own `description`, which
  # SurveyTranslator walks and therefore translates) because the final tally is
  # not a card at all: it is drawn onto the end screen by the player from the
  # submit response. There is nothing to hang a translated field on, so this
  # shares the shape and the limits of tokens_note beside it — and its
  # limitation, which the editor states rather than leaving to be discovered:
  # survey-level copy is shown verbatim in every language.
  #
  # No default. Blank means the tally says nothing extra, so no existing Verto
  # gains words its creator did not write.
  def change
    add_column :surveys, :token_result_note, :string
  end
end
