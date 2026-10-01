require "test_helper"

# The subject-access export has to be complete: a respondent's own typed words
# are the one thing it most obviously covers. It used to drop an entry whose
# value was empty before it ever looked at the Other box — so a write-in on its
# own ({value: nil, other: "…"}, the shape the box has always produced when
# nothing was ticked) left the export entirely.
class RespondentDataExportTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "O", slug: "rde-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Minds", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "text" => "What is on your mind?",
          "options" => %w[Jobs Housing], "allow_other" => true },
        { "type" => "open_ended", "text" => "Anything else?" }
      ]
    )
  end

  def export_for(answers)
    response = @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                                         answers: answers)
    RespondentDataExport.new(survey: @survey, responses: [ response ]).call
  end

  test "a write-in on its own is in the export" do
    export = export_for({ "0" => { "type" => "multiple_choice", "value" => nil, "other" => "The future of my generation" } })
    assert_includes export.to_json, "The future of my generation",
                    "the respondent's own words were dropped because nothing was ticked beside them"
  end

  test "a pick with a write-in carries both halves" do
    export = export_for({ "0" => { "type" => "multiple_choice", "value" => "Jobs", "other" => "and more" } })
    json = export.to_json
    assert_includes json, "Jobs"
    assert_includes json, "and more"
  end

  test "an entry with nothing in either half is still left out" do
    export = export_for({ "0" => { "type" => "multiple_choice", "value" => nil, "other" => "" },
                          "1" => { "type" => "open_ended", "value" => "" } })
    refute_includes export.to_json, "What is on your mind?"
    refute_includes export.to_json, "Anything else?"
  end
end
