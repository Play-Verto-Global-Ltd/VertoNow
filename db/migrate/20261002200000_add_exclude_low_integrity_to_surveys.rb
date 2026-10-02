class AddExcludeLowIntegrityToSurveys < ActiveRecord::Migration[8.1]
  # The creator's switch for the Verto Integrity Score: when on, the results
  # page, its exports, the AI readings, the public results link and the
  # partner page all count only High, Medium and unscored responses (see
  # Survey#integrity_filtered). Saved on the Verto rather than carried in the
  # URL like a segment, because a report or a shared link that silently
  # counted different responses from the page that made it would be worse
  # than either choice. Off by default, and inert until
  # ResponseIntegrity.visible?.
  def change
    add_column :surveys, :exclude_low_integrity, :boolean, default: false, null: false
  end
end
