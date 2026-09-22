class PurgeCollectedPostcodes < ActiveRecord::Migration[8.1]
  # Postcodes are no longer collected anywhere on the platform: the optional
  # field is gone from the location card, the editor toggle is gone, and the
  # write path never fills the column again. This deletes what was already
  # collected, which is the half that removing the field does NOT do.
  #
  # Two places held one, and clearing only the first would have left the
  # platform looking postcode-free while every raw export still carried them:
  #
  #   · responses.region_postcode — the denormalised column;
  #   · responses.answers — the location card's own value, stored as
  #     "CC|Label|POSTCODE" by the player's location picker.
  #
  # The second is why this walks surveys rather than issuing one UPDATE: the
  # location card's index differs per Verto, so the key inside the answers
  # JSON is only knowable per deck. Surveys with no location card are skipped
  # entirely, and a response whose value has no third segment is left alone.
  #
  # Irreversible by design — the data is deleted, not moved. The columns stay:
  # dropping them would break any deck, export or query still naming them for
  # no gain, and an always-nil column costs nothing.
  def up
    execute "UPDATE responses SET region_postcode = NULL WHERE region_postcode IS NOT NULL"
    execute "UPDATE surveys SET capture_postcode = #{quoted_false} WHERE capture_postcode = #{quoted_true}"

    strip_postcodes_from_answers!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "collected postcodes were deleted, not archived"
  end

  private

  def strip_postcodes_from_answers!
    survey = Class.new(ActiveRecord::Base) { self.table_name = "surveys" }
    response = Class.new(ActiveRecord::Base) { self.table_name = "responses" }

    survey.find_each do |s|
      cards = parse_json(s.cards)
      next unless cards.is_a?(Array)

      idx = cards.find_index { |c| c.is_a?(Hash) && c["demographic"] && c["input"] == "location" }
      next if idx.nil?

      response.where(survey_id: s.id).find_each do |resp|
        answers = parse_json(resp.answers)
        next unless answers.is_a?(Hash)

        entry = answers[idx.to_s]
        next unless entry.is_a?(Hash)

        stripped = strip_third_segment(entry["value"])
        next if stripped.nil?

        answers[idx.to_s] = entry.merge("value" => stripped)
        resp.update_columns(answers: answers.to_json)
      end
    end
  end

  # nil when there is nothing to strip, so an untouched response is never
  # rewritten — this runs over every response in the table.
  def strip_third_segment(value)
    text = value.to_s
    parts = text.split("|", 3)
    return nil unless parts.length == 3

    "#{parts[0]}|#{parts[1]}"
  end

  # The columns are `json` on Postgres and text on SQLite, so what comes back
  # is already-parsed on one engine and a String on the other.
  def parse_json(raw)
    return raw unless raw.is_a?(String)

    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  def quoted_true  = ActiveRecord::Base.connection.quote(true)
  def quoted_false = ActiveRecord::Base.connection.quote(false)
end
